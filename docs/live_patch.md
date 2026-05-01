# `live_patch.sh` — reference

Host-side bash that drives a live, rooted MTK device through ADB: pulls the encrypted IMEI file, hands it to `imei_tool.py` to rewrite, pushes it back through `su`, offers to reboot. Short and linear; the binary-format and crypto knowledge lives in `imei_tool.py`, this script is plumbing. Live-tested on F21 Pro; per-device verification status lives in the top-level [README](../README.md#verification-status).

## Header

```bash
#!/bin/bash
```

`#!/bin/bash` rather than `/bin/sh` because the script uses `read -p`. No other comments — the script body is self-documenting and this doc is the prose reference.

## Configuration

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$SCRIPT_DIR/imei_tool.py"

IMEI_PATH="/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001"
DEVICE_TMP="/data/local/tmp"

WORK="$(pwd)/tmp"
mkdir -p "$WORK"
BACKUP="$WORK/backup_LD0B_001.bin"
PATCHED="$WORK/patched_LD0B_001.bin"
```

| Variable | Purpose |
|---|---|
| `SCRIPT_DIR` | Absolute dir of `live_patch.sh`, resolves correctly under symlinks / relative invocations. |
| `TOOL` | `imei_tool.py` next to the script. |
| `IMEI_PATH` | On-device path to `LD0B_001`. Hardcoded — the canonical MTK location. |
| `DEVICE_TMP` | On-device staging dir (`/data/local/tmp`, world-writable, su-friendly). |
| `WORK` | Host-side staging dir, always `./tmp/` relative to the user's CWD. Idempotent. |
| `BACKUP` / `PATCHED` | The pulled file and the patched file; both stay in `tmp/` after the run for inspection. |

No cleanup trap — `tmp/` is gitignored and the staged files are deliberately preserved so the user can inspect or restore.

## Helpers

### `die(msg)`

```bash
die() { echo "Error: $1" >&2; exit 1; }
```

### `push_replace(src, name, dest, group)`

Replaces a destination file on the device with one we just pushed. Args are: host source, on-device staging name, final destination, `chown` group.

```bash
adb push "$src" "$DEVICE_TMP/$name"            # push to staging
adb shell su -c "mount -o remount,rw /mnt/vendor/nvdata"   # defensive remount
adb shell su -c "mount -o remount,rw /"        # defensive remount (root)
adb shell su -c "cp $DEVICE_TMP/$name $dest"   # install (only step that dies on failure)
adb shell su -c "chmod 660 $dest"              # fix mode
adb shell su -c "chown root:$group $dest"      # fix ownership
adb shell su -c "rm $DEVICE_TMP/$name"         # clean up staging
```

**Three things in this function are deliberate, not noise:**

1. **`</dev/null` on every adb invocation.** When `live_patch.sh` is invoked with piped stdin (`printf 'y\n…\nn\n' | ./live_patch.sh`), `adb shell` will silently consume bytes off that pipe instead of letting `read -p` see them. Routing adb's stdin to `/dev/null` keeps the prompts working.

2. **Both `mount -o remount,rw` lines.** `/mnt/vendor/nvdata` is what we write to and is rw on the verified firmware (no-op there). `/` is included for hypothetical Magisk/SELinux configurations that route writes through the root namespace. Both have stdout and stderr discarded — failures don't kill the script; if the cp afterwards still can't write, that's where we surface the error.

3. **Separate `adb shell su -c` calls** rather than a chained `su -c "cp && chmod && chown && rm"`. We hit a bug earlier where chaining caused a permission-denied on the cp that worked when run alone. Splitting is bulletproof; the cost is three round-trips, imperceptible.

Only the cp dies on failure; chmod/chown/rm are best-effort (the file is already in place after cp).

## Preflight checks

```bash
adb devices 2>/dev/null | grep -q "device$" || die "No ADB device connected"
adb shell su -c id </dev/null 2>/dev/null | grep -q "uid=0" \
    || die "su -c failed: device must be rooted and root must be granted to adb shell"
echo "Device is rooted, continuing..."
```

Confirms an ADB device in the `device` state (not `unauthorized` / `recovery` / `offline`) and that `su -c id` returns `uid=0`. Without the second check, a non-rooted phone would reach the `cat $IMEI_PATH` and fail with a less-specific cat error instead of the explicit "must be rooted" message. The chatty success line is intentional — confirms the precheck happened so a later silent failure isn't misread.

## Pull current IMEI

```bash
adb exec-out su -c "cat $IMEI_PATH" > "$BACKUP" \
    || die "Cannot read $IMEI_PATH from device"
```

`adb exec-out` (not `adb shell`) is critical for binary transfers. `adb shell` allocates a PTY and applies CRLF translations that destroy binary blobs (any `\n` in the encrypted block becomes `\r\n`). `adb exec-out` pipes raw bytes. Stderr is *not* suppressed — if `cat` fails (e.g. wrong path on a non-F21 device), its specific error is shown above the script's own die message.

```bash
file_size=$(wc -c < "$BACKUP")
[ "$file_size" -eq 384 ] || die "LD0B_001 is $file_size bytes (expected 384) - pull may have corrupted the file"
```

Defense in depth: validate the pull is exactly 384 bytes before feeding it to `imei_tool.py`.

```bash
read_output=$(python3 "$TOOL" read "$BACKUP") || die "Read failed (imei_tool.py error above)"
echo "$read_output" | sed 's/^/  /'
echo ""

populated=$(echo "$read_output" | grep -cv '(empty)')
```

Hand the pulled file to `imei_tool.py read` once. The output is two lines (`IMEI 1: …` / `IMEI 2: …`); reprint indented for readability and keep the raw text in `$read_output` for the next step. `populated` counts the lines *not* matching `(empty)` — this is how the script tells dual-SIM (`populated == 2`) from single-SIM (`populated == 1`) without hardcoding a device list.

## Adaptive prompt

```bash
if [ "$populated" -ge 2 ]; then
    read -p "Change which IMEI? [1/2/n] " choice
    case "$choice" in
        1|2) slot="$choice" ;;
        *) echo "No changes made."; exit 0 ;;
    esac
