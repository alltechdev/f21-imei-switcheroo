#!/usr/bin/env python3
"""
DuoQin F21 Pro IMEI Tool — read/write the IMEI in the device's
NVRAM LD0B_001 file or in a full nvdata partition image.

Usage:
  imei_tool.py read  <LD0B_001 or nvdata.img/.bin>
  imei_tool.py write <LD0B_001 or nvdata.img/.bin> <IMEI> [-o output]

Examples:
  python3 imei_tool.py read LD0B_001
  python3 imei_tool.py write LD0B_001 350859600862948 -o LD0B_001_new
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


def read_imei(ld0b_data):
    pt = nvram_ecb_decrypt(ld0b_data[HEADER_SIZE:HEADER_SIZE + IMEI_BLOCK_SIZE])
    return bcd_to_imei(pt[:IMEI_BCD_SIZE])


def patch_imei(ld0b_data, imei):
    pt = bytearray(nvram_ecb_decrypt(
        ld0b_data[HEADER_SIZE:HEADER_SIZE + IMEI_BLOCK_SIZE]))
    pt[:IMEI_BCD_SIZE] = imei_to_bcd(imei)
    pt[8] = 0xFF
    pt[9] = 0xFF
    pt[10:18] = _md5_xor_checksum(bytes(pt[:10]))
    pt[18:32] = b'\x00' * 14

    out = bytearray(ld0b_data)
    out[HEADER_SIZE:HEADER_SIZE + IMEI_BLOCK_SIZE] = nvram_ecb_encrypt(bytes(pt))
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


def _patch_all_copies(img, sig, orig_header, header_len, patched_data, data_len):
    offset = img.find(sig)
    if offset == -1:
        return 0
    img[offset:offset + data_len] = patched_data
    count = 1
    pos = offset + data_len
    while True:
        pos = img.find(sig, pos)
        if pos == -1:
            break
        if img[pos:pos + header_len] == orig_header:
            img[pos:pos + data_len] = patched_data
            count += 1
        pos += 1
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
        print(f"IMEI: {read_imei(load_ld0b(filepath)) or '(empty)'}")
        return

    if len(argv) < 3:
        die("Usage: imei_tool.py write <file> <IMEI> [-o output]")
    imei = argv[2]
    output = None
    i = 3
    while i < len(argv):
        if argv[i] == '-o' and i + 1 < len(argv):
            output = argv[i + 1]
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

        off, orig_ld0b = _find_ld0b_raw(img)
        if off is None:
            die("LD0B_001 not found in partition image")
        patched_ld0b = patch_imei(orig_ld0b, imei)
        imei_count = _patch_all_copies(
            img, LD0B_SIG, orig_ld0b[:HEADER_SIZE], HEADER_SIZE,
            patched_ld0b, LD0B_SIZE)

        try:
            with open(output, 'wb') as f:
                f.write(img)
        except (PermissionError, FileNotFoundError) as e:
            die(f"Cannot write to {output}: {e}")

        print(f"Patched IMEI ({imei_count} copies)")
        print(f"Output: {output}")

        with open(output, 'rb') as f:
            verify_img = f.read()
        _, verify_ld0b = _find_ld0b_raw(verify_img)
        print(f"Verified IMEI: {read_imei(verify_ld0b)}")

    else:
        if not output:
            output = "LD0B_001_patched"
        ld0b = load_ld0b(filepath)
        try:
            with open(output, 'wb') as f:
                f.write(patch_imei(ld0b, imei))
        except (PermissionError, FileNotFoundError) as e:
            die(f"Cannot write to {output}: {e}")
        print(f"Written: {output}")
        print(f"Verified: {read_imei(load_ld0b(output))}")


if __name__ == "__main__":
    main()
