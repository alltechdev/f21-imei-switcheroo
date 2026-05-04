#!/bin/bash
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

die() { echo "Error: $1" >&2; exit 1; }

command -v adb >/dev/null 2>&1 || die "adb not found in PATH. Install Android platform-tools."
command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH. Install Python 3.6 or newer."
[ -f "$TOOL" ] || die "mac_tool.py not found next to this script (expected at $TOOL)"

push_replace() {
    local src="$1" name="$2" dest="$3" group="$4"
    adb push "$src" "$DEVICE_TMP/$name" </dev/null >/dev/null 2>&1 \
        || die "adb push of $src to $DEVICE_TMP/$name failed. Is /data/local/tmp writable? Try: adb shell ls -ld /data/local/tmp"
    adb shell su -c "mount -o remount,rw /mnt/vendor/nvdata" </dev/null >/dev/null 2>&1
    adb shell su -c "mount -o remount,rw /" </dev/null >/dev/null 2>&1
    adb shell su -c "cp '$DEVICE_TMP/$name' '$dest'" </dev/null \
        || die "cp $DEVICE_TMP/$name -> $dest failed. /mnt/vendor/nvdata may be read-only; check: adb shell su -mm -c 'mount | grep nvdata'"
    adb shell su -c "chmod 660 '$dest'" </dev/null >/dev/null 2>&1
    adb shell su -c "chown root:$group '$dest'" </dev/null >/dev/null 2>&1
    adb shell su -c "rm '$DEVICE_TMP/$name'" </dev/null >/dev/null 2>&1
}

pull_to_host() {
    local src="$1" stage="$2" dest="$3"
    adb shell su -c "cp '$src' '$stage' && chmod 644 '$stage'" </dev/null \
        || die "Cannot stage $src at $stage. Verify the file exists: adb shell su -c 'ls -la $src'"
    adb pull "$stage" "$dest" >/dev/null 2>&1 \
        || die "adb pull of $stage to $dest failed. Try the pull manually: adb pull $stage"
    adb shell su -c "rm '$stage'" </dev/null >/dev/null 2>&1
}

adb_state=$(adb devices 2>/dev/null | awk 'NR>1 && NF{print $2}' | head -1)
if [ -z "$adb_state" ]; then
    die "No ADB device detected. Plug in the device and ensure USB debugging is enabled."
elif [ "$adb_state" != "device" ]; then
    die "ADB device is in state '$adb_state', not 'device'. Common fixes: accept the host fingerprint on the phone (unauthorized), exit recovery (recovery), or reconnect USB (offline)."
fi

adb shell su -c id </dev/null 2>/dev/null | grep -q "uid=0" \
    || die "su -c id did not return uid=0. The device must be rooted and root must be granted to the 'shell' user. Open Magisk -> Superuser and allow root for 'shell'."
echo "Device is rooted, continuing..."

pull_to_host "$BT_PATH"   "/sdcard/BT_Addr_pull" "$BT_BACKUP"
pull_to_host "$WIFI_PATH" "/sdcard/WIFI_pull"    "$WIFI_BACKUP"

bt_size=$(wc -c < "$BT_BACKUP")
wf_size=$(wc -c < "$WIFI_BACKUP")
[ "$bt_size" -eq 440 ]  || die "BT_Addr pulled as $bt_size bytes, expected 440. Pull may have been corrupted (e.g. CRLF injection on Android 13 + Magisk over exec-out). The script uses cp + adb pull which is binary-safe; if this fails, inspect $BT_BACKUP and confirm the on-device path: adb shell su -c 'wc -c $BT_PATH'"
[ "$wf_size" -eq 2050 ] || die "WIFI pulled as $wf_size bytes, expected 2050. Same diagnostic: adb shell su -c 'wc -c $WIFI_PATH'"

bt_now=$(python3 "$TOOL" read "$BT_BACKUP" | awk '{print $2}')
wf_now=$(python3 "$TOOL" read "$WIFI_BACKUP" | awk '{print $3}')
echo "  Current BT_Addr : $bt_now"
echo "  Current WIFI MAC: $wf_now"
echo ""

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

read -p "Change WiFi MAC? [y/N] " ans
case "$ans" in
    y|Y)
        read -p "  New WiFi MAC (xx:xx:xx:xx:xx:xx): " new_wf
        echo "$new_wf" | grep -qiE '^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$' \
            || die "WiFi MAC '$new_wf' is not six colon- or dash-separated hex bytes (e.g. 02:11:22:33:44:66)"
        echo "  Patching WIFI..."
        python3 "$TOOL" write "$WIFI_BACKUP" --wifi "$new_wf" -o "$WIFI_PATCHED" \
            || die "WIFI patch failed — see mac_tool.py output above. The pulled backup is at $WIFI_BACKUP for inspection."
        push_replace "$WIFI_PATCHED" WIFI.new "$WIFI_PATH" system
        ;;
    *) echo "  WIFI unchanged." ;;
esac

if [ ! -f "$BT_PATCHED" ] && [ ! -f "$WIFI_PATCHED" ]; then
    echo "No changes made."
    exit 0
fi

read -p "Reboot device now? [y/N] " ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    adb reboot
fi
