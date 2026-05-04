# `live_patch_mac.sh` — reference

Host-side bash that drives a live, rooted MTK device through ADB: pulls the `BT_Addr` and `WIFI` files, hands each to `mac_tool.py` to rewrite, pushes them back through `su`, offers to reboot. Mirrors the structure of `live_patch.sh` (the IMEI side) — short and linear; the binary-format and checksum knowledge lives in `mac_tool.py`, this script is plumbing.

> **Scope reminder:** verified live on **F21 Pro / Android 11 + Magisk only**. Other MT67xx devices (F25, TIQ M5, …) are unverified for WiFi/BT MAC patching at this time.

## Header

```bash
#!/bin/bash
```

`#!/bin/bash` rather than `/bin/sh` because the script uses `read -p`. Same convention as `live_patch.sh`.

## Configuration

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$SCRIPT_DIR/mac_tool.py"

BT_PATH="/mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr"
WIFI_PATH="/mnt/vendor/nvdata/APCFG/APRDEB/WIFI"
DEVICE_TMP="/data/local/tmp"

WORK="$(pwd)/tmp"
mkdir -p "$WORK"
BT_BACKUP="$WORK/backup_BT_Addr.bin"
WIFI_BACKUP="$WORK/backup_WIFI.bin"
BT_PATCHED="$WORK/patched_BT_Addr.bin"
WIFI_PATCHED="$WORK/patched_WIFI.bin"
```

| Variable | Purpose |
|---|---|
| `SCRIPT_DIR` | Absolute dir of `live_patch_mac.sh`, resolves under symlinks / relative invocations. |
| `TOOL` | `mac_tool.py` next to the script. |
| `BT_PATH` / `WIFI_PATH` | On-device paths. Hardcoded — these are the canonical MTK locations for the F21 Pro / MT6761 platform. |
| `DEVICE_TMP` | On-device staging dir (`/data/local/tmp`, world-writable, su-friendly). |
| `WORK` | Host-side staging dir, always `./tmp/` relative to the user's CWD. Idempotent. |
| `BT_BACKUP` / `WIFI_BACKUP` | The pulled files (one each, even if the user only patches one). Always 440 / 2050 bytes if the pull succeeded. |
| `BT_PATCHED` / `WIFI_PATCHED` | The patched files; only created if the user proceeded with the corresponding patch. |

No cleanup trap — `tmp/` is gitignored and the staged files are deliberately preserved so the user can inspect, restore, or diff against the live device.

## Helpers

### `die(msg)`

```bash
die() { echo "Error: $1" >&2; exit 1; }
```

Same as `live_patch.sh`.

### `pull_to_host(src, stage, dest)`

Stages a system-owned file at `/sdcard/<stage>` (so the `shell` ADB user can read it) and pulls it via the binary-safe `adb pull` SYNC protocol. Equivalent to the IMEI script's pull idiom.

```bash
adb shell su -c "cp '$src' '$stage' && chmod 644 '$stage'" </dev/null \
    || die "Cannot stage $src at $stage. Verify the file exists: adb shell su -c 'ls -la $src'"
adb pull "$stage" "$dest" >/dev/null 2>&1 \
    || die "adb pull of $stage to $dest failed. Try the pull manually: adb pull $stage"
adb shell su -c "rm '$stage'" </dev/null >/dev/null 2>&1
```

Why `adb pull` rather than `adb exec-out su -c "cat …"`: on Android 13 / Magisk combinations the latter injects `\r` before every `\n` in the binary stream (verified on TIQ M5 in the IMEI work). The `cp via su /sdcard + adb pull` form sidesteps this — `cp` writes the bytes to the filesystem directly, and `adb pull` uses adb's SYNC protocol, neither of which involve a PTY. Verified binary-safe on F21 Pro / Android 11 + Magisk in this script. Each error message names what was tried and a follow-up diagnostic command.

### `push_replace(src, name, dest, group)`

Replaces a destination file on the device with one we just pushed. Args are: host source, on-device staging name, final destination, `chown` group (`bluetooth` for `BT_Addr`, `system` for `WIFI`).

```bash
adb push "$src" "$DEVICE_TMP/$name" </dev/null >/dev/null 2>&1 \
    || die "adb push of $src to $DEVICE_TMP/$name failed. Is /data/local/tmp writable? Try: adb shell ls -ld /data/local/tmp"
