#!/usr/bin/env python3
"""
MTK NVRAM IMEI Tool — read/write IMEI(s) in the device's NVRAM LD0B_001
file or in a full nvdata partition image.

Verified on DuoQin F21 Pro (single-SIM), DuoQin F25 (dual-SIM, firmware
only), and TIQ M5 (MT6761, dual-SIM, live device).

Usage:
  imei_tool.py read  <LD0B_001 or nvdata.img/.bin>
  imei_tool.py write <LD0B_001 or nvdata.img/.bin> <IMEI> [-s 1|2] [-o output]

`read` prints both IMEI slots; an unpopulated slot prints `(empty)`.
`write` defaults to slot 1; pass `-s 2` to rewrite the second IMEI on
dual-SIM devices (F25, TIQ M5). Slot 1 is the only slot the F21 Pro uses.

Examples:
  python3 imei_tool.py read LD0B_001
  python3 imei_tool.py write LD0B_001 350859600862948 -o LD0B_001_new
  python3 imei_tool.py write LD0B_001 350859600862948 -s 2 -o LD0B_001_new
  python3 imei_tool.py write nvdata.img 350859600862948 -o nvdata_patched.img
"""

import sys
import os
import hashlib

try:
    from Crypto.Cipher import AES
except ImportError:
    from Cryptodome.Cipher import AES

AES_KEY = bytes.fromhex("3f06bd14d45fa985dd027410f0214d22")

LD0B_MAGIC = b'LDI\x00'
LD0B_SIG = b'LDI\x00\x10\xef\x0a\x00'
LD0B_SIZE = 384
HEADER_SIZE = 0x40
IMEI_BCD_SIZE = 8
IMEI_BLOCK_SIZE = 32


def nvram_ecb_decrypt(data):
    return AES.new(AES_KEY, AES.MODE_ECB).decrypt(data)


def nvram_ecb_encrypt(data):
    return AES.new(AES_KEY, AES.MODE_ECB).encrypt(data)


def _md5_xor_checksum(bcd_10):
    md = hashlib.md5(bcd_10).digest()
    return bytes(md[i] ^ md[i + 8] for i in range(8))


def imei_to_bcd(imei):
    d = [int(c) for c in imei]
    out = bytearray(8)
    for i in range(8):
        lo = d[2 * i] if 2 * i < 15 else 0xF
        hi = d[2 * i + 1] if 2 * i + 1 < 15 else 0xF
        out[i] = (hi << 4) | lo
    return bytes(out)


def bcd_to_imei(bcd):
    if bcd in (b'\xff' * 8, b'\x00' * 8):
        return None
    digits = []
    for b in bcd:
        lo, hi = b & 0xF, (b >> 4) & 0xF
        if lo > 9:
            break
        digits.append(str(lo))
        if hi > 9:
            break
        digits.append(str(hi))
    s = ''.join(digits)
    return s if len(s) == 15 else None


def _slot_offset(slot):
    if slot not in (1, 2):
        die(f"Slot must be 1 or 2, got {slot}")
    return HEADER_SIZE + (slot - 1) * IMEI_BLOCK_SIZE


def read_imei(ld0b_data, slot=1):
    off = _slot_offset(slot)
    pt = nvram_ecb_decrypt(ld0b_data[off:off + IMEI_BLOCK_SIZE])
    return bcd_to_imei(pt[:IMEI_BCD_SIZE])


def patch_imei(ld0b_data, imei, slot=1):
    off = _slot_offset(slot)
    pt = bytearray(nvram_ecb_decrypt(ld0b_data[off:off + IMEI_BLOCK_SIZE]))
    pt[:IMEI_BCD_SIZE] = imei_to_bcd(imei)
    pt[8] = 0xFF
    pt[9] = 0xFF
    pt[10:18] = _md5_xor_checksum(bytes(pt[:10]))
    pt[18:32] = b'\x00' * 14
    out = bytearray(ld0b_data)
    out[off:off + IMEI_BLOCK_SIZE] = nvram_ecb_encrypt(bytes(pt))
    return bytes(out)


def _find_ld0b_raw(img):
    pos = 0
    while True:
        pos = img.find(LD0B_SIG, pos)
        if pos == -1:
            return None, None
        candidate = img[pos:pos + LD0B_SIZE]
        if len(candidate) == LD0B_SIZE:
            return pos, bytes(candidate)
        pos += 1


