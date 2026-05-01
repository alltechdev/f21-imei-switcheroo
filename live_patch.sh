#!/bin/bash
# Interactive IMEI changer for the rooted DuoQin F21 Pro via ADB.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$SCRIPT_DIR/imei_tool.py"

IMEI_PATH="/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001"
DEVICE_TMP="/data/local/tmp"

WORK="$(pwd)/tmp"
mkdir -p "$WORK"
BACKUP="$WORK/backup_LD0B_001.bin"
PATCHED="$WORK/patched_LD0B_001.bin"

die() { echo "Error: $1" >&2; exit 1; }

push_replace() {
    local src="$1" name="$2" dest="$3" group="$4"
    adb push "$src" "$DEVICE_TMP/$name" > /dev/null </dev/null || die "adb push $name failed"
    adb shell su -c "mount -o remount,rw /mnt/vendor/nvdata" </dev/null >/dev/null 2>&1
    adb shell su -c "mount -o remount,rw /" </dev/null >/dev/null 2>&1
    adb shell su -c "cp $DEVICE_TMP/$name $dest" </dev/null || die "cp $name to $dest failed"
    adb shell su -c "chmod 660 $dest" </dev/null
    adb shell su -c "chown root:$group $dest" </dev/null
    adb shell su -c "rm $DEVICE_TMP/$name" </dev/null
}

adb devices 2>/dev/null | grep -q "device$" || die "No ADB device connected"
adb shell su -c id </dev/null 2>/dev/null | grep -q "uid=0" \
    || die "su -c failed: device must be rooted and root must be granted to adb shell"
echo "Device is rooted, continuing..."

echo "Reading current IMEI from device..."
adb exec-out su -c "cat $IMEI_PATH" > "$BACKUP" 2>/dev/null || die "Cannot read LD0B_001 from device"

file_size=$(wc -c < "$BACKUP")
[ "$file_size" -eq 384 ] || die "LD0B_001 is $file_size bytes (expected 384) - pull may have corrupted the file"

current_imei=$(python3 "$TOOL" read "$BACKUP" 2>/dev/null | grep "IMEI:" | awk '{print $2}')

echo ""
echo "  Current IMEI: ${current_imei:-(empty)}"
echo ""

read -p "Change IMEI? [y/N] " ans
if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
    echo "No changes made."
    exit 0
fi

read -p "  New IMEI (15 digits): " new_imei
echo "$new_imei" | grep -qE '^[0-9]{15}$' || die "IMEI must be exactly 15 digits"
echo "  Patching IMEI..."
python3 "$TOOL" write "$BACKUP" "$new_imei" -o "$PATCHED" || die "Patch failed"
push_replace "$PATCHED" LD0B_001 "$IMEI_PATH" system
echo "  IMEI updated."

echo ""
read -p "Reboot device now? [y/N] " ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    adb reboot
fi
