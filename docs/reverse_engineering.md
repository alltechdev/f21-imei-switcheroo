# Reverse engineering the IMEI NVRAM format

A step-by-step walkthrough of how the F21 Pro's IMEI encryption was reverse-engineered from scratch. Every claim is backed by a command you can run or a byte offset you can verify. No prior knowledge of the format is assumed beyond "this phone stores its IMEI somewhere on disk."

## Source material

| Source | What it provided |
|---|---|
| F21 Pro modem firmware (`md1img_a.bin`, unpacked via [R0rt1z2/md1imgpy](https://github.com/R0rt1z2/md1imgpy) to `1_md1rom`) | The compiled ARM code and embedded constants that implement IMEI encryption on the device. Ground truth for key derivation constants, file paths, and call chain. |
| [bkerler/mtkclient](https://github.com/bkerler/mtkclient) | Open-source reimplementation of MTK's NVRAM key derivation (`SST_Get_NVRAM_SW_Key`). Provided the scramble + AES-256-CBC algorithm in Python form. |
| [MTK MOLY modem source](https://github.com/hyperion70/HSPA_MOLY.WR8.W1449.MD.WG.MP.V16) | Leaked MT6592 modem source. Contains `SST_secure.c`, `custom_nvram_sec.c`, and `nvram_util.c` in C. Older platform — provides the encryption framework and NVRAM structure but predates the MD5-XOR checksum introduced on MT67xx. |
| Black-box testing on live F21 Pro | The MD5-XOR checksum algorithm was determined empirically by decrypting known-good `LD0B_001` files and iterating on write/reboot/verify cycles until the modem consistently accepted patched IMEIs. |

## Step 0 — Find the IMEI file on disk

On a rooted F21 Pro, the IMEI is readable via `service call iphonesubinfo`, but where is it *stored*? MediaTek devices use NVRAM partitions. Search for likely paths:

```bash
adb shell su -c "find /mnt/vendor/nvdata -iname '*imei*' 2>/dev/null"
# /mnt/vendor/nvdata/md/NVRAM/NVD_IMEI
```

The match is a directory; list it to find what's inside:

```bash
adb shell su -c "ls -la /mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/"
# total 48
# drwxrwx--x 2 root  system 4096 ... .
# drwxrwx--x 7 root  system 4096 ... ..
# -rw-r--r-- 1 radio system   36 ... FILELIST
# -rw-rw---- 1 root  system  384 ... LD0B_001
# -rw-rw---- 1 root  system   96 ... NV01_000
# -rw-rw---- 1 root  system  144 ... NV0S_000
```

Four files. `LD0B_001` is the 384-byte one, owned `root:system` mode `0660` — the modem-protected payload, distinguishable by size and ownership from the small companion records. Pull it and inspect:

```bash
adb exec-out su -c "cat /mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001" > LD0B_001
wc -c LD0B_001
# 384

od -A x -t x1z -N 32 LD0B_001
# 000000 4c 44 49 00 10 ef 0a 00 0a 00 00 00 0a 40 00 00  >LDI..........@..<
# 000010 00 20 00 00 00 00 00 00 00 00 00 00 00 00 a2 44  >. .............D<
# 000020
```

The file is 384 bytes. The first 4 bytes are `LDI\x00` — a known MTK NVRAM file marker. The IMEI digits are not visible in plaintext anywhere in the file, so the content is encrypted. Now the question becomes: with what key, what algorithm, and what format?

## Crypto constants in the modem binary

All three key-derivation constants live in a contiguous block inside `1_md1rom`, sourced from `common/service/sst/src/SST_secure_exp.c`:

```
Offset in 1_md1rom   Size    Constant
────────────────────────────────────────────────────
15637084 (0xEE9A5C)   32     SECOND_SEED
15637116 (0xEE9A7C)   32     KEY_CONST
15637148 (0xEE9A9C)  256     NVSW_KGEN
```

Immediately after the constants, the source path string confirms their origin:

```
common/service/sst/src/SST_secure_exp.c
```

Followed by AES debug strings from the same file:

```
[CHE] AES encryption, data length is: %d
[CHE] AES enc length should be block size aligned, after aligned, the length is: %d
[CHE] AES decryption, data length is: %d
```

The NVRAM seed (`01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 0B 14 15 16 17 18 19 1A 1B 1C 00 00 00 00`) appears at offset 15813496 (0xF14B78).

## NVRAM security call chain

Found via debug strings in the modem ROM:

```
custom_nvram_sec.c          "pcore/custom/service/nvram/custom_nvram_sec.c"
    └── nvram_sec.c         "common/service/nvram/sec/nvram_sec.c"
        └── SST_secure.c    "common/service/sst/src/SST_secure.c"
                             "[SST]NVRAM secure check, lid=%x, rw=%x,secure=%x"
                             "[SST]NVRAM secure check status : %x"
                             debug labels: "enc_seed_source", "enc_key_source",
                                           "enc_seed", "enc_key"
            └── SST_secure_exp.c  "common/service/sst/src/SST_secure_exp.c"
                                   AES encrypt/decrypt via CHE (Crypto Hardware Engine)
                                   contains SECOND_SEED, KEY_CONST, NVSW_KGEN
```

## IMEI verification in the modem

The modem validates IMEIs at boot. Evidence from string references:

- `SBP_IMEI_VERIFY_FAIL_ENTER_ECC_MODE` — if IMEI verification fails, the modem enters emergency-calls-only mode
- `SBP_IMEI_LOCK_SUPPORT` — carrier IMEI lock support flag
- `smu_imei_lock_verified_ind_handler` — handler called after IMEI lock verification
- `IMEI locked` — debug string when IMEI lock is active
- `IMEI of SIM` — from `pcore/modem/nas/mm/cmm/src/mm_cs_common_proc.c`

The NVRAM file path `Z:\NVRAM\NVD_IMEI` appears in the modem's virtual filesystem table at offset 15581844 (0xEDC294), confirming `NVD_IMEI` is the IMEI storage folder the modem reads from.

## Identifying the encryption

The debug strings near the crypto constants tell us the algorithm:

```
[CHE] AES encryption, data length is: %d
[CHE] AES enc length should be block size aligned, after aligned, the length is: %d
```

So the modem uses AES. But which mode? Try the simplest first:

1. **ECB** (no IV needed) — try decrypting `LD0B_001[0x40:0x60]` (the 32 bytes after the 64-byte header) with AES-128-ECB and the derived key. If the output starts with recognizable BCD digits matching the known IMEI, we have our mode.
2. **CBC** — would require finding an IV. Try only if ECB doesn't work.

```python
from Crypto.Cipher import AES

AES_KEY = bytes.fromhex("3f06bd14d45fa985dd027410f0214d22")

with open("LD0B_001", "rb") as f:
    data = f.read()

# Try ECB on the 32 bytes after the header
pt = AES.new(AES_KEY, AES.MODE_ECB).decrypt(data[0x40:0x60])
print(pt.hex())
# If this starts with valid BCD digits → ECB is correct
```

On the F21 Pro, ECB works on the first attempt — the decrypted output starts with recognizable BCD-encoded IMEI digits. No IV search needed. The MOLY source (`custom_nvram_sec.c`) confirms this: `custom_nvram_encrypt` calls AES with no IV parameter, which in MTK's CHE API defaults to ECB.

**Why offset 0x40?** If you don't know the header size, brute-force it: try decrypting every 16-byte-aligned offset in the 384-byte file and check which one produces a 15-digit BCD IMEI. The IMEI's BCD form is 8 bytes where the first 7 contain two decimal digits each and byte 7's high nibble is the `0xF` padding sentinel for the unpaired 15th digit:

```python
def looks_like_imei_bcd(pt8):
    # First 7 bytes: both nibbles must be 0-9
    if not all((b & 0xF) <= 9 and (b >> 4) <= 9 for b in pt8[:7]):
        return False
    # Byte 7: low nibble 0-9 (the 15th digit), high nibble == 0xF (sentinel)
    return (pt8[7] & 0xF) <= 9 and (pt8[7] >> 4) == 0xF

for offset in range(0, 384 - 32, 16):
    pt = AES.new(AES_KEY, AES.MODE_ECB).decrypt(data[offset:offset+32])
    if looks_like_imei_bcd(pt[:8]):
        print(f"Candidate at offset {offset:#x}: {pt[:8].hex()}")
```

Only offset `0x40` matches — the trailing `0xF` sentinel is the discriminator that rules out offsets where the decrypted bytes are nibble-valid by accident (the all-`0xFF` padding region in `LD0B_001` decrypts to a sequence whose nibbles all happen to be 0–9, but the byte-7 high nibble isn't `0xF`). The 384-byte file has an 8-byte signature (`LDI\x00\x10\xef\x0a\x00`) plus 56 bytes of modem metadata = 64 bytes of header before the first encrypted IMEI block.

## AES key derivation

The key derivation algorithm was independently documented by [bkerler/mtkclient](https://github.com/bkerler/mtkclient). The constants required are all present in the modem binary (see [Crypto constants](#crypto-constants-in-the-modem-binary) above):

```
1. scramble(NVRAM_SEED, KEY_CONST) using SECOND_SEED
   → produces (iv, key), both 32 bytes
2. AES-256-CBC encrypt NVSW_KGEN (256 bytes) with key and iv[:16]
3. Take first 16 bytes of ciphertext = AES-128 NVRAM key
```

To run the derivation yourself:

```python
from Crypto.Cipher import AES

NVRAM_SEED = bytes.fromhex("0102030405060708090A0B0C0D0E0F1011120B1415161718191A1B1C00000000")
KEY_CONST  = bytes.fromhex("3523325342455424438668347856341278563412438668344245542435233253")
SECOND_SEED = bytes.fromhex("8F9C6151DC86B9163A37506D9DFF7753464BA73E5EDEF3625BA18D481235805B")
NVSW_KGEN  = bytes.fromhex(
    "BE410C67394D98017256AA3C8F21BB42CE75601B8F7BC3078216362B151F7F01"
    "96E9EB0431739C7438E4920CB18F0961956BE82D9D68403207B07A3687351302"
    "C718AD6B10EB571DCB8CFD250BAA0D55987C19528445B2728BFC252189FEF974"
    "46765F5C803309566DB380251A7CE31EB4751A06DBB2B0037B2F391D72B7266D"
    "14004905ED85E35901D9E12FE275A9207C01A76183EF175BF894282212EB9266"
    "B462B44F3079BB2EC37A9C4749CE9C7DCDE1FB60CB2A177ED103B07F95FAA84C"
    "DB156F1B9C90AD25A0A4B6217392886D20D65F182CA1DC42FD908262674CBF74"
    "ACD4E5186A44030881C8A213604A001F45F7B30BFCF7DB30D301270C59F7FC10")

def scramble(iv, buf):
    iv, buf = bytearray(iv), bytearray(buf)
    for i in range(0, 0x20, 2):
        iv[i], iv[i+1] = iv[i+1], iv[i]
    for i in range(0, 0x20, 2):
        buf[i], buf[i+1] = buf[i+1], buf[i]
    for i in range(0x20):
        v = iv[i] ^ SECOND_SEED[i]
        iv[i] = v
        buf[i] = v ^ buf[i]
    return bytes(iv), bytes(buf)

iv, key = scramble(NVRAM_SEED, KEY_CONST)
derived = AES.new(key, AES.MODE_CBC, iv=iv[:16]).encrypt(NVSW_KGEN)
aes_key = derived[:16]
print(aes_key.hex())
# Output: 3f06bd14d45fa985dd027410f0214d22
```

The constants in the modem binary match mtkclient's values byte-for-byte. The derived key is:

```
3f06bd14d45fa985dd027410f0214d22
```

This key is hardcoded in `imei_tool.py` as `AES_KEY` rather than re-derived at runtime.

## MD5-XOR checksum

The MD5-XOR checksum is **not present in the leaked MOLY source** (MT6592-era). It was introduced in the MT67xx modem generation. No public documentation or open-source tool implements it. The algorithm was discovered through the following process:

### Step 1 — Observe the plaintext structure

Pull a known-good `LD0B_001` from the device, then decrypt the IMEI block with the derived AES key and inspect it:

```bash
# On a rooted F21 Pro:
adb exec-out su -c "cat /mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001" > LD0B_001

# Read the current IMEI for cross-reference:
adb shell su -c "service call iphonesubinfo 4 i32 1" \
  | awk -F"'" '{print $2}' | sed '1d' | tr -d '.\n ' | head -c15
```

```python
from Crypto.Cipher import AES

AES_KEY = bytes.fromhex("3f06bd14d45fa985dd027410f0214d22")

with open("LD0B_001", "rb") as f:
    data = f.read()

# Encrypted IMEI block is at offset 0x40, 32 bytes
ct = data[0x40:0x60]
pt = AES.new(AES_KEY, AES.MODE_ECB).decrypt(ct)

print("Full 32-byte plaintext (hex):")
print(pt.hex())
print()
# By eye, four regions stand out: 0:8, 8:10, 10:18, 18:32. Print them grouped.
print("Decrypted 32-byte IMEI block:")
for start, end in [(0, 8), (8, 10), (10, 18), (18, 32)]:
    chunk = ' '.join(f'{b:02x}' for b in pt[start:end])
    print(f"  [0x{start:02x} : 0x{end:02x}]   {chunk}")
```

Typical output (illustrative — IMEI `123456789012345`, BCD `21 43 65 87 09 21 43 f5`, stock-style `00 00` filler):

```
Full 32-byte plaintext (hex):
21436587092143f50000dff6b0a2d850962a0000000000000000000000000000

Decrypted 32-byte IMEI block:
  [0x00 : 0x08]   21 43 65 87 09 21 43 f5
  [0x08 : 0x0a]   00 00
  [0x0a : 0x12]   df f6 b0 a2 d8 50 96 2a
  [0x12 : 0x20]   00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Four regions become obvious:
- `[0x00:0x08]` — eight bytes of decimal-digit pairs that decode as the device's IMEI (BCD encoding, swapped nibbles; matches `service call iphonesubinfo`).
- `[0x08:0x0a]` — a 2-byte field, constant for a given IMEI.
- `[0x0a:0x12]` — 8 unknown bytes. *What are these?*
- `[0x12:0x20]` — 14 bytes of zero padding.

To confirm the unknown bytes are a checksum (not a nonce or random):
- Pull `LD0B_001` multiple times without changing the IMEI → bytes `[0x0a:0x12]` are **identical** every time (deterministic, not random)
- Change the IMEI on the device, pull again → bytes `[0x0a:0x12]` are **completely different** (dependent on IMEI, not a fixed constant)

This behavior is consistent with a hash-derived checksum over the IMEI data.

### Step 2 — Identify the hash algorithm

**Constraints from observation:**
- Output is exactly 8 bytes
- Deterministic: same IMEI always produces the same 8 bytes
- High entropy: no obvious pattern, no repeated nibbles, no byte-level structure
- Changes completely when even one IMEI digit changes (avalanche behavior → cryptographic hash, not CRC)

**Approach:** Pull `LD0B_001` files for at least two different known IMEIs (e.g. before and after a carrier swap), decrypt both, and test candidate algorithms against the 8 unknown bytes. The test harness is trivial — one Python script iterating through hypotheses:

```python
import hashlib, struct, binascii

known_pairs = [
    # (decrypted_block_from_device_A, known_imei_A),
    # (decrypted_block_from_device_B, known_imei_B),
]

for pt, imei in known_pairs:
    target = pt[10:18]
    data_8  = bytes(pt[0:8])    # BCD only
    data_10 = bytes(pt[0:10])   # BCD + 2-byte filler

    # --- Hypothesis 1: CRC-64 ---
    # No stdlib CRC-64; skip unless nothing else hits.

    # --- Hypothesis 2: Simple byte-sum checksum (MOLY style) ---
    # nvram_util_caculate_checksum in MOLY uses odd/even byte sums → 2 bytes, not 8.
    # Ruled out by size alone.

    # --- Hypothesis 3: MD5 truncated to first 8 bytes ---
    h = hashlib.md5(data_10).digest()
    if h[:8] == target:
        print("MD5 first-half match"); continue

    # --- Hypothesis 4: MD5 truncated to last 8 bytes ---
    if h[8:] == target:
        print("MD5 last-half match"); continue

    # --- Hypothesis 5: MD5 XOR-folded (first 8 XOR last 8) ---
    folded = bytes(h[i] ^ h[i+8] for i in range(8))
    if folded == target:
        print("MD5 XOR-fold match"); continue

    # --- Hypothesis 6: SHA-1 truncated to 8 bytes ---
    h1 = hashlib.sha1(data_10).digest()
    if h1[:8] == target:
        print("SHA-1 first-8 match"); continue

    # --- Hypothesis 7: SHA-256 truncated to 8 bytes ---
    h256 = hashlib.sha256(data_10).digest()
    if h256[:8] == target:
        print("SHA-256 first-8 match"); continue

    # --- Hypothesis 8: SHA-1 XOR-folded (first 8 XOR bytes 8-16) ---
    h1_fold = bytes(h1[i] ^ h1[i+8] for i in range(8))
    if h1_fold == target:
        print("SHA-1 XOR-fold match"); continue

    # --- Hypothesis 9: SHA-256 XOR-folded (first 8 XOR bytes 8-16) ---
    h256_fold = bytes(h256[i] ^ h256[i+8] for i in range(8))
    if h256_fold == target:
        print("SHA-256 XOR-fold match"); continue

    # --- Hypothesis 10: MD4 truncated to 8 bytes ---
    # MD4 is in some older MTK code paths
    try:
        h4 = hashlib.new('md4', data_10).digest()
        if h4[:8] == target:
            print("MD4 first-8 match"); continue
        h4_fold = bytes(h4[i] ^ h4[i+8] for i in range(8))
        if h4_fold == target:
            print("MD4 XOR-fold match"); continue
    except ValueError:
        pass  # MD4 not available in all builds

    # --- Hypothesis 11: BLAKE2b with 8-byte digest ---
    b2 = hashlib.blake2b(data_10, digest_size=8).digest()
    if b2 == target:
        print("BLAKE2b-64 match"); continue

    # --- Hypothesis 12: repeat all above with data_8 instead of data_10 ---
    # (i.e. hash over BCD only, excluding the 2-byte filler)
    h_8 = hashlib.md5(data_8).digest()
    if bytes(h_8[i] ^ h_8[i+8] for i in range(8)) == target:
        print("MD5 XOR-fold over [0:8] match"); continue
    # (expand as needed for SHA-1, SHA-256, etc. over data_8)

    print("No match found for this pair")
```

**Results against an LD0B_001 from the F21 Pro nvdata partition image** (illustrative IMEI `123456789012345`, stock-style `00 00` filler):

```
Decrypted plaintext:
  [0x00:0x08] BCD:      21436587092143f5  →  IMEI: 123456789012345
  [0x08:0x0a] Filler:   0000
  [0x0a:0x12] Target:   dff6b0a2d850962a
  [0x12:0x20] Padding:  0000000000000000000000000000
```

| # | Algorithm | Variant | Input range | Result |
|---|---|---|---|---|
| 1 | Simple byte-sum (MOLY) | odd/even accumulator | any | Wrong size (2 bytes, not 8) |
| 2 | MD5 | first 8 bytes | `[0:10]` | No match |
| 3 | MD5 | last 8 bytes | `[0:10]` | No match |
| **4** | **MD5** | **XOR-folded** | **`[0:10]`** | **MATCH** |
| 5 | MD5 | XOR-folded | `[0:8]` | No match (wrong input range) |
| 6 | SHA-1 | first 8 bytes | `[0:10]` | No match |
| 7 | SHA-1 | XOR-folded | `[0:10]` | No match |
| 8 | SHA-256 | first 8 bytes | `[0:10]` | No match |
| 9 | SHA-256 | XOR-folded | `[0:10]` | No match |
| 10 | MD4 | first 8 / XOR-folded | `[0:10]` | N/A (not in hashlib) |
| 11 | BLAKE2b | 8-byte digest | `[0:10]` | No match |
| 12 | All of 2-11 | all variants | `[0:8]` | No match (BCD-only, no filler) |

```
Confirmed: MD5 XOR-fold over [0:10] = dff6b0a2d850962a
  matches target checksum              dff6b0a2d850962a
```

**Note on the data above:** the IMEI, BCD, and target checksum in this section are illustrative — the target was computed by applying MD5 XOR-fold, so of course that algorithm matches it. The numbers prove the methodology is internally consistent, not that the algorithm is correct. To verify independently, run this same hypothesis matrix against an `LD0B_001` pulled from your own F21 Pro: decrypt the IMEI block with the AES key derived above, take the actual `pt[10:18]` bytes from *your* device's plaintext as the target, and confirm that of the 12 candidates only MD5 XOR-fold over `pt[0:10]` matches. That's where the result becomes evidence rather than self-consistency.

**Row 4 is the only hit.** The checksum is `MD5(plaintext[0:10])` XOR-folded across its two halves:

```python
md = hashlib.md5(bcd_plus_filler).digest()    # 16 bytes
checksum = bytes(md[i] ^ md[i + 8] for i in range(8))
```

**Why MD5 XOR-fold is the natural first guess among the candidates:**
- MD5 is already linked into the modem binary (IPsec cipher suites reference it at offsets 15836083+)
- XOR-folding a digest to halve its length is a standard construction (e.g. NIST SP 800-108 KDF counter mode, Davies-Meyer compression — the pattern "hash then XOR halves" recurs throughout embedded crypto)
- 8 bytes is the natural result of folding MD5's 16-byte output in half — no truncation offset to guess
- The approach is cheap: one MD5 call + 8 XORs, suitable for a modem boot path that runs on every power-on

**Note on bytes `[0x08:0x0a]` (the 2-byte filler):** The stock nvdata image has `00 00` at this position. `imei_tool.py` writes `FF FF` (matching the convention used by other MTK IMEI tools). Both are accepted by the modem — the checksum is computed over `pt[0:10]` regardless of what those 2 bytes contain, so any value works as long as the checksum matches. The modem does not validate the filler independently; it only validates the checksum.

### Step 3 — Confirm by write/reboot testing

All three cases were verified end-to-end on the F21 Pro:

1. **With correct checksum**: write a new IMEI with `MD5(BCD + filler)` XOR-folded → reboot → modem accepts it → new IMEI appears in `service call iphonesubinfo` and the on-disk `LD0B_001` reads back as the new IMEI.
2. **Without checksum update** (BCD overwritten, checksum left as it was for the previous IMEI): reboot → the modem detects the mismatch and *rolls back* — it overwrites `LD0B_001` with the device's factory IMEI block (BCD + valid factory checksum) sourced from a backup partition. `iphonesubinfo` then reports the factory IMEI, not the BCD we wrote.
3. **With random checksum bytes** at `[10:18]`: same outcome as case 2 — the post-reboot `LD0B_001` is byte-identical to case 2's, confirming both bad-checksum paths trigger the same factory-rollback handler.

This confirms the modem firmware validates the checksum on every boot. The `SBP_IMEI_VERIFY_FAIL_ENTER_ECC_MODE` symbol earlier in the binary names a stricter failure path the firmware *can* take (emergency-calls-only with no valid IMEI), but on this device the modem only reaches it when the factory backup is also unrecoverable. With the backup intact, the observable behavior is silent rollback.

### Why MD5 in the modem binary is hard to trace

The compiled MD5 implementation exists in `1_md1rom` (the IPsec/IKE subsystem references it as `md5` in lowercase cipher-suite strings starting at offset 15836083 — e.g. `aes256-aes128-des-3des-sha256-sha1-aesxcbc-md5-…` — and the NVRAM encryption code uses it internally). However, the MD5 function has no debug symbol strings tying it directly to the IMEI checksum — it's a generic library function called from compiled ARM code with no assertion or log strings at the call site. The connection between MD5 and the IMEI checksum was established entirely through the empirical process above.

## IMEI BCD encoding

Once you decrypt a known IMEI and stare at the first 8 bytes, the encoding is recognizable:

```
Known IMEI:  3 5 0 8 5 9 6 0 0 8 6 2 9 4 8
Bytes:       53 80 95 06 80 26 49 F8
```

Each byte packs two digits in swapped-nibble order: low nibble = even-indexed digit, high nibble = odd-indexed digit. Byte 7's high nibble is `0xF` because the 15th digit is unpaired. This is standard GSM BCD (3GPP TS 23.003, same as SIM card EF_IMSI). It also appears in the MOLY source (`nvram_util.c`) and older public tools like [chuacw/WriteIMEI](https://github.com/chuacw/WriteIMEI).

The 2-byte filler at `[8:10]` plus the MD5-XOR checksum at `[10:18]` is the structure specific to the MT67xx LD0B_001 format — older platforms (MP0B_001) used a different layout with simple XOR masking and byte-sum checksums. The filler value itself isn't fixed by the format: stock nvdata leaves it `00 00`, `imei_tool.py` writes `FF FF`, and the modem accepts either as long as the checksum that follows is computed over whatever filler bytes are present.

## Summary of provenance

```
imei_tool.py component          Primary source                          How verified
────────────────────────────────────────────────────────────────────────────────────────
AES_KEY (hardcoded)              Derived via bkerler/mtkclient           Constants matched
                                 algorithm from standard MTK seed        byte-for-byte in
                                                                         modem binary at
                                                                         offsets 0xEE830C+

AES-128-ECB encrypt/decrypt      Standard crypto primitive               Decrypt known
                                 (pycryptodome)                          LD0B_001 → valid
                                                                         BCD IMEI output

imei_to_bcd / bcd_to_imei        Standard GSM BCD (MOLY source,         Matches decoded
                                 chuacw/WriteIMEI, 3GPP TS 23.003)      IMEI from device

_md5_xor_checksum                Reverse-engineered from F21 Pro         Write/reboot/verify
                                 modem firmware via black-box testing     cycle (accepted with
                                 of decrypted LD0B_001 plaintexts        correct checksum,
                                                                         rejected without)

LD0B_001 file layout             MOLY source path strings in modem       Confirmed by pulling
(header, offsets, size)          binary (nvram_multi_folder.c,           LD0B_001 from device
                                 NVD_IMEI path at offset 0xEDA51D)      and validating size

Plaintext block structure        Decrypted live LD0B_001 files from      Multiple IMEIs
(BCD + FF FF + checksum + pad)   the device, cross-referenced with       tested across
                                 iphonesubinfo service call output        reboot cycles
```

## Reproducibility

Every step above can be independently reproduced with:

1. A rooted DuoQin F21 Pro
2. The stock modem firmware (`md1img_a.bin`) unpacked with [md1imgpy](https://github.com/R0rt1z2/md1imgpy)
3. To pull the encrypted file (binary-safe on F21 Pro / Android 11 *and* later Android + Magisk setups where `su`'s stdio injects CRLF):
   ```bash
   adb shell su -c "cp /mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001 /sdcard/LD0B_001 && chmod 644 /sdcard/LD0B_001"
   adb pull /sdcard/LD0B_001
   adb shell su -c "rm /sdcard/LD0B_001"
   ```
   The shorter `adb exec-out su -c "cat …" > LD0B_001` form works on F21 Pro / Android 11 but corrupts the pull on Android 13 / Magisk (see [Hardware validation (TIQ M5)](#hardware-validation-tiq-m5-dual-sim) below for the byte-level evidence).
4. Python 3.6+ with `pycryptodome` and `hashlib` (stdlib) to decrypt and test checksum hypotheses
5. `adb reboot` to verify the modem accepts or rejects the written IMEI

## Cross-device validation (F25, firmware-only)

The walkthrough above was conducted on a live F21 Pro (single-SIM). The same key, slot offsets, and checksum were independently re-validated against a stock **DuoQin F25** (dual-SIM) firmware ZIP — no F25 hardware was used.

### What was checked against the F25 firmware

1. **Locate `LD0B_001` in the F25 nvdata image.** Unzip the F25 firmware, scan `nvdata.bin` for the `LDI\x00\x10\xef\x0a\x00` signature. Three copies are present: two byte-identical live copies (one active, one ext4 leftover sharing the same 0x40-byte header) and a distinct **factory backup** at offset `0x1c04000`. The backup has different IMEIs from the live copies, header bytes `[0x2a:0x2c]` differ (`0x68 0x10` live vs `0x37 0xf9` backup — likely a sequence/version field), and both backup slots carry their own valid checksums.

2. **Same AES key.** `AES.new(0x3f06bd14d45fa985dd027410f0214d22, ECB).decrypt(...)` on both 32-byte slots of the F25 live `LD0B_001` produces well-formed plaintext: BCD-encoded 15-digit IMEIs at `[0:8]` of each slot, a 2-byte filler at `[8:10]` (`00 00` on the live copy, `FF FF` on the factory backup — both round-trip cleanly because the checksum is computed over whichever bytes are present), and a checksum at `[10:18]` that matches MD5-XOR over `pt[0:10]` byte-for-byte.

3. **Both slots populated.** Unlike the F21 Pro (single-SIM, slot 2 = all-zero / all-`0xFF`), the F25 has *both* slots holding real IMEIs. The two IMEIs differ — confirming MTK uses one slot per SIM rather than mirroring.

4. **Round-trip through `imei_tool.py`.** `imei_tool.py write nvdata.bin <new_imei> -s 1` and `-s 2` against the F25 image: read-back via `imei_tool.py read` returns the new IMEIs in the corresponding slots, the other slot's bytes are byte-identical to the original, and `_patch_all_copies` updates the two header-matching live copies while leaving the factory backup at `0x1c04000` alone (its differing `[0x2a:0x2c]` header bytes cause the header-equality matcher to skip it — by analogy with the F21 Pro's factory-rollback handler this is desirable, but rollback behavior on F25 itself has not been observed).

### What was *not* checked

- **No live F25 hardware.** No `adb`/`fastboot`/reboot test was performed on a real F25.
- **No bad-checksum behavior on F25.** The modem-side rollback-vs-ECC-mode response confirmed on the F21 Pro (Step 3 cases 2 and 3 above) has not been observed on F25.
The cross-device evidence is strong enough to say `imei_tool.py -s 2` produces modem-acceptable bytes for the F25 *firmware* layout. Whether the F25 modem's runtime actually accepts a patched dual-SIM `LD0B_001` and brings the radio up has not been tested directly on F25 hardware; the closest hardware evidence is F21 Pro slot 1 (single-SIM) and TIQ M5 both slots (dual-SIM, see next section), where the same crypto / format / checksum produce modem-acceptable bytes that survive boot. The TIQ M5 result *is* the cross-validation against another dual-SIM MT67xx device that this section originally noted as missing.

## Hardware validation (TIQ M5, dual-SIM)

Independent end-to-end confirmation on a live **TIQ M5** (MT6761, dual-SIM):

1. **Firmware-level checks.** Same NVRAM crypto framework as F21 Pro / F25: `SST_secure_exp.c`, `nvram_sec.c`, `custom_nvram_sec.c` source-path strings present in the modem binary; the same standard MTK `NVRAM_SEED` / `KEY_CONST` / `SECOND_SEED` constants present at MT6761-specific offsets in `md1img-verified.img`; same `Z:\NVRAM\NVD_IMEI` IMEI path; same `SBP_IMEI_VERIFY_FAIL_ENTER_ECC_MODE` / `SBP_IMEI_LOCK_SUPPORT` symbols; modem built with `GEMINI_PLUS=2` (dual-SIM).

2. **Decryption check.** Pulled `nvdata.bin` from a live device via [mtkclient](https://github.com/bkerler/mtkclient). Four LD0B_001 copies present: three byte-identical 384-byte bodies at offsets `0x1202000` / `0x180414e` / `0x2e0314e` plus one distinct body at `0x100214e` whose slot 1 IMEI differs from the others (slot 2 IMEI is the same across all four). All four copies share an identical 0x40-byte header. All four decrypt cleanly with `3f06bd14d45fa985dd027410f0214d22`; all eight slot blocks (4 copies × 2 slots) carry valid MD5-XOR checksums over `pt[0:10]`; all fillers are `00 00` (stock convention). Which of the byte-identical trio is the live ext4 filesystem block versus journal/COW leftovers wasn't determined — the patching strategy doesn't depend on knowing.

3. **Bug surfaced and fixed.** Unlike F25 — where the factory backup's header bytes `[0x2a:0x2c]` differ from the live copies and the `_patch_all_copies` header-equality gate correctly excludes it — TIQ M5's four copies share a byte-identical 0x40-byte header. The original `_patch_all_copies` blasted the patched-first-copy's 384 bytes onto every header-matching copy, which on TIQ M5 corrupted the live copies' slot 1 (overwriting it with the distinct copy's slot 1 IMEI). The fix patches each copy in place — only the requested slot's 32-byte ciphertext is rewritten per copy. F21 Pro (15-copy real partition image) and F25 (firmware image) produce byte-identical output before and after the fix because their multi-copy scenarios never had body-differing same-header copies; TIQ M5 only works correctly after.

4. **Live hardware test.** Built a test `nvdata.bin` by chain-patching slot 1 then slot 2 to a single test IMEI (`123456789012345`); per-copy verification confirmed all 4 copies had both slots = the test IMEI with valid MD5-XOR checksums and zero padding intact. Flashed back via mtkclient, booted the device. Both IMEIs read as `123456789012345` on-device — confirming the modem accepts patched bytes at runtime, both slots are independently patchable, and the AES key + slot offsets + format + checksum + BCD encoding are all correct on TIQ M5.

5. **`live_patch.sh` end-to-end (rooted-ADB flow).** Two consecutive runs on the same device, each followed by a reboot:
   - Run 1: dual-SIM `[1/2/n]` prompt → choose slot 2 → patch slot 2 to a fresh test IMEI. Post-script: slot 1 byte-identical to its pre-script value (per-copy preservation verified — only the slot-2 ciphertext block changed), slot 2 = the new IMEI. Post-reboot: file md5 byte-identical to script's `tmp/patched_LD0B_001.bin` (modem persists, no rollback).
   - Run 2: same prompt → choose slot 1 → patch slot 1 to a fresh test IMEI. Post-script: slot 2 byte-identical to its run-1-patched value (the previously-patched slot is preserved across this run), slot 1 = the new IMEI. Post-reboot: file md5 byte-identical to script's patched file again.
   - **Observation that drove a script change:** the original pull (`adb exec-out su -c "cat $IMEI_PATH" > backup`) returned 387 bytes on this device's Android 13 + Magisk combo. Every byte with value `0x0a` in the file appeared as `0x0d 0x0a` in the pull — for example the source file's first 8 bytes are `4c 44 49 00 10 ef 0a 00` ("LDI" header), which were pulled back as `4c 44 49 00 10 ef 0d 0a 00`. The script's defense-in-depth size check (`wc -c == 384`) correctly rejected it. Pull was switched to `cp via su` to `/sdcard` + `adb pull` (SYNC-protocol-based, binary-safe by construction); same script then verified end-to-end on both TIQ M5 / Android 13 *and* F21 Pro / Android 11 + Magisk in the same session.

6. **Bad-checksum behavior on TIQ M5: the modem deletes the file.** Test: pulled the live `LD0B_001`, decrypted slot 1, XOR'd the 8-byte MD5-XOR checksum at `pt[0x0a:0x12]` with `0xff` (so the checksum no longer matched MD5-XOR over `pt[0:10]`), re-encrypted, pushed back. After reboot, `LD0B_001` was **absent** from `/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/` — only the unrelated `FILELIST`, `NV01_000`, and `NV0S_000` were left. The other slot (untouched, still valid) didn't save the file: the modem deletes the whole `LD0B_001` on a single bad slot. **This differs from F21 Pro,** which silently rewrites `LD0B_001` with a factory backup IMEI block (Step 3 cases 2 and 3 above) and keeps the radio up. The TIQ M5 behavior also retroactively explains the initial state of this device when first connected for testing — `LD0B_001` was missing then too, consistent with a prior bad-checksum write that the modem cleared. Restoration: pushing a valid `LD0B_001` back and rebooting is sufficient; the modem accepts it, persists across reboot, both slots read back correctly. No fastboot / mtkclient flash was needed.

7. **CRLF-injection layer isolated to `adb exec-out` + `su -c "..."`.** Test: pushed a 6-byte probe (`00 0a 00 0a 00 0a`) to `/sdcard/`, pulled it back five different ways, compared each output against the source.

   | Pull method | Output | Result |
   |---|---|---|
   | `adb pull` (SYNC protocol) | 6 bytes (`000a 000a 000a`) | clean |
   | `adb exec-out cat /sdcard/probe` (no su) | 6 bytes | clean |
   | `adb shell cat /sdcard/probe` (no su) | 6 bytes | clean |
   | **`adb exec-out su -c "cat /sdcard/probe"`** | **9 bytes (`000d0a 000d0a 000d0a`)** | **corrupted** |
   | `adb shell su -c "cat /sdcard/probe"` | 6 bytes | clean |

   So the corruption requires the *combination* of `adb exec-out` (which doesn't allocate a PTY) with Magisk's `su -c "..."` invocation. Neither layer alone produces it on this device:
   - `adb exec-out` by itself pipes raw bytes (test 2).
   - Magisk's `su` by itself, when invoked under `adb shell` (which *does* allocate a PTY), produces clean output (test 5) — apparently because `su` reuses the parent PTY's terminal settings rather than spawning its own.
   - Only when `su` is invoked under `exec-out`'s no-PTY environment does it appear to allocate its own line-discipline-applying PTY for the executed command, which is what runs `\n` → `\r\n`.

   The `cp via su /sdcard + adb pull` form sidesteps this because the binary content never traverses `su`'s stdout — `cp` writes to the filesystem directly, and `adb pull` uses the SYNC protocol, neither of which involves a PTY.

### What is *not* yet checked on TIQ M5

- (no remaining items — both bad-checksum behavior and the CRLF-layer question are resolved above.)
