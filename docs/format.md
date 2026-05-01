# `LD0B_001` binary format and crypto

This page documents the on-disk layout of the F21 Pro's IMEI NVRAM file, the encryption used to protect it, and the modem-validated checksum that gates whether a written IMEI is accepted. It's the reference an engineer would need to reimplement what `imei_tool.py` does.

## File layout

`LD0B_001` is exactly **384 bytes**. The file is stored at:

```
/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001
```

owned `root:system`, mode `0660`. Layout:

```
offset  size   contents
─────────────────────────────────────────────────────────────────────
0x000     8    LD0B signature: 4C 44 49 00 10 EF 0A 00   ("LDI\0\x10\xef\x0a\x00")
0x008    56    fixed header (modem-internal metadata, not modified by this tool)
─────────────────────────────────────────────────────────────────────
0x040    32    encrypted IMEI block #1 (AES-128-ECB, two 16-byte AES blocks)
0x060    32    encrypted IMEI block #2 (typically zero/0xFF on single-SIM units)
─────────────────────────────────────────────────────────────────────
0x080   256    padding / reserved (typically 0xFF)
─────────────────────────────────────────────────────────────────────
                                                          total = 0x180 = 384 bytes
```

`imei_tool.py` patches IMEI block #1 only. Block #2 is left untouched.

### Signature

The first 8 bytes `LDI\x00\x10\xef\x0a\x00` are stable across every `LD0B_001` we've observed on the F21 Pro. The first 4 are the human-readable `LDI\x00` (NVRAM file family marker, MTK convention). The next 4 (`10 ef 0a 00`) are a fixed format/version constant.

When scanning a multi-MB partition image for `LD0B_001` blobs, the tool greps for the full 8-byte signature (`LD0B_SIG`) rather than just the 4-byte magic — this drops false-positive hit rate to effectively zero on real images.

## Encrypted IMEI block

Each 32-byte slot at `0x040` and `0x060` is AES-128-ECB ciphertext over a fixed-shape plaintext:

```
plaintext offset  size   meaning
──────────────────────────────────────────────────────────────────────
[0x00 : 0x08]      8     BCD-encoded IMEI (15 decimal digits, see below)
[0x08 : 0x0A]      2     2-byte filler — covered by the checksum but
                         otherwise unvalidated. Stock nvdata holds
                         0x00 0x00; imei_tool.py writes 0xFF 0xFF.
[0x0A : 0x12]      8     MD5-XOR checksum of [0x00 : 0x0A]
[0x12 : 0x20]     14     zero padding (0x00)
──────────────────────────────────────────────────────────────────────
                  32 bytes
```

The whole 32-byte plaintext is AES-128-ECB encrypted as **two independent AES blocks** (bytes `[0:16]` and `[16:32]`). ECB is fine here because the plaintext format is fixed and the data is not repeated across blocks in any way that would leak under ECB's block-equality side channel.