else
    slot=1
    read -p "Change IMEI? [y/N] " ans
    case "$ans" in
        y|Y) ;;
        *) echo "No changes made."; exit 0 ;;
    esac
fi
```

Two prompt shapes selected by the slot count from the previous step:

- **Dual-SIM (`populated >= 2`)** — `Change which IMEI? [1/2/n]`. Anything other than `1` or `2` aborts cleanly. `slot` is set to the user's choice.
- **Single-SIM (`populated < 2`)** — the original `Change IMEI? [y/N]` flow; `slot` is hardcoded to `1`. Hitting Enter aborts.

Default-abort on both branches so a stray run can be aborted without writing anything; `live_patch.sh` is safe to use just to read the current IMEIs.

```bash
read -p "  New IMEI $slot (15 digits): " new_imei
echo "$new_imei" | grep -qE '^[0-9]{15}$' || die "IMEI must be exactly 15 digits"
echo "  Patching IMEI $slot..."
python3 "$TOOL" write "$BACKUP" "$new_imei" -s "$slot" -o "$PATCHED" \
    || die "Patch failed (imei_tool.py error above)"
push_replace "$PATCHED" LD0B_001 "$IMEI_PATH" system
```

The regex check is a UX nicety — `imei_tool.py write` re-validates the same constraint. The slot number is shown in the prompt (`New IMEI 1`, `New IMEI 2`) and passed through to `imei_tool.py write -s "$slot"`. `push_replace`'s last arg `system` matches the original ownership (`root:system`, mode `0660`).

```bash
read -p "Reboot device now? [y/N] " ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    adb reboot
fi
```

The IMEI is now in NVRAM, but the modem stack has the old value cached. Only a reboot makes the new IMEI live.

## Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: No ADB device connected` | Phone unplugged, USB debugging off, or `adb` not in `PATH`. | Plug in, enable USB debugging, accept the host fingerprint. |
| `Error: su -c failed: …` | Root prompt denied or phone isn't rooted. | Open Magisk → Superuser, allow root for the `shell` user. |
| `Error: Cannot read <path> from device` | The path is wrong or unreadable. The `cat` error above the die line shows specifically why. | Verify with `adb shell su -c "ls -la $IMEI_PATH"`. |
| `Error: LD0B_001 is N bytes (expected 384)` | Pull corrupted or wrong path. | Confirm path and re-run. |
| `Error: Read failed (imei_tool.py error above)` | `imei_tool.py read` rejected the pulled file (wrong size, bad LDI magic, missing dependency, …). The exact reason is printed above by `imei_tool.py`. | Read the line above; common cases: pull was truncated, or `pycryptodome` not installed. |
| `Error: IMEI must be exactly 15 digits` | Typo at the prompt. | Re-run. |
| `Error: Patch failed (imei_tool.py error above)` | `imei_tool.py write` failed. The exact reason is printed above by `imei_tool.py`. | Read the line above; common cases: invalid IMEI, output dir not writable, `pycryptodome` not installed. |
| `Error: cp LD0B_001 to … failed` | `/mnt/vendor/nvdata` mounted ro and both defensive remounts failed. | Inspect with `adb shell su -mm -c "mount | grep nvdata"`. |

## Artifacts after a run

```
tmp/
├── backup_LD0B_001.bin    # the pulled file before patching
└── patched_LD0B_001.bin   # the file we pushed back (only if you said "y")
```

Both are 384 bytes; decrypt either with `imei_tool.py read`. Useful for **recovery** (push the backup back if something boots wrong), **diff** (`cmp -l` shows which bytes changed — the 32-byte block at offset 0x40), or **auditing** (confirm what was written). Re-running overwrites; `rm -rf tmp/` for a clean slate.
