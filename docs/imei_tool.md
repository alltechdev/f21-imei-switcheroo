# `imei_tool.py` — reference

Reads and writes the IMEI inside an MTK NVRAM `LD0B_001` blob — either as a standalone 384-byte file or embedded in a full `nvdata` partition image. No on-device logic; `live_patch.sh` (or any user script) is responsible for getting the bytes off and onto the device.

The file breaks down into: a thin wrapper around `pycryptodome`'s AES-128-ECB, the MTK-specific binary format (constants, BCD, MD5-XOR checksum), and CLI plumbing.

## Imports

```python
import sys, os, hashlib
try:
    from Crypto.Cipher import AES
except ImportError:
    from Cryptodome.Cipher import AES
```

The dual `Crypto` / `Cryptodome` import handles both `pycryptodome` distributions in the wild — historically two competing forks, modern installs land in either namespace. Same `AES.new(key, mode).encrypt/decrypt` API on both. `hashlib` (stdlib) provides MD5.

## Constants

```python
AES_KEY = bytes.fromhex("3f06bd14d45fa985dd027410f0214d22")

LD0B_MAGIC = b'LDI\x00'
LD0B_SIG   = b'LDI\x00\x10\xef\x0a\x00'
LD0B_SIZE  = 384
HEADER_SIZE = 0x40
IMEI_BCD_SIZE = 8
IMEI_BLOCK_SIZE = 32
```