adb shell su -c "mount -o remount,rw /mnt/vendor/nvdata" </dev/null >/dev/null 2>&1
adb shell su -c "mount -o remount,rw /" </dev/null >/dev/null 2>&1
adb shell su -c "cp '$DEVICE_TMP/$name' '$dest'" </dev/null \
    || die "cp $DEVICE_TMP/$name -> $dest failed. /mnt/vendor/nvdata may be read-only; check: adb shell su -mm -c 'mount | grep nvdata'"
adb shell su -c "chmod 660 '$dest'" </dev/null >/dev/null 2>&1
adb shell su -c "chown root:$group '$dest'" </dev/null >/dev/null 2>&1
adb shell su -c "rm '$DEVICE_TMP/$name'" </dev/null >/dev/null 2>&1
```

Same three-things-deliberate as `live_patch.sh`: `</dev/null` on every adb invocation (so piping the script's stdin through prompts doesn't get consumed by adb), defensive `mount -o remount,rw` for hypothetical Magisk/SELinux configurations that route writes through the root namespace, and separate `adb shell su -c` calls (chained `cp && chmod && chown && rm` was observed to fail in the IMEI work). Only `cp` dies on failure; chmod/chown/rm are best-effort. All on-device path arguments are single-quoted within the `su -c` string to keep the shell parsing predictable even though `BT_PATH` / `WIFI_PATH` / `DEVICE_TMP` have no whitespace.

The mode `0660` and `chown root:<group>` match the original on-device ownership: `BT_Addr` is `root:bluetooth`, `WIFI` is `root:system`. The kernel and userspace consumers verify the mode at boot, so this matters even if the file content is otherwise correct.

## Preflight checks

```bash
command -v adb >/dev/null 2>&1     || die "adb not found in PATH. Install Android platform-tools."
command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH. Install Python 3.6 or newer."
[ -f "$TOOL" ]                     || die "mac_tool.py not found next to this script (expected at $TOOL)"

adb_state=$(adb devices 2>/dev/null | awk 'NR>1 && NF{print $2}' | head -1)
if [ -z "$adb_state" ]; then
    die "No ADB device detected. Plug in the device and ensure USB debugging is enabled."
elif [ "$adb_state" != "device" ]; then
    die "ADB device is in state '$adb_state', not 'device'. Common fixes: …"
fi

adb shell su -c id </dev/null 2>/dev/null | grep -q "uid=0" \
    || die "su -c id did not return uid=0. The device must be rooted and root must be granted to the 'shell' user. …"
echo "Device is rooted, continuing..."
```

Five gates, in order: host has `adb`, host has `python3`, `mac_tool.py` is sitting next to the script (so the user didn't accidentally run a copy of `live_patch_mac.sh` without its dependency), an ADB device is present and in the `device` state (not `unauthorized` / `recovery` / `offline`), and `su -c id` returns `uid=0`. Each gate dies with a specific message naming the observed condition and the suggested fix; the messages are listed verbatim in the [Failure modes](#failure-modes) table below. Without the third and fourth gates, a missing `mac_tool.py` or an unauthorized device would surface much later as a cryptic Python or `adb pull` error.

## Pull current state

```bash
pull_to_host "$BT_PATH"   "/sdcard/BT_Addr_pull" "$BT_BACKUP"
pull_to_host "$WIFI_PATH" "/sdcard/WIFI_pull"    "$WIFI_BACKUP"

bt_size=$(wc -c < "$BT_BACKUP")
wf_size=$(wc -c < "$WIFI_BACKUP")
[ "$bt_size" -eq 440 ]  || die "BT_Addr is $bt_size bytes (expected 440)"
[ "$wf_size" -eq 2050 ] || die "WIFI is $wf_size bytes (expected 2050)"
```

Defense in depth: validate exact byte counts before feeding to `mac_tool.py`. If the pull was corrupted, fail here rather than silently producing a malformed patched file.

```bash
bt_now=$(python3 "$TOOL" read "$BT_BACKUP" | awk '{print $2}')
wf_now=$(python3 "$TOOL" read "$WIFI_BACKUP" | awk '{print $3}')
echo "  Current BT_Addr : $bt_now"
echo "  Current WIFI MAC: $wf_now"
echo ""
```

Hand each backup to `mac_tool.py read` and pull the MAC string out of the printed line. The script doesn't conditionally branch on these values — they're for the user to see what's currently set before being asked to change it.

## Adaptive prompts

```bash
read -p "Change BT MAC? [y/N] " ans
case "$ans" in
    y|Y)
        read -p "  New BT MAC (xx:xx:xx:xx:xx:xx): " new_bt
        echo "$new_bt" | grep -qiE '^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$' \
            || die "BT MAC '$new_bt' is not six colon- or dash-separated hex bytes (e.g. 02:11:22:33:44:55)"
        echo "  Patching BT_Addr..."
        python3 "$TOOL" write "$BT_BACKUP" --bt "$new_bt" -o "$BT_PATCHED" \
            || die "BT_Addr patch failed — see mac_tool.py output above. The pulled backup is at $BT_BACKUP for inspection."
        push_replace "$BT_PATCHED" BT_Addr.new "$BT_PATH" bluetooth
        ;;
    *) echo "  BT_Addr unchanged." ;;