def _patch_all_copies(img, sig, header_len, slot, imei):
    pos = 0
    count = 0
    first_header = None
    while True:
        p = img.find(sig, pos)
        if p == -1:
            break
        if p + LD0B_SIZE > len(img):
            pos = p + 1
            continue
        header = bytes(img[p:p + header_len])
        if first_header is None:
            first_header = header
        if header == first_header:
            ld0b = bytes(img[p:p + LD0B_SIZE])
            img[p:p + LD0B_SIZE] = patch_imei(ld0b, imei, slot=slot)
            count += 1
        pos = p + 1
    return count


def is_partition_image(path):
    size = os.path.getsize(path)
    if size == LD0B_SIZE:
        return False
    return size > 1024 * 1024


def die(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def load_ld0b(filepath):
    if is_partition_image(filepath):
        with open(filepath, 'rb') as f:
            img = f.read()
        _, data = _find_ld0b_raw(img)
        if data is None:
            die("LD0B_001 not found in partition image")
        return data
    with open(filepath, 'rb') as f:
        data = f.read()
    if len(data) != LD0B_SIZE or data[:4] != LD0B_MAGIC:
        die(f"Not a valid LD0B_001 file (expected {LD0B_SIZE} bytes with LDI header)")
    return data


def _print_both_imeis(ld0b_data):
    for slot in (1, 2):
        v = read_imei(ld0b_data, slot=slot)
        print(f"IMEI {slot}: {v or '(empty)'}")


def main():
    argv = sys.argv[1:]
    if len(argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = argv[0]
    if cmd not in ("read", "write"):
        die(f"Unknown command: {cmd}. Use 'read' or 'write'.")

    filepath = argv[1]
    if not os.path.isfile(filepath):
        die(f"File not found: {filepath}")

    if cmd == "read":
        _print_both_imeis(load_ld0b(filepath))
        return

    if len(argv) < 3:
        die("Usage: imei_tool.py write <file> <IMEI> [-s 1|2] [-o output]")
    imei = argv[2]
    output = None
    slot = 1
    i = 3
    while i < len(argv):
        if argv[i] == '-o' and i + 1 < len(argv):
            output = argv[i + 1]
            i += 2
        elif argv[i] in ('-s', '--slot') and i + 1 < len(argv):
            try:
                slot = int(argv[i + 1])
            except ValueError:
                die(f"--slot must be 1 or 2, got '{argv[i + 1]}'")
            if slot not in (1, 2):
                die(f"--slot must be 1 or 2, got {slot}")
            i += 2
        else:
            die(f"Unknown argument: {argv[i]}")

    if not imei.isdigit() or len(imei) != 15:
        die(f"IMEI must be exactly 15 digits, got '{imei}'")

    if is_partition_image(filepath):
        if not output:
            base, ext = os.path.splitext(filepath)
            output = f"{base}_patched{ext}" if ext else filepath + '.patched'

        try:
            with open(filepath, 'rb') as f:
                img = bytearray(f.read())
        except (PermissionError, FileNotFoundError) as e:
            die(f"Cannot read {filepath}: {e}")

        imei_count = _patch_all_copies(img, LD0B_SIG, HEADER_SIZE, slot, imei)
        if imei_count == 0:
            die("LD0B_001 not found in partition image")

        try:
            with open(output, 'wb') as f:
                f.write(img)
        except (PermissionError, FileNotFoundError) as e:
            die(f"Cannot write to {output}: {e}")

        print(f"Patched IMEI {slot} ({imei_count} copies)")
        print(f"Output: {output}")

        with open(output, 'rb') as f:
            verify_img = f.read()
        _, verify_ld0b = _find_ld0b_raw(verify_img)
        print("Verified:")
        for s in (1, 2):
            v = read_imei(verify_ld0b, slot=s)
            print(f"  IMEI {s}: {v or '(empty)'}")

    else:
        if not output:
            output = "LD0B_001_patched"
        ld0b = load_ld0b(filepath)
        try:
            with open(output, 'wb') as f:
                f.write(patch_imei(ld0b, imei, slot=slot))
        except (PermissionError, FileNotFoundError) as e:
            die(f"Cannot write to {output}: {e}")
        print(f"Written: {output}  (IMEI {slot} = {imei})")
        out_ld0b = load_ld0b(output)
        print("Verified:")
        for s in (1, 2):
            v = read_imei(out_ld0b, slot=s)
            print(f"  IMEI {s}: {v or '(empty)'}")


if __name__ == "__main__":
    main()