| Constant | Meaning |
|---|---|
| `AES_KEY` | The AES-128 key. Pre-computed; see [`format.md` § AES key derivation](format.md#aes-key-derivation). |
| `LD0B_MAGIC` | First 4 bytes of any `LD0B_001` file. Validity check for standalone files. |
| `LD0B_SIG` | First 8 bytes (magic + fixed `10 ef 0a 00`). Stricter; used to scan partition images. |
| `LD0B_SIZE` | 384 bytes — both a validity check and the patch-and-replace stride. |
| `HEADER_SIZE` | 0x40 — the encrypted IMEI block lives at `[HEADER_SIZE : HEADER_SIZE + IMEI_BLOCK_SIZE]`. |
| `IMEI_BCD_SIZE` | 8 — BCD-encoded IMEI is the first 8 bytes of the decrypted block. |
| `IMEI_BLOCK_SIZE` | 32 — two AES-128 blocks, the unit of decrypt/encrypt. |

See [`format.md` § File layout](format.md#file-layout) for the byte-by-byte map.

## AES wrappers

`nvram_ecb_decrypt(data)` / `nvram_ecb_encrypt(data)` wrap `AES.new(AES_KEY, AES.MODE_ECB).decrypt(data)` / `.encrypt(data)` so call sites read in domain language. `data` must be a multiple of 16; in practice we always pass 32.

## Checksum

### `_md5_xor_checksum(bcd_10)`

```python
md = hashlib.md5(bcd_10).digest()         # 16 bytes
return bytes(md[i] ^ md[i + 8] for i in range(8))
```

The 8-byte checksum the modem firmware validates on every read. Algorithm: MD5 the 10-byte input, XOR-fold the digest in half (`digest[i] ^ digest[i+8]` for i in 0..7).

The 10-byte input is `pt[0:10]` — the BCD IMEI (`[0:8]`) plus the 2 filler bytes at `[8:10]`. The filler bytes are hashed but not validated independently: stock nvdata holds `00 00`, `imei_tool.py` writes `FF FF`, both round-trip. See [`format.md` § MD5-XOR checksum](format.md#md5-xor-checksum) and [`reverse_engineering.md` § MD5-XOR checksum](reverse_engineering.md#md5-xor-checksum) for the input-range bisection that established this.

## BCD encoding

### `imei_to_bcd(imei)`

15-digit decimal string → 8-byte BCD with swapped nibbles:

```
byte 0  (d1 << 4) | d0
byte 1  (d3 << 4) | d2
…
byte 7  (0xF << 4) | d14    ← unpaired 15th digit, high nibble is the sentinel
```

The function trusts its input is 15 numeric chars — `main()` validates first.

### `bcd_to_imei(bcd)`

Inverse. Walks the 8 bytes splitting each into low/high nibbles, stops at the first nibble > 9 (signals padding or invalid), and returns the assembled string only if it's exactly 15 chars long. Returns `None` otherwise — that's how callers detect "no IMEI here" (zero-filled or all-`0xFF` blocks both decode to `None`).

## Slot selection

### `_slot_offset(slot)`

```python
return HEADER_SIZE + (slot - 1) * IMEI_BLOCK_SIZE
```

Maps the user-facing slot number `1` or `2` to the byte offset within `LD0B_001`: slot 1 → `0x40`, slot 2 → `0x60`. Dies if `slot` is anything else. Every `read_imei` / `patch_imei` call routes through here, so per-slot logic stays in one place.

The CLI is 1-indexed (`-s 1`, `-s 2`) for clarity at the prompt; internally each call still resolves to the same fixed offset that the stock modem firmware uses.

## High-level read/write

### `read_imei(ld0b_data, slot=1)`

```python
off = _slot_offset(slot)
pt = nvram_ecb_decrypt(ld0b_data[off:off + IMEI_BLOCK_SIZE])
return bcd_to_imei(pt[:IMEI_BCD_SIZE])
```

Decrypt the requested IMEI block (`[0x40:0x60]` for slot 1, `[0x60:0x80]` for slot 2), decode the first 8 plaintext bytes as BCD. The other 24 bytes (filler / checksum / padding) are ignored on read. Returns `None` on an unpopulated slot — `_print_both_imeis` is what turns that into the `(empty)` string in the printed output, which `live_patch.sh` then searches for to detect single-vs-dual-SIM.

### `patch_imei(ld0b_data, imei, slot=1)`

The write counterpart. `slot=1` rewrites the block at `[0x40:0x60]`, `slot=2` rewrites the block at `[0x60:0x80]`; the other slot is untouched. Steps:

1. Decrypt the existing IMEI block — preserves any unknown fields rather than starting from zeros.
2. Overwrite `[0:8]` with the new BCD-encoded IMEI.
3. Set the filler at `[8:10]` to `0xFF 0xFF` (tool convention; stock uses `00 00` and round-trips equally well — what the modem validates is the BCD-vs-checksum pair, not the filler).
4. Recompute the MD5-XOR checksum over `[0:10]`, write to `[10:18]`. *Without this the modem rejects the new IMEI.*
5. Zero `[18:32]` (padding).
6. Re-encrypt with `AES_KEY`.
7. Splice back into `LD0B_001` at the slot's offset (`0x40` or `0x60`); the other slot, the file header, and the trailing padding are untouched.

Returns the full 384-byte patched `LD0B_001` as `bytes`.

## Partition-image helpers

### `_find_ld0b_raw(img)`

Returns `(offset, copy)` for the first `LD0B_SIG` followed by ≥`LD0B_SIZE` more bytes; `(None, None)` if no match. Locates `LD0B_001` inside a multi-MB partition image without mounting the ext4 filesystem; the 8-byte signature makes false positives effectively zero.

### `_patch_all_copies(img, sig, header_len, slot, imei)`

Walks `img` for every `sig` match. The first match's `header_len`-byte header sets the equality gate — only matches whose first `header_len` bytes equal that header get patched. Each gated match is patched **in place**: the 32-byte ciphertext at the slot's offset *within that copy* is decrypted, the new IMEI/checksum/padding written, re-encrypted, and spliced back. The rest of each copy (header, the *other* slot's ciphertext, trailing padding) is preserved per-copy. Returns the count of patched copies. Truncated finds at the very end of the image (less than `LD0B_SIZE` bytes available) are skipped.

ext4 keeps stale block contents around (journal, orphan inodes, COW remnants) and `LD0B_001` is small enough that historical versions persist as fragments. We've observed up to 15 copies in a single dumped nvdata image. The modem reads through the live filesystem, but updating every copy is cheap insurance against a post-flash fsck/journal-replay re-surfacing a stale one.

The per-copy in-place semantic matters when same-header copies have different bodies. On the F21 Pro partition image all 15 copies have byte-identical bodies (slot 1 = the device's IMEI, slot 2 = empty) so blast-replace and per-copy in-place produce the same output. On the F25 partition image the factory backup has a *different* header so the equality gate excludes it from patching. On the TIQ M5 partition image four copies share an identical 0x40-byte header but the bodies differ — three byte-identical bodies plus one distinct body whose slot 1 IMEI differs — and patching the requested slot in place is what stops the byte-identical trio's un-targeted slot from being clobbered with the distinct copy's value.

## CLI plumbing

### `is_partition_image(path)`

`False` for files exactly 384 bytes (standalone `LD0B_001`), `True` for files > 1 MB (partition image), `False` otherwise (which falls into the standalone path and fails the magic check with a clear error).

### `die(msg)`

`print(f"Error: {msg}", file=sys.stderr); sys.exit(1)` — keeps every error site one line.

### `load_ld0b(filepath)`

Returns 384 bytes for either input shape: scans via `_find_ld0b_raw` if the file is a partition image, otherwise reads directly and validates `len == 384` and `LD0B_MAGIC`. Dies on either failure. Used by `read` and the standalone-`LD0B_001` `write` path; the partition-image `write` path calls `_find_ld0b_raw` directly because it needs the offset.

### `_print_both_imeis(ld0b_data)`

Helper used by the `read` command and by the verify-after-write step inside `write`. Iterates `slot in (1, 2)` and prints `IMEI 1: <value>` / `IMEI 2: <value>` (or `(empty)` if `read_imei` returned `None`). Single-SIM devices like the F21 Pro will always show `IMEI 2: (empty)`; `live_patch.sh` uses that string to detect dual-SIM and adapt its prompt.

### `main()`

Hand-rolled arg parsing — two subcommands and two optional flags (`-o output`, `-s 1|2`), so `argparse` would be more setup than the loop costs. `-s` defaults to `1`; only values `1` and `2` are accepted (validated both at parse time and inside `_slot_offset`).

**Read flow:** validate the file exists, call `_print_both_imeis(load_ld0b(filepath))`. Output is two lines, one per slot, with `(empty)` for unpopulated slots. `live_patch.sh` parses this output by counting `(empty)` occurrences to decide between the dual-SIM and single-SIM prompt.

**Write flow:** after validating the IMEI is 15 numeric digits, branch on `is_partition_image`. Standalone `LD0B_001` → call `patch_imei(..., slot=slot)`, write, re-read both slots to verify. Partition image → derive the default output name (`base_patched.ext` or `base.patched`), find the first `LD0B_001`, run `patch_imei` on the requested slot, run `_patch_all_copies` for the backups, write, re-scan and print both slots to verify.

The verify-after-write step is the project's primary self-check: every `write` re-decrypts its own output and prints both slots. If AES, BCD, checksum, partition patching, or slot routing is broken, the verified output is wrong and the bug is immediately visible.

## Partition-image mode

End-to-end recipe when you have a full nvdata partition dump (live dump from a rooted device, or extracted from a stock ROM image):

```bash
# Dump (binary-safe across all verified Android versions: cp via su to /sdcard,
# then adb pull which uses adb's SYNC protocol)
adb shell su -c "dd if=/dev/block/by-name/nvdata of=/sdcard/nvdata.img bs=1M && chmod 644 /sdcard/nvdata.img"
adb pull /sdcard/nvdata.img
adb shell su -c "rm /sdcard/nvdata.img"

# Patch
python3 imei_tool.py write nvdata.img 350859600862948 -o nvdata_patched.img

# Flash
adb reboot bootloader
fastboot flash nvdata nvdata_patched.img
fastboot reboot
```

A simpler `adb exec-out su -c "dd if=/dev/block/by-name/nvdata bs=1M" > nvdata.img` works on F21 Pro / Android 11 but will produce a corrupted image on devices where the `su` stdio path injects CRLF translation (observed on TIQ M5 / Android 13 + Magisk — see [`live_patch.sh`'s pull section](live_patch.md#pull-current-imei) for the same issue's resolution). The `cp via su /sdcard + adb pull` form sidesteps it.

`_patch_all_copies` patches every header-matching `LD0B_001` copy in the image (live + ext4 journal/COW leftovers) in place — each copy's requested slot becomes the new IMEI while its other slot is preserved per-copy. Distinct copies whose 0x40-byte header differs (e.g. F25's factory backup) are intentionally skipped. End-to-end verified on the F21 Pro (slot 1) via `fastboot flash` and on the TIQ M5 (both slots) via mtkclient flash + boot. Both verifications used the binary-safe `cp via su + adb pull` dump form for the *initial* device → host transfer.