esac
```

(WiFi block is symmetric — same shape, `--wifi` instead of `--bt`, `system` instead of `bluetooth`.)

The regex check is a UX nicety — `mac_tool.py write` re-validates with the same constraint and dies with its own message if the format is bad, so this exists only to fail before the (slow) round-trip through `python3 + adb`.

Default-abort on each prompt: pressing Enter or anything other than `y`/`Y` keeps the corresponding file unchanged. The script is safe to use just to read the current values.

## Reboot

```bash
if [ ! -f "$BT_PATCHED" ] && [ ! -f "$WIFI_PATCHED" ]; then
    echo "No changes made."
    exit 0
fi

read -p "Reboot device now? [y/N] " ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    adb reboot
fi
```

If neither patch ran, exit cleanly without prompting for a reboot. Otherwise prompt — the user might want to inspect the staged files before rebooting, or apply additional changes (e.g. an IMEI patch via `live_patch.sh`) in the same boot cycle.

The patched files are now on the device's filesystem, but the BT and WiFi stacks have the old values cached in memory. Only a reboot makes the new values live. The kernel WiFi driver in particular reads the WIFI file once at boot via the `wlan_assistant` initialization path; live re-loading is not supported.

## Failure modes

Every `die()` path has been triggered live and the resulting message captured. The driver `tests/live_patch_mac_preflight.sh` reproduces them all using real `adb` (against the live device) for the host-environment cases plus a small mocked `adb` (in `/tmp/fakebin`, transient) for the device-side cases that would otherwise need physical disruption to set up. Re-running it asserts each error message comes out as documented.

| Symptom | Trigger | Suggested fix |
|---|---|---|
| `Error: adb not found in PATH. Install Android platform-tools.` | Host without `adb` installed (verified via `PATH=/empty`) | Install `adb` and put it on `PATH`. |
| `Error: python3 not found in PATH. Install Python 3.6 or newer.` | Host without `python3` (verified via `PATH=$(dirname adb)`) | Install Python 3. |
| `Error: mac_tool.py not found next to this script (expected at <path>)` | Renamed/moved `mac_tool.py` (verified via temporary `mv mac_tool.py mac_tool.py.bak`) | Restore the file beside the script. |
| `Error: No ADB device detected. Plug in the device and ensure USB debugging is enabled.` | No device connected (verified via mocked `adb devices` returning empty list) | Plug in, enable USB debugging. |
| `Error: ADB device is in state 'unauthorized', not 'device'. Common fixes: …` | Fingerprint not accepted, device in recovery, or offline (verified via mocked `adb devices` returning state `unauthorized`) | Accept the fingerprint on the phone, exit recovery, or reconnect USB. |
| `Error: su -c id did not return uid=0. The device must be rooted and root must be granted to the 'shell' user. …` | Device not rooted or root denied (verified via mocked `adb shell` returning `uid=2000(shell)`) | Open Magisk → Superuser, allow root for `shell`. |
| `Error: Cannot stage <path> at /sdcard/.... Verify the file exists: adb shell su -c 'ls -la <path>'` | On-device path missing or `cp` via `su` blocked (verified via mocked `adb shell` returning failure on the staging cp) | Run the suggested `ls -la`. |
| `Error: adb pull of /sdcard/... to <path> failed. Try the pull manually: adb pull <path>` | Stage cp succeeded but `adb pull` failed (verified via mocked `adb pull` returning exit 1) | Try the manual pull. |
| `Error: BT_Addr pulled as N bytes, expected 440. …` (mirror for WIFI 2050) | Pull returned a wrong-sized file (verified via mocked `adb pull` writing a 5- or 10-byte file) | Run the diagnostic in the error: `adb shell su -c 'wc -c <path>'`. |
| `Error: BT MAC '<mac>' is not six colon- or dash-separated hex bytes (e.g. 02:11:22:33:44:55)` (mirror for WiFi 02:11:22:33:44:66) | Malformed MAC typed at the prompt (verified by feeding `not-a-mac` and `bogus`) | Re-run, give a valid MAC. |
| `Error: BT_Addr patch failed — see mac_tool.py output above. The pulled backup is at <path> for inspection.` (mirror for WIFI) | `mac_tool.py write` returned non-zero (verified via a temporarily-replaced `mac_tool.py` that prints an error and exits 1) | Read the `mac_tool.py` error printed just above. |
| `Error: cp /data/local/tmp/BT_Addr.new -> <path> failed. /mnt/vendor/nvdata may be read-only; check: adb shell su -mm -c 'mount \| grep nvdata'` (mirror for WIFI) | Final cp into `/mnt/vendor/nvdata/APCFG/APRDEB` failed (verified via mocked `adb shell` returning exit 1 on the final cp) | Run the suggested mount diagnostic. |

### Happy-path branches (also verified live)

| Outcome | Trigger | Behavior |
|---|---|---|
| `BT_Addr unchanged. WIFI unchanged. No changes made.` (clean exit, no reboot prompt) | Both prompts answered `n` | Script exits 0 without offering reboot. |
| Only BT patched (`tmp/patched_BT_Addr.bin` exists, `tmp/patched_WIFI.bin` does not) | First prompt `y`, second prompt `n` | The patched BT_Addr is pushed to the device; WIFI is left as it was. |
| Only WiFi patched (`tmp/patched_WIFI.bin` exists, `tmp/patched_BT_Addr.bin` does not) | First prompt `n`, second prompt `y` | Mirror of the above. |
| Both patched | Both prompts `y` | Both pushed. End-to-end reboot verification confirms BT directly via `settings get secure bluetooth_address` (byte-matches `BT_Addr[0:6]`); WiFi indirectly via the WIFI file persisting across reboot byte-for-byte and the daemon's `NVM_CheckFile` not triggering rollback. Android's per-interface MAC randomization on `wlan0` and `p2p0` means there's no direct `wlan0/address`-level runtime read of the patched MAC on this Android version — the kernel WiFi driver does load the patched bytes (`wlan_assistant` is the documented consumer) but they're masked behind the netdev randomization layer. |

## Artifacts after a run

```
tmp/
├── backup_BT_Addr.bin     ← always (440 B)
├── backup_WIFI.bin        ← always (2050 B)
├── patched_BT_Addr.bin    ← only if BT patch confirmed
└── patched_WIFI.bin       ← only if WiFi patch confirmed
```

Both backups exist after any run that got past the pull step. The patched files exist only if the user proceeded with the corresponding patch and gave a valid MAC. All four files are useful for **recovery** (push the backup back if something boots wrong), **diff** (`cmp -l` shows which bytes changed — only the 6-byte MAC and the 1-byte trailer), or **auditing** (confirm what was written). Re-running overwrites; `rm -rf tmp/` for a clean slate.

## Why APRDEB-only is enough

A reasonable concern is "does a runtime patch to the APRDEB files survive even though the BinRegion mirrors (`AllFile` and the `nvram` partition) still hold the old MAC?" Yes, on F21 Pro: the runtime consumers (BT HAL, `wlan_assistant`) read directly from APRDEB at boot, and the `nvram_daemon`'s `NVM_CheckFile` path validates *those* files against their own embedded `aa CC` trailers — not against BinRegion. If the trailer is correct (which `mac_tool.py` ensures), the daemon does not invoke its `NVM_RestoreFromBinRegion_OneFile` path and the files persist as written. See [`wifi_bt_reverse_engineering.md` § What does *not* need to be patched](wifi_bt_reverse_engineering.md#what-does-not-need-to-be-patched) for the byte-level confirmation.

If the user later does a factory reset that wipes APRDEB, the daemon will re-populate APRDEB from BinRegion (which still has the old MAC) — at which point this script can be re-run.
