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

## High-level read/write

### `read_imei(ld0b_data)`

```python
pt = nvram_ecb_decrypt(ld0b_data[HEADER_SIZE:HEADER_SIZE + IMEI_BLOCK_SIZE])
return bcd_to_imei(pt[:IMEI_BCD_SIZE])
```

Decrypt the IMEI block at `[0x40:0x60]`, decode the first 8 plaintext bytes as BCD. The other 24 bytes (filler / checksum / padding) are ignored on read.

### `patch_imei(ld0b_data, imei)`

The write counterpart. Steps:

1. Decrypt the existing IMEI block — preserves any unknown fields rather than starting from zeros.
2. Overwrite `[0:8]` with the new BCD-encoded IMEI.
3. Set the filler at `[8:10]` to `0xFF 0xFF` (tool convention; stock uses `00 00` and round-trips equally well — what the modem validates is the BCD-vs-checksum pair, not the filler).
4. Recompute the MD5-XOR checksum over `[0:10]`, write to `[10:18]`. *Without this the modem rejects the new IMEI.*
5. Zero `[18:32]` (padding).
6. Re-encrypt with `AES_KEY`.
7. Splice back into `LD0B_001` at `[HEADER_SIZE : HEADER_SIZE + IMEI_BLOCK_SIZE]`; the surrounding header and post-block padding are untouched.

Returns the full 384-byte patched `LD0B_001` as `bytes`.

## Partition-image helpers

### `_find_ld0b_raw(img)`

Returns `(offset, copy)` for the first `LD0B_SIG` followed by ≥`LD0B_SIZE` more bytes; `(None, None)` if no match. Locates `LD0B_001` inside a multi-MB partition image without mounting the ext4 filesystem; the 8-byte signature makes false positives effectively zero.

### `_patch_all_copies(img, sig, orig_header, header_len, patched_data, data_len)`

Walks `img` and overwrites every `sig` match whose first `header_len` bytes equal `orig_header`. Returns the count.

ext4 keeps stale block contents around (journal, orphan inodes, COW remnants) and `LD0B_001` is small enough that historical versions persist as fragments. We've observed up to 15 copies in a single dumped nvdata image. The modem reads through the live filesystem, but updating every copy is cheap insurance against a post-flash fsck/journal-replay re-surfacing a stale one.

## CLI plumbing

### `is_partition_image(path)`

`False` for files exactly 384 bytes (standalone `LD0B_001`), `True` for files > 1 MB (partition image), `False` otherwise (which falls into the standalone path and fails the magic check with a clear error).

### `die(msg)`

`print(f"Error: {msg}", file=sys.stderr); sys.exit(1)` — keeps every error site one line.

### `load_ld0b(filepath)`

Returns 384 bytes for either input shape: scans via `_find_ld0b_raw` if the file is a partition image, otherwise reads directly and validates `len == 384` and `LD0B_MAGIC`. Dies on either failure. Used by `read` and the standalone-`LD0B_001` `write` path; the partition-image `write` path calls `_find_ld0b_raw` directly because it needs the offset.

### `main()`

Hand-rolled arg parsing — two subcommands and one optional flag (`-o output`), so `argparse` would be more setup than the loop costs.

**Read flow:** validate the file exists, call `read_imei(load_ld0b(filepath))`, print `IMEI: <value>` or `IMEI: (empty)` if `bcd_to_imei` returned `None`. The `(empty)` sentinel keeps `live_patch.sh`'s `awk` parser from crashing on uninitialised blocks.

**Write flow:** after validating the IMEI is 15 numeric digits, branch on `is_partition_image`. Standalone `LD0B_001` → call `patch_imei`, write, re-read to verify. Partition image → derive the default output name (`base_patched.ext` or `base.patched`), find the first `LD0B_001`, run `patch_imei`, run `_patch_all_copies` for the backups, write, re-scan to verify.

The verify-after-write line is the project's primary self-check: every `write` re-decrypts its own output and prints what it found. If AES, BCD, checksum, or partition patching is broken, the verified IMEI is wrong and the bug is immediately visible.

## Partition-image mode

End-to-end recipe when you have a full nvdata partition dump (live `dd` from a rooted device, or extracted from a stock ROM image):

```bash
# Dump
adb exec-out su -c "dd if=/dev/block/by-name/nvdata bs=1M 2>/dev/null" > nvdata.img

# Patch
python3 imei_tool.py write nvdata.img 350859600862948 -o nvdata_patched.img

# Flash
adb reboot bootloader
fastboot flash nvdata nvdata_patched.img
fastboot reboot
```

`_patch_all_copies` ensures every `LD0B_001` copy in the image — live, journal, backup — agrees on the new IMEI. End-to-end verified on the F21 Pro.
