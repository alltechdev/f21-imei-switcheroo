#!/usr/bin/env bash
# Termux interactive IMEI changer for rooted MTK devices.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$SCRIPT_DIR/imei_tool.py"

IMEI_PATH="/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001"
WORK="$(pwd)/tmp"
mkdir -p "$WORK"
BACKUP="$WORK/backup_LD0B_001.bin"
PATCHED="$WORK/patched_LD0B_001.bin"

die() { echo "Error: $1" >&2; exit 1; }

echo "Checking dependencies..."

if ! command -v python3 >/dev/null 2>&1; then
    read -p "Python not installed. Install now? [y/N] " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        pkg update && pkg install python || die "Python install failed"
        echo "Installed python"
    else
        die "Python not installed"
    fi
fi

if ! python3 -c "from Crypto.Cipher import AES" 2>/dev/null \
   && ! python3 -c "from Cryptodome.Cipher import AES" 2>/dev/null; then
    read -p "pycryptodome not installed. Install now with pip? [y/N] " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        pip install pycryptodome || die "pycryptodome install failed"
        echo "Installed pycryptodome"
    else
        die "pycryptodome not installed"
    fi
fi

echo "All dependencies are installed"

push_replace() {
    su -c "mount -o remount,rw /mnt/vendor/nvdata" </dev/null >/dev/null 2>&1
    su -c "mount -o remount,rw /" </dev/null >/dev/null 2>&1
    su -c "cp $PATCHED $IMEI_PATH" </dev/null || die "cp $PATCHED to $IMEI_PATH failed"
    su -c "chmod 660 $IMEI_PATH" </dev/null
    su -c "chown root:system $IMEI_PATH" </dev/null
}

su -c id </dev/null 2>/dev/null | grep -q "uid=0" \
    || die "su -c failed: device must be rooted and root must be granted to termux shell"
echo "Device is rooted, continuing..."

echo "Reading current IMEIs from device..."
su -c "cat $IMEI_PATH" </dev/null > "$BACKUP" 2>/dev/null \
    || die "Cannot read LD0B_001 from device"

file_size=$(wc -c < "$BACKUP")
[ "$file_size" -eq 384 ] || die "LD0B_001 is $file_size bytes (expected 384) - read may have corrupted the file"

echo ""
read_output=$(python3 "$TOOL" read "$BACKUP") || die "Read failed (imei_tool.py error above)"
echo "$read_output" | sed 's/^/  /'
echo ""

populated=$(echo "$read_output" | grep -cv '(empty)')

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

read -p "  New IMEI $slot (15 digits): " new_imei
echo "$new_imei" | grep -qE '^[0-9]{15}$' || die "IMEI must be exactly 15 digits"
echo "  Patching IMEI $slot..."
python3 "$TOOL" write "$BACKUP" "$new_imei" -s "$slot" -o "$PATCHED" \
    || die "Patch failed (imei_tool.py error above)"
push_replace
echo "  IMEI $slot updated."

echo ""
read -p "Reboot device now? [y/N] " ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    su -c "reboot" </dev/null
fi
