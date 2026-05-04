#!/usr/bin/env python3
import os
import stat
import sys

BT_FILE_SIZE = 440
WIFI_FILE_SIZE = 2050

BT_MAC_OFFSET = 0x00
BT_TRAILER_SIG = bytes.fromhex('60002310000007000000050703040000')
BT_TRAILER_SIG_OFFSET = 0x06

WIFI_HDR = bytes.fromhex('01000800')
WIFI_MAC_OFFSET = 0x04

TRAILER_MAGIC = 0xAA


def die(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_mac(s):
    parts = s.replace('-', ':').split(':')
    if len(parts) != 6 or any(len(p) != 2 for p in parts):
        die(f"MAC must be six colon-separated hex bytes (e.g. 02:11:22:33:44:55), got {s!r} ({len(parts)} parts)")
    try:
        return bytes(int(p, 16) for p in parts)
    except ValueError:
        die(f"MAC contains non-hex characters: {s!r} (expected 0-9, a-f, A-F)")


def format_mac(b):
    return ':'.join(f'{x:02x}' for x in b)


def compute_checksum(data):
    cs = 0
    for i, b in enumerate(data[:-2]):
        cs = ((cs + b) if i % 2 == 0 else (cs ^ b)) & 0xff
    return cs


def trailer_valid(data):
    return data[-2] == TRAILER_MAGIC and data[-1] == compute_checksum(data)


def patch_bt(data, new_mac):
    if len(data) != BT_FILE_SIZE:
        die(f"BT_Addr size is {len(data)} bytes, expected {BT_FILE_SIZE}. Did you pass the WIFI file by mistake? (WIFI is {WIFI_FILE_SIZE} bytes)")
    got = data[BT_TRAILER_SIG_OFFSET:BT_TRAILER_SIG_OFFSET + len(BT_TRAILER_SIG)]
    if got != BT_TRAILER_SIG:
        die(f"BT_Addr trailer signature mismatch at offset {BT_TRAILER_SIG_OFFSET:#x}: got {got.hex()}, expected {BT_TRAILER_SIG.hex()}. File may be corrupted or not a real BT_Addr.")
    out = bytearray(data)
    out[BT_MAC_OFFSET:BT_MAC_OFFSET + 6] = new_mac
    out[-2] = TRAILER_MAGIC
    out[-1] = compute_checksum(bytes(out))
    return bytes(out)


def patch_wifi(data, new_mac):
    if len(data) != WIFI_FILE_SIZE:
        die(f"WIFI size is {len(data)} bytes, expected {WIFI_FILE_SIZE}. Did you pass the BT_Addr file by mistake? (BT_Addr is {BT_FILE_SIZE} bytes)")
    got = data[:len(WIFI_HDR)]
    if got != WIFI_HDR:
        die(f"WIFI header magic mismatch: got {got.hex()}, expected {WIFI_HDR.hex()}. File may be corrupted or not a real WIFI.")
    out = bytearray(data)
    out[WIFI_MAC_OFFSET:WIFI_MAC_OFFSET + 6] = new_mac
    out[-2] = TRAILER_MAGIC
    out[-1] = compute_checksum(bytes(out))
    return bytes(out)


def read_bt_mac(data):
    if len(data) != BT_FILE_SIZE:
        return None
    if data[BT_TRAILER_SIG_OFFSET:BT_TRAILER_SIG_OFFSET + len(BT_TRAILER_SIG)] != BT_TRAILER_SIG:
        return None
    return data[BT_MAC_OFFSET:BT_MAC_OFFSET + 6]


def read_wifi_mac(data):
    if len(data) != WIFI_FILE_SIZE:
        return None
    if data[:len(WIFI_HDR)] != WIFI_HDR:
        return None
    return data[WIFI_MAC_OFFSET:WIFI_MAC_OFFSET + 6]


def find_bt_copies(img):
    out = []
    pos = 0
    while True:
        i = img.find(BT_TRAILER_SIG, pos)
        if i < 0:
            break
        start = i - BT_TRAILER_SIG_OFFSET
        if start >= 0 and start + BT_FILE_SIZE <= len(img):
            blob = img[start:start + BT_FILE_SIZE]
            if trailer_valid(blob):
                out.append((start, blob))
        pos = i + 1
    return out


def find_wifi_copies(img):
    out = []
    pos = 0
    while True:
        i = img.find(WIFI_HDR, pos)
        if i < 0:
            break
        if i + WIFI_FILE_SIZE <= len(img):
            blob = img[i:i + WIFI_FILE_SIZE]
            if trailer_valid(blob):
                out.append((i, blob))
        pos = i + 1
    return out


def is_partition_image(path):
    sz = os.path.getsize(path)
    if sz == BT_FILE_SIZE or sz == WIFI_FILE_SIZE:
        return False
    return sz > 1024 * 1024


def write_output(path, data):
    try:
        with open(path, 'wb') as f:
            f.write(data)
    except OSError as e:
        die(f"cannot write {path}: {e.strerror or e}")


def is_regular_file(path):
    try:
        return stat.S_ISREG(os.stat(path).st_mode)
    except OSError:
        return False


def read_file(path):
    with open(path, 'rb') as f:
        return f.read()


def cmd_read(args):
    if len(args) != 1:
        die("usage: mac_tool.py read <file>")
    path = args[0]
    if not os.path.exists(path):
        die(f"file not found: {path}")
    sz = os.path.getsize(path)
    data = read_file(path)
    if is_partition_image(path):
        bts = find_bt_copies(data)
        wfs = find_wifi_copies(data)
        if bts:
            mac = bts[0][1][BT_MAC_OFFSET:BT_MAC_OFFSET + 6]
            print(f"BT_Addr  ({len(bts)} copies, first @ {bts[0][0]:#x}): {format_mac(mac)}")
        else:
            print("BT_Addr  : (not found — no valid 440-byte record with a matching aa+checksum trailer)")
        if wfs:
            mac = wfs[0][1][WIFI_MAC_OFFSET:WIFI_MAC_OFFSET + 6]
            print(f"WIFI MAC ({len(wfs)} copies, first @ {wfs[0][0]:#x}): {format_mac(mac)}")
        else:
            print("WIFI MAC : (not found — no valid 2050-byte record with a matching aa+checksum trailer)")
        return
    bt = read_bt_mac(data)
    if bt is not None:
        print(f"BT_Addr: {format_mac(bt)}")
        return
    wf = read_wifi_mac(data)
    if wf is not None:
        print(f"WIFI MAC: {format_mac(wf)}")
        return
    if sz == BT_FILE_SIZE:
        die(f"file is {sz} bytes (BT_Addr-shaped) but the trailer signature at offset {BT_TRAILER_SIG_OFFSET:#x} does not match {BT_TRAILER_SIG.hex()} — file may be corrupted or not a real BT_Addr")
    if sz == WIFI_FILE_SIZE:
        die(f"file is {sz} bytes (WIFI-shaped) but the header magic does not match {WIFI_HDR.hex()} — file may be corrupted or not a real WIFI")
    die(f"file is {sz} bytes; expected {BT_FILE_SIZE} (BT_Addr), {WIFI_FILE_SIZE} (WIFI), or > 1 MiB (partition image)")


def cmd_write(args):
    bt_mac = None
    wifi_mac = None
    out_path = None
    in_path = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == '--bt':
            if i + 1 >= len(args):
                die("--bt requires a MAC argument (e.g. --bt 02:11:22:33:44:55)")
            bt_mac = parse_mac(args[i + 1])
            i += 2
        elif a == '--wifi':
            if i + 1 >= len(args):
                die("--wifi requires a MAC argument (e.g. --wifi 02:11:22:33:44:66)")
            wifi_mac = parse_mac(args[i + 1])
            i += 2
        elif a == '-o':
            if i + 1 >= len(args):
                die("-o requires a path argument")
            out_path = args[i + 1]
            i += 2
        elif in_path is None:
            in_path = a
            i += 1
        else:
            die(f"unexpected argument {a!r} (already have input file {in_path!r})")
    if in_path is None:
        die("usage: mac_tool.py write <file> [--bt MAC] [--wifi MAC] [-o output]")
    if bt_mac is None and wifi_mac is None:
        die("at least one of --bt MAC or --wifi MAC is required")
    if not os.path.exists(in_path):
        die(f"file not found: {in_path}")

    data = read_file(in_path)
    sz = len(data)

    if is_partition_image(in_path):
        if out_path is None:
            base, ext = os.path.splitext(in_path)
            out_path = f"{base}_patched{ext}" if ext else f"{in_path}.patched"
        out = bytearray(data)
        bt_count = 0
        wifi_count = 0
        if bt_mac is not None:
            for off, blob in find_bt_copies(data):
                out[off:off + BT_FILE_SIZE] = patch_bt(blob, bt_mac)
                bt_count += 1
        if wifi_mac is not None:
            for off, blob in find_wifi_copies(data):
                out[off:off + WIFI_FILE_SIZE] = patch_wifi(blob, wifi_mac)
                wifi_count += 1
        if bt_mac is not None and bt_count == 0:
            die(f"no valid BT_Addr record found in {in_path} ({sz} bytes scanned). Looked for {BT_TRAILER_SIG.hex()} at offset 6 of a 440-byte record with valid aa+checksum trailer.")
        if wifi_mac is not None and wifi_count == 0:
            die(f"no valid WIFI record found in {in_path} ({sz} bytes scanned). Looked for header {WIFI_HDR.hex()} at the start of a 2050-byte record with valid aa+checksum trailer.")
        write_output(out_path, bytes(out))
        msg = []
        if bt_mac is not None:
            msg.append(f"BT={format_mac(bt_mac)} ({bt_count} copies)")
        if wifi_mac is not None:
            msg.append(f"WIFI={format_mac(wifi_mac)} ({wifi_count} copies)")
        print(f"Wrote {out_path}: {', '.join(msg)}")
        if is_regular_file(out_path):
            cmd_read([out_path])
        else:
            print(f"  (verify skipped: {out_path} is not a regular file)")
        return

    if sz == BT_FILE_SIZE:
        if bt_mac is None:
            die(f"input {in_path} is a BT_Addr file ({sz} bytes); pass --bt MAC (got --wifi only)")
        if wifi_mac is not None:
            die(f"input {in_path} is a BT_Addr file ({sz} bytes); --wifi not applicable. Pass the WIFI file ({WIFI_FILE_SIZE} bytes) instead, or pass a partition image to patch both at once.")
        if out_path is None:
            base, ext = os.path.splitext(in_path)
            out_path = f"{base}_patched{ext}" if ext else f"{in_path}.patched"
        write_output(out_path, patch_bt(data, bt_mac))
        print(f"Wrote {out_path}: BT={format_mac(bt_mac)}")
        if is_regular_file(out_path):
            cmd_read([out_path])
        else:
            print(f"  (verify skipped: {out_path} is not a regular file)")
        return

    if sz == WIFI_FILE_SIZE:
        if wifi_mac is None:
            die(f"input {in_path} is a WIFI file ({sz} bytes); pass --wifi MAC (got --bt only)")
        if bt_mac is not None:
            die(f"input {in_path} is a WIFI file ({sz} bytes); --bt not applicable. Pass the BT_Addr file ({BT_FILE_SIZE} bytes) instead, or pass a partition image to patch both at once.")
        if out_path is None:
            base, ext = os.path.splitext(in_path)
            out_path = f"{base}_patched{ext}" if ext else f"{in_path}.patched"
        write_output(out_path, patch_wifi(data, wifi_mac))
        print(f"Wrote {out_path}: WIFI={format_mac(wifi_mac)}")
        if is_regular_file(out_path):
            cmd_read([out_path])
        else:
            print(f"  (verify skipped: {out_path} is not a regular file)")
        return

    die(f"file {in_path} is {sz} bytes; expected {BT_FILE_SIZE} (BT_Addr), {WIFI_FILE_SIZE} (WIFI), or > 1 MiB (partition image)")


def main():
    if len(sys.argv) < 2:
        die("usage: mac_tool.py read <file> | write <file> [--bt MAC] [--wifi MAC] [-o output]")
    cmd = sys.argv[1]
    args = sys.argv[2:]
    if cmd == 'read':
        cmd_read(args)
    elif cmd == 'write':
        cmd_write(args)
    else:
        die(f"unknown command {cmd!r}; expected 'read' or 'write'")


if __name__ == '__main__':
    main()
