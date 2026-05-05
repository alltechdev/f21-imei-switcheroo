# `mac_tool.py` — reference

Reads and writes the WiFi MAC and Bluetooth address inside an MTK NVRAM `BT_Addr` (440-byte) or `WIFI` (2050-byte) file — either as a standalone file or embedded in a larger partition image (e.g. an `nvram` or `nvdata` dump). No on-device logic; `live_patch_mac.sh` (or any user script) is responsible for getting the bytes off and onto the device.

The file is short by design. The MTK NVRAM trailer-byte algorithm (the only non-trivial piece) is in `compute_checksum`; everything else is byte-shuffling and CLI plumbing. See [`wifi_bt_reverse_engineering.md`](wifi_bt_reverse_engineering.md) for the algorithm's provenance.

> **Scope reminder.** `mac_tool.py` is exercised directly on partition samples from F21 Pro, F25, and TIQ M5 (round-trip identity for all three; see `tests/mac_tool_edge_cases.sh`). End-to-end hardware verification with `live_patch_mac.sh` was run on **F21 Pro** and **TIQ M5** here; F25 hardware verification is through the Java port [`flipphoneguy/mtk-imei-switcheroo-app`](https://github.com/flipphoneguy/mtk-imei-switcheroo-app) (bit-equivalent to `mac_tool.py`'s primitives and to the WCS sync), since we don't have F25 hardware on this side. The format constants below match what's on F21 Pro's `/vendor/lib64/libnvram.so`; the F25 WIFI header variant (`01 00 09 00`) is supported via `WIFI_HDR_VARIANTS`. On Android 12+ devices, the WiFi runtime additionally requires invalidating Android's cached factory WiFi MAC in `WifiConfigStore.xml` after the file write — `live_patch_mac.sh` does this; the offline + `fastboot flash` path does not (see [`live_patch_mac.md` § sync_android_wifi_factory_mac](live_patch_mac.md#sync_android_wifi_factory_macnew_mac) for the limitation).

## Imports

```python
import os
import sys
```

stdlib only — no `pycryptodome` or `hashlib`. The format is plaintext.

## Constants

```python
BT_FILE_SIZE   = 440
WIFI_FILE_SIZE = 2050

BT_MAC_OFFSET         = 0x00
BT_TRAILER_SIG        = bytes.fromhex('60002310000007000000050703040000')
BT_TRAILER_SIG_OFFSET = 0x06

WIFI_HDR_VARIANTS = (
    bytes.fromhex('01000800'),    # F21 Pro, TIQ M5, F30 stock
    bytes.fromhex('01000900'),    # F25
)
WIFI_HDR_LEN    = 4
WIFI_MAC_OFFSET = 0x04

TRAILER_MAGIC = 0xAA
```

| Constant | Meaning |
|---|---|
| `BT_FILE_SIZE` / `WIFI_FILE_SIZE` | The exact byte sizes; both a validity check and the slice stride for partition-image scans. |
| `BT_MAC_OFFSET` / `WIFI_MAC_OFFSET` | Where the 6-byte MAC lives in each file — `[0:6]` for BT_Addr, `[4:10]` for WIFI (behind the 4-byte WIFI header). |
| `BT_TRAILER_SIG` | The 16-byte fixed fingerprint that follows the BT MAC (`60 00 23 10 00 00 07 00 00 00 05 07 03 04 00 00`). Does not appear elsewhere in nvdata, so it's an unambiguous signature for finding BT_Addr copies in a partition image. |
| `WIFI_HDR_VARIANTS` | The set of accepted 4-byte WIFI headers. Both observed values share the prefix `01 00 …. 00` and differ only in the byte at offset 2: `08` for F21 Pro / TIQ M5 / F30 stock, `09` for F25. The trailer-checksum algorithm is identical across both variants. New device families with a different byte at offset 2 should add their value to this tuple after the format is verified offline (round-trip identity test). |
| `TRAILER_MAGIC` | The constant `0xaa` byte that prefixes the 1-byte trailer checksum. Verified by `NVM_CheckFile` in `libnvram.so`. |

See [`wifi_bt_reverse_engineering.md` § File layouts](wifi_bt_reverse_engineering.md#file-layouts) for the byte-by-byte map of each file.

## Helpers

### `parse_mac(s)` / `format_mac(b)`

`parse_mac` accepts six colon- or dash-separated hex bytes (`02:11:22:33:44:55` or `02-11-22-33-44-66`); anything else dies with an explicit message. `format_mac` is the inverse and always returns lowercase colon-separated.

### `compute_checksum(data)`

```python
def compute_checksum(data):
    cs = 0
    for i, b in enumerate(data[:-2]):
        cs = ((cs + b) if i % 2 == 0 else (cs ^ b)) & 0xff
    return cs
```

The MTK NVRAM trailer-byte algorithm: walk the file *excluding* the last 2 bytes (the trailer itself), maintain an 8-bit running checksum, **ADD** on even-indexed bytes and **XOR** on odd-indexed bytes. The trailer byte at `data[-1]` is what `data[-2]` (always `0xaa`) is followed by, and that byte must equal `compute_checksum(data) & 0xff` for the runtime `nvram_daemon`'s `NVM_CheckFile` to consider the file valid.

Recovered by disassembling `_Z18NVM_ComputeCheckNoPKcPcb` in `/vendor/lib64/libnvram.so`. The Python is a direct translation of the ARM64 loop body. See [`wifi_bt_reverse_engineering.md` § Step 3 — Disassembling NVM_ComputeCheckNo](wifi_bt_reverse_engineering.md#step-3--disassembling-nvm_computecheckno) for the assembly walkthrough.

### `trailer_valid(data)`

Returns `True` iff the file's 2-byte trailer is `(0xaa, compute_checksum(data))`. Used by `find_bt_copies` / `find_wifi_copies` to filter out partition-image hits whose trailer is corrupt or who happen to match the signature byte-for-byte by accident.

## Read / write primitives

### `patch_bt(data, new_mac)` / `patch_wifi(data, new_mac)`

Both:

1. Validate the input is the expected size (440 or 2050).
2. Validate the relevant signature (BT_TRAILER_SIG at offset 6 for BT, any of `WIFI_HDR_VARIANTS` at offset 0 for WIFI). On mismatch, die — the file is structurally not what we expect, and refusing to patch is safer than blindly editing.
3. Splice the new MAC at the slot's offset (`[0:6]` for BT, `[4:10]` for WIFI).
4. Set `data[-2] = 0xaa`, `data[-1] = compute_checksum(data)`.
5. Return the new bytes.

Step 4 is the load-bearing one — without it the daemon reverts at boot. Step 1+2's signature checks rule out catastrophic mistakes (passing the wrong file type for the slot, or corrupting a non-MAC region).

### `read_bt_mac(data)` / `read_wifi_mac(data)`

Inverse: validate size and signature, return the 6 MAC bytes (or `None` if validation fails). The signature check is what `cmd_read` falls back on to print "(not found)" rather than printing 6 bytes from a junk file.

## Partition-image helpers

### `find_bt_copies(img)` / `find_wifi_copies(img)`

Walk `img` for every occurrence of the relevant signature (`BT_TRAILER_SIG` for BT; any of `WIFI_HDR_VARIANTS` for WIFI), reconstruct the candidate 440- or 2050-byte slice, and check `trailer_valid`. Return `[(offset, blob), ...]` for every valid hit, sorted by offset, with no duplicates if multiple WIFI variants match the same offset (impossible in practice — the variant bytes differ — but the dedup is in place anyway). A "hit" requires *both* the signature *and* a self-consistent `aa CC` trailer — that's why a partition image with stale fragments doesn't trip the patcher.

On the live F21 Pro `nvram` partition (BinRegion mirror, 64 MiB), each finder returns exactly **one** copy each (BT at offset `0x2003c`, WIFI at offset `0x201f4`). On larger images that contain multiple fragments (ext4 journal/COW remnants from an extracted `nvdata` partition) the finders return one entry per valid copy, and `cmd_write` patches all of them in place.

### `is_partition_image(path)`

`False` for files exactly 440 or 2050 bytes (standalone). `True` for files larger than 1 MiB. Anything else falls through and fails with an explicit "is not BT_Addr / WIFI / partition image" error.

## CLI

### `cmd_read(args)`

`mac_tool.py read <file>` — auto-detects standalone vs partition-image and prints either a single line (`BT_Addr: …` or `WIFI MAC: …`) or two lines for partition images including a copy count and the first hit's offset:

```
$ python3 mac_tool.py read live_nvram.img
BT_Addr  (1 copies, first @ 0x2003c): 10:df:8b:XX:YY:ZZ
WIFI MAC (1 copies, first @ 0x201f4): 10:df:8b:UU:VV:WW
```

### `cmd_write(args)`

`mac_tool.py write <file> [--bt MAC] [--wifi MAC] [-o output]` — depending on input shape:

- **Standalone BT_Addr** (440 B). `--bt MAC` is required, `--wifi` is rejected. `--bt` patches the MAC and recomputes the trailer.
- **Standalone WIFI** (2050 B). Symmetric — `--wifi MAC` required, `--bt` rejected.
- **Partition image** (>1 MiB). `--bt` and/or `--wifi` accepted in any combination; passes either through, patches every header- or signature-matching copy in place, refuses if a requested slot has zero copies in the image.

If `-o` is omitted, the default is `<base>_patched<ext>` (or `<file>.patched` for files without an extension).

After every successful write to a regular file the tool re-reads the output via `cmd_read` so the output ends with a self-verify line — same convention as `imei_tool.py`'s `_print_both_imeis`. When the output path is not a regular file (`/dev/null`, a character device, a named pipe), `cmd_read` would fail trying to size-check it, so the tool prints `(verify skipped: <path> is not a regular file)` instead and exits 0.

### Error surface

All input errors die with a single line beginning `Error: …`. Exit code 0 on success, 1 on any failure. Every error message includes both what was observed and what was expected (with a hint when applicable). The errors verified by the regression sweep `tests/mac_tool_edge_cases.sh`:

| Trigger | Message excerpt |
|---|---|
| File missing | `file not found: <path>` |
| Empty file (0 bytes) | `file is 0 bytes; expected 440 (BT_Addr), 2050 (WIFI), or > 1 MiB (partition image)` |
| 440-byte file w/o BT trailer fingerprint | `file is 440 bytes (BT_Addr-shaped) but the trailer signature at offset 0x6 does not match …` |
| 2050-byte file w/o WIFI header magic | `file is 2050 bytes (WIFI-shaped) but the header magic does not match 01000800 or 01000900` |
| Other non-matching size | `file is N bytes; expected 440 (BT_Addr), 2050 (WIFI), or > 1 MiB (partition image)` |
| Bad MAC, wrong number of parts | `MAC must be six colon-separated hex bytes (e.g. 02:11:22:33:44:55), got '…' (N parts)` |
| Bad MAC, non-hex character | `MAC contains non-hex characters: '…' (expected 0-9, a-f, A-F)` |
| MAC with embedded / leading / trailing whitespace | rejected (split-fail or non-hex) |
| `--bt` for WIFI input | `input … is a WIFI file (2050 bytes); pass --wifi MAC (got --bt only)` (mirror for `--wifi` on BT) |
| `--bt` and `--wifi` both passed for a single-record file | `--wifi not applicable. Pass the WIFI file (2050 bytes) instead, or pass a partition image …` (mirror) |
| `write` without any `--bt`/`--wifi` | `at least one of --bt MAC or --wifi MAC is required` |
| `--bt` / `--wifi` / `-o` with no value | `--bt requires a MAC argument (e.g. --bt 02:11:22:33:44:55)` (mirrors) |
| Unknown long flag | `unexpected argument '<flag>' (already have input file '<path>')` |
| Unknown subcommand | `unknown command '<cmd>'; expected 'read' or 'write'` |
| `write` to partition image with `--bt` and zero matching BT copies | `no valid BT_Addr record found in <path> (N bytes scanned). Looked for <hex> at offset 6 of a 440-byte record …` (mirror for WIFI) |
| Output path's directory doesn't exist | `cannot write <path>: No such file or directory` |

### `read` of a partition image with corrupted records

When `find_bt_copies` / `find_wifi_copies` find a signature hit but the trailer's `aa CC` doesn't validate (corrupted file or signature appearing in unrelated data), the copy is silently skipped — `read` of an image where every signature hit is corrupt prints `(not found — no valid 440-byte record with a matching aa+checksum trailer)` rather than returning a stale MAC. Same handling for an image whose only signature hit is at an offset where the full record won't fit before EOF.

### Output to non-regular files

`write` accepts `-o /dev/null` (or any character device, named pipe, etc.). The bytes are written, but the auto-verify step that re-reads the output is skipped — instead of failing the auto-read, the script prints `(verify skipped: <path> is not a regular file)` and exits 0. Useful for scripted "compute the trailer byte without producing an artifact" workflows.

### Regression sweep

`tests/mac_tool_edge_cases.sh` runs every case above plus round-trip identity (patch → patch back → byte-equal to original) and the partition-image edge cases. Requires the live samples in `tmp/wifi_bt_re/` (a pulled `BT_Addr.bin`, `WIFI.bin`, and `live_nvram.img` — produced as a side effect of running `live_patch_mac.sh` and pulling `nvram` once). Multi-device round-trip cases for TIQ M5 and F25 also run automatically when `tmp/tiqm5/nvdata.bin` and `tmp/f25/nvdata.bin` are present. **38 cases** when all three sample sets are present (33 base + 1 TIQ M5 read + 1 TIQ M5 round-trip + 2 F25 read + 1 F25 round-trip), exit 0 on full pass.

## Quick recipes

```bash
python3 mac_tool.py read BT_Addr
python3 mac_tool.py read WIFI
python3 mac_tool.py read nvdata.img

python3 mac_tool.py write BT_Addr --bt 02:11:22:33:44:55 -o BT_Addr.patched
python3 mac_tool.py write WIFI    --wifi 02:11:22:33:44:66 -o WIFI.patched

python3 mac_tool.py write nvdata.img --bt 02:11:22:33:44:55 \
                                     --wifi 02:11:22:33:44:66 \
                                     -o nvdata_patched.img
```

Use a freshly-pulled `nvdata.img` (`dd if=/dev/block/by-name/nvdata of=/sdcard/nvdata.img bs=1M` then `adb pull`) for the partition-image flow — that's the path verified end-to-end via `fastboot flash nvdata`. `nvram.img` (the `nvram` partition) also contains a single signature-matching record each, but flashing it isn't part of the verified offline path on this branch.

For the live-device flow that wraps these calls (pull → patch → push → reboot → verify), see [`live_patch_mac.md`](live_patch_mac.md).