The 2-byte filler at `[0x08:0x0A]` is part of the checksum input but is not validated independently — the modem accepts any value there as long as the checksum at `[0x0A:0x12]` is computed over the actual bytes present. The stock nvdata image has `00 00`; `imei_tool.py` writes `FF FF` to match the convention used by other MTK IMEI tools. Both round-trip cleanly. See [`reverse_engineering.md` § MD5-XOR checksum](reverse_engineering.md#md5-xor-checksum) for the test that established this.

### Why 32 bytes?

The IMEI itself only needs `8 (BCD) + 2 (filler) + 8 (checksum) = 18` bytes. The remaining 14 bytes of zero padding bring the block up to two full AES-128 blocks of 16 bytes each. The modem decrypts the full 32 bytes; only the BCD region and the checksum are validated against each other.

## BCD encoding

The IMEI is 15 decimal digits. To pack 15 digits into 8 bytes, MTK uses **BCD with swapped nibbles** and a sentinel `0xF` for the unpaired final digit:

```
digits   d0 d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11 d12 d13 d14
                                                    └ 15th digit, unpaired

byte 0   (d1 << 4) | d0
byte 1   (d3 << 4) | d2
byte 2   (d5 << 4) | d4
byte 3   (d7 << 4) | d6
byte 4   (d9 << 4) | d8
byte 5   (d11 << 4) | d10
byte 6   (d13 << 4) | d12
byte 7   (0xF << 4) | d14   ← high nibble forced to 0xF
```

So IMEI `350859600862948` packs to:

```
d  =  3  5  0  8  5  9  6  0  0  8  6  2  9  4  8
       └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └─┬─┘ └ pad
         0x53  0x80  0x95  0x06  0x80  0x26  0x49 0xF8

bytes  53 80 95 06 80 26 49 F8
```

Note the byte-order: low nibble first within each byte. This "swapped BCD" is the same convention used by GSM SIM card files (EF_IMSI etc.).

`bcd_to_imei` reverses the transformation. It walks the 8 bytes, splits each into low/high nibbles, and stops at the first nibble > 9 (which signals the 0xF padding or a partial / invalid digit). It returns `None` if the assembled string isn't exactly 15 characters — this is how all-zero or all-`0xFF` blocks decode to `None` ("no IMEI here").

## MD5-XOR checksum

The 8-byte checksum at `[0x0A : 0x12]` of the plaintext is what the modem firmware validates whenever it reads an IMEI block. If you write a new IMEI without recomputing the checksum, the modem rejects the file at boot and falls back to a default IMEI (or refuses to bring the radio up).

The algorithm is:

```
md = MD5(plaintext[0x00 : 0x0A])              # 16 bytes
checksum[i] = md[i] ^ md[i + 8]    for i in 0..7
```

i.e. MD5 the 10-byte input (BCD IMEI + 2 filler bytes), then XOR-fold the 16-byte digest in half to produce 8 bytes.

The hash input is **always** the full 10 bytes — the 8-byte BCD IMEI plus the 2 filler bytes at `[0x08:0x0A]`. The filler bytes themselves are not validated by the modem; what matters is that the checksum is computed over the actual filler bytes present in the block. `patch_imei` writes `pt[8] = 0xFF; pt[9] = 0xFF` (matching other MTK IMEI tools) and then hashes the full 10 bytes including those `FF FF`s. Stock nvdata stores `00 00` instead and hashes that; either round-trips cleanly. See [`reverse_engineering.md` § MD5-XOR checksum](reverse_engineering.md#md5-xor-checksum) for the input-range bisection that confirmed this.

Confirmation: a freshly-pulled `LD0B_001` from the F21 Pro decrypts to a plaintext whose `[0x0A : 0x12]` matches `MD5(plaintext[0:0x0A]) XOR-folded` exactly — regardless of whether `pt[8:10]` is `00 00` or `FF FF`.

### Sanity test

```python
>>> import hashlib
>>> # IMEI 350859600862948 with the FF FF filler (the convention imei_tool.py writes)
>>> bcd_10 = bytes.fromhex("53809506802649F8FFFF")
>>> md = hashlib.md5(bcd_10).digest()
>>> bytes(md[i] ^ md[i+8] for i in range(8)).hex()
# matches plaintext[0x0A:0x12] of any LD0B_001 written by imei_tool.py for that IMEI

>>> # Same IMEI, but with the 00 00 filler (what stock nvdata uses)
>>> bcd_10 = bytes.fromhex("53809506802649F80000")
>>> md = hashlib.md5(bcd_10).digest()
>>> bytes(md[i] ^ md[i+8] for i in range(8)).hex()
# different output, but also valid — the modem accepts whichever filler/checksum pair is present
```

## AES key derivation

The AES-128 key the modem uses is **device-class specific**. On the F21 Pro (and any MT67xx device using MTK's standard NVRAM seed) it works out to:

```
3f06bd14d45fa985dd027410f0214d22
```

`imei_tool.py` hardcodes this as `AES_KEY` and uses it directly. The full derivation (which we don't run at runtime) is:

### MTK's `SST_Get_NVRAM_SW_Key`

```
seed   = "0102030405060708090A0B0C0D0E0F1011120B1415161718191A1B1C00000000"   (32 bytes)
const  = "3523325342455424438668347856341278563412438668344245542435233253"   (32 bytes)
second = "8F9C6151DC86B9163A37506D9DFF7753464BA73E5EDEF3625BA18D481235805B"   (32 bytes)
kgen   = 256 bytes of fixed plaintext (NVSW_KGEN, see bkerler/mtkclient)
```

Step 1 — scramble:
```python
def scramble(iv, buf):
    iv, buf = bytearray(iv), bytearray(buf)
    # swap adjacent bytes within each pair
    for i in range(0, 0x20, 2):
        iv[i], iv[i+1] = iv[i+1], iv[i]
    for i in range(0, 0x20, 2):
        buf[i], buf[i+1] = buf[i+1], buf[i]
    # XOR with second_seed
    for i in range(0x20):
        v = iv[i] ^ second[i]
        iv[i] = v
        buf[i] = v ^ buf[i]
    return iv, buf
```

Step 2 — derive: `AES-256-CBC(scramble(seed, const) → (key, iv))` over the 256-byte `NVSW_KGEN`. Take the first 16 bytes as the AES-128 NVRAM key.

Implementation reference: [`bkerler/mtkclient`](https://github.com/bkerler/mtkclient), files `mtkclient/Library/Auth/sla_keys.py` and similar.

### Why hardcoded?

The runtime derivation produces `3f06bd14d45fa985dd027410f0214d22` byte-for-byte for any device using the standard MTK seed (which is all of them in the MT67xx product line). Pre-computing once and hardcoding:

- removes the AES-256-CBC dependency (we only need AES-128-ECB at runtime),
- removes 30+ lines of derivation code from the runtime path,
- makes the actually-used key explicit and grep-able,
- eliminates a class of bugs where the derivation algorithm could subtly diverge from the modem's.

Other MTK OEMs (Samsung, OPPO, etc.) use different seeds and would derive different keys. This project only targets the F21 Pro, so the seed-variance question doesn't apply.

## End-to-end byte trace

Putting it all together, here's what happens when you patch IMEI `350859600862948` into a fresh `LD0B_001`:

```
1. Read bytes [0x40 : 0x60] of LD0B_001              → 32 bytes ciphertext
2. AES-128-ECB decrypt with AES_KEY                  → 32 bytes plaintext
3. Replace pt[0:8] with imei_to_bcd("350859600862948")   → 53 80 95 06 80 26 49 F8
4. Set pt[8] = 0xFF, pt[9] = 0xFF                    → 2-byte filler (tool convention)
5. md5_xor_checksum(pt[0:10]) → pt[10:18]            → 8 fresh checksum bytes
6. Zero pt[18:32]                                    → padding
7. AES-128-ECB encrypt with AES_KEY                  → 32 bytes new ciphertext
8. Splice into LD0B_001 at offset 0x40               → 384 bytes complete
9. Write to disk / push to device.
```

On reboot, the modem reads the file, decrypts it with the same key, recomputes the MD5-XOR checksum over `pt[0:10]` (whatever's actually there), compares it against `pt[10:18]`, and if they match decodes `pt[0:8]` as BCD and uses that as the live IMEI. The filler bytes at `pt[8:10]` are part of the hash input but are not validated independently.

## References

- [`bkerler/mtkclient`](https://github.com/bkerler/mtkclient) — reference Python implementation of MTK's NVRAM key derivation (`NVSW_KGEN`, `KEY_CONST`, scramble/CBC steps).
- [MTK MOLY modem source](https://github.com/hyperion70/HSPA_MOLY.WR8.W1449.MD.WG.MP.V16) — leaked MT6592 modem source containing the `SST_Get_NVRAM_SW_Key` C implementation. Note: predates the MT67xx generation, so it does **not** contain the MD5-XOR checksum step.
- [R0rt1z2/md1imgpy](https://github.com/R0rt1z2/md1imgpy) — used to unpack the F21 Pro's `md1img_a.bin` and confirm the key-derivation constants byte-for-byte against the live modem binary at offsets `0xEE830C` (SECOND_SEED), `0xEE832C` (KEY_CONST), `0xEE834C` (NVSW_KGEN).
- [chuacw/WriteIMEI](https://github.com/chuacw/WriteIMEI) and 3GPP TS 23.003 — standard GSM swapped-nibble BCD encoding, identical to SIM `EF_IMSI`.
- The MD5-XOR checksum was determined empirically through black-box testing on the F21 Pro — see [`reverse_engineering.md`](reverse_engineering.md) for the full step-by-step trace (decrypt-and-observe → MD5 hypothesis → input-range bisection → write/reboot/verify confirmation).
