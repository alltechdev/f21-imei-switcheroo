#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/live_patch_mac.sh"
TOOL="$ROOT/mac_tool.py"
SAMPLES="$ROOT/tmp/wifi_bt_re"
FAKE="$(mktemp -d)"

cleanup() {
    [ -f "$TOOL.bak" ]  && mv "$TOOL.bak"  "$TOOL"
    [ -f "$TOOL.real" ] && mv "$TOOL.real" "$TOOL"
    rm -rf "$FAKE"
}
trap cleanup EXIT INT TERM

[ -f "$SAMPLES/BT_Addr.bin" ] || { echo "missing $SAMPLES/BT_Addr.bin (pull a live BT_Addr first)"; exit 2; }
[ -f "$SAMPLES/WIFI.bin" ]    || { echo "missing $SAMPLES/WIFI.bin (pull a live WIFI first)";    exit 2; }
[ -f "$SCRIPT" ]              || { echo "missing $SCRIPT";  exit 2; }
[ -f "$TOOL" ]                || { echo "missing $TOOL";    exit 2; }

DEVICE_PRESENT=0
if command -v adb >/dev/null 2>&1 && adb devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; then
    DEVICE_PRESENT=1
fi

PYDIR="$(dirname "$(command -v python3)")"
SYSPATH="$PYDIR:/usr/bin:/bin"

PASS=0; FAIL=0

reset_artifacts() {
    rm -rf "$ROOT/tmp/backup_BT_Addr.bin" "$ROOT/tmp/backup_WIFI.bin" \
           "$ROOT/tmp/patched_BT_Addr.bin" "$ROOT/tmp/patched_WIFI.bin"
}

assert() {
    local label="$1" expected_pattern="$2" expected_exit="$3" out_file="$4"
    local actual_exit="$5"
    if [ "$actual_exit" -eq "$expected_exit" ] && grep -qF "$expected_pattern" "$out_file"; then
        echo "  PASS   $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL   $label  (exit=$actual_exit, expected $expected_exit; pattern=\"$expected_pattern\")"
        head -3 "$out_file" | sed 's/^/         /'
        FAIL=$((FAIL+1))
    fi
}

run_with_path() {
    local path_value="$1"; shift
    local out="$1"; shift
    env PATH="$path_value" bash -c "$*" >"$out" 2>&1
    return $?
}

write_fake_adb() {
    cat >"$FAKE/adb" <<EOF
#!/bin/bash
$1
EOF
    chmod +x "$FAKE/adb"
}

cd "$ROOT"

echo "== Host environment =="
reset_artifacts
PATH=/empty "$SCRIPT" </dev/null >"$FAKE/o" 2>&1; rc=$?
assert "adb missing"     "Error: adb not found in PATH" 1 "$FAKE/o" "$rc"

ADBDIR="$(dirname "$(command -v adb)")"
PATH="$ADBDIR" "$SCRIPT" </dev/null >"$FAKE/o" 2>&1; rc=$?
assert "python3 missing (adb present)" "Error: python3 not found in PATH" 1 "$FAKE/o" "$rc"

mv "$TOOL" "$TOOL.bak"
reset_artifacts
"$SCRIPT" </dev/null >"$FAKE/o" 2>&1; rc=$?
mv "$TOOL.bak" "$TOOL" || true
assert "mac_tool.py missing"  "Error: mac_tool.py not found" 1 "$FAKE/o" "$rc"

echo ""
echo "== Mocked-ADB device states =="

write_fake_adb 'case "$1" in
    devices) echo "List of devices attached"; echo "" ;;
    *) exit 0 ;;
esac'
reset_artifacts
run_with_path "$FAKE:$SYSPATH" "$FAKE/o" "$SCRIPT </dev/null"
assert "no device detected"   "Error: No ADB device detected" 1 "$FAKE/o" "$?"

write_fake_adb 'case "$1" in
    devices) echo "List of devices attached"; printf "0123456789ABCDEF\tunauthorized\n"; echo "" ;;
    *) exit 0 ;;
esac'
reset_artifacts
run_with_path "$FAKE:$SYSPATH" "$FAKE/o" "$SCRIPT </dev/null"
assert "device unauthorized"  "ADB device is in state" 1 "$FAKE/o" "$?"

write_fake_adb 'case "$1" in
    devices) echo "List of devices attached"; printf "0123456789ABCDEF\tdevice\n"; echo "" ;;
    shell)   echo "uid=2000(shell)" ;;
    *) exit 0 ;;
esac'
reset_artifacts
run_with_path "$FAKE:$SYSPATH" "$FAKE/o" "$SCRIPT </dev/null"
assert "device not rooted"    "Error: su -c id did not return uid=0" 1 "$FAKE/o" "$?"

echo ""
echo "== Mocked-ADB pull/push errors =="

write_fake_adb 'case "$1" in
    devices) echo "List of devices attached"; printf "0123456789ABCDEF\tdevice\n"; echo "" ;;
    shell)
        joined="$*"
        if [[ "$joined" == *" id"* ]] && [[ "$joined" != *"BT_Addr"* && "$joined" != *"WIFI"* ]]; then
            echo "uid=0(root)"
        elif [[ "$joined" == *"/mnt/vendor/nvdata"* ]] && [[ "$joined" == *"/sdcard/"* ]]; then
            echo "cp: not found" >&2; exit 1
        else
            exit 0
        fi
        ;;
    *) exit 0 ;;
esac'
reset_artifacts
run_with_path "$FAKE:$SYSPATH" "$FAKE/o" "$SCRIPT </dev/null"
assert "stage cp fails"       "Error: Cannot stage" 1 "$FAKE/o" "$?"

write_fake_adb 'case "$1" in
    devices) echo "List of devices attached"; printf "0123456789ABCDEF\tdevice\n"; echo "" ;;
    shell)   echo "uid=0(root)"; exit 0 ;;
    pull)    exit 1 ;;
    *) exit 0 ;;
esac'
reset_artifacts
run_with_path "$FAKE:$SYSPATH" "$FAKE/o" "$SCRIPT </dev/null"
assert "adb pull fails"       "Error: adb pull of" 1 "$FAKE/o" "$?"

REAL_BT="$SAMPLES/BT_Addr.bin"
write_fake_adb "case \"\$1\" in
    devices) echo \"List of devices attached\"; printf \"0123456789ABCDEF\tdevice\n\"; echo \"\" ;;
    shell)   echo \"uid=0(root)\"; exit 0 ;;
    pull)    dest=\"\$3\"; printf 'WRONG_SIZE' > \"\$dest\"; exit 0 ;;
    *) exit 0 ;;
esac"
reset_artifacts
run_with_path "$FAKE:$SYSPATH" "$FAKE/o" "$SCRIPT </dev/null"
assert "BT pulled wrong size" "Error: BT_Addr pulled as 10 bytes, expected 440" 1 "$FAKE/o" "$?"

write_fake_adb "case \"\$1\" in
    devices) echo \"List of devices attached\"; printf \"0123456789ABCDEF\tdevice\n\"; echo \"\" ;;
    shell)   echo \"uid=0(root)\"; exit 0 ;;
    pull)
        dest=\"\$3\"
        if [[ \"\$2\" == *BT_Addr* ]]; then cp \"$REAL_BT\" \"\$dest\"; else printf 'WRONG' > \"\$dest\"; fi
        exit 0 ;;
    *) exit 0 ;;
esac"
reset_artifacts
run_with_path "$FAKE:$SYSPATH" "$FAKE/o" "$SCRIPT </dev/null"
assert "WIFI pulled wrong size" "Error: WIFI pulled as 5 bytes, expected 2050" 1 "$FAKE/o" "$?"

REAL_WF="$SAMPLES/WIFI.bin"
write_fake_adb "case \"\$1\" in
    devices) echo \"List of devices attached\"; printf \"0123456789ABCDEF\tdevice\n\"; echo \"\" ;;
    shell)
        joined=\"\$*\"
        if [[ \"\$joined\" == *\"/data/local/tmp\"* ]] && [[ \"\$joined\" == *\"/mnt/vendor/nvdata\"* ]]; then
            echo \"cp: Read-only file system\" >&2; exit 1
        elif [[ \"\$joined\" == *\" id\"* ]] && [[ \"\$joined\" != *BT_Addr* && \"\$joined\" != *WIFI* ]]; then
            echo \"uid=0(root)\"
        else
            exit 0
        fi
        ;;
    pull)
        dest=\"\$3\"
        if [[ \"\$2\" == *BT_Addr* ]]; then cp \"$REAL_BT\" \"\$dest\"; else cp \"$REAL_WF\" \"\$dest\"; fi
        exit 0 ;;
    push) exit 0 ;;
    *) exit 0 ;;
esac"
reset_artifacts
run_with_path "$FAKE:$SYSPATH" "$FAKE/o" "$SCRIPT <<< 'y
02:11:22:33:44:55
n
'"
assert "final cp fails (RO)"  "Error: cp /data/local/tmp/BT_Addr.new -> /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr failed" 1 "$FAKE/o" "$?"

if [ "$DEVICE_PRESENT" -eq 1 ]; then
    echo ""
    echo "== MAC-format prompt validation (real adb, real device) =="
    reset_artifacts
    printf 'y\nnot-a-mac\n' | "$SCRIPT" >"$FAKE/o" 2>&1
    assert "BT MAC bad"           "Error: BT MAC 'not-a-mac' is not six colon- or dash-separated" 1 "$FAKE/o" "$?"

    reset_artifacts
    printf 'n\ny\nbogus\n' | "$SCRIPT" >"$FAKE/o" 2>&1
    assert "WiFi MAC bad"         "Error: WiFi MAC 'bogus' is not six colon- or dash-separated" 1 "$FAKE/o" "$?"

    echo ""
    echo "== mac_tool.py write failure (real device, mocked tool) =="
    mv "$TOOL" "$TOOL.real"
    cat > "$TOOL" <<'EOF'
#!/usr/bin/env python3
import sys
if sys.argv[1] == 'read':
    if 'BT_Addr' in sys.argv[2]: print("BT_Addr: 10:df:8b:00:00:00")
    else: print("WIFI MAC: 10:df:8b:00:00:01")
    sys.exit(0)
print("Error: mocked mac_tool failure", file=sys.stderr); sys.exit(1)
EOF
    chmod +x "$TOOL"
    reset_artifacts
    printf 'y\n02:11:22:33:44:55\n' | "$SCRIPT" >"$FAKE/o" 2>&1
    rc=$?
    mv "$TOOL.real" "$TOOL"
    assert "mac_tool write fails" "Error: BT_Addr patch failed" 1 "$FAKE/o" "$rc"
else
    echo ""
    echo "== Skipping real-device cases (no ADB device in 'device' state) =="
    echo "   To exercise: connect a rooted F21 Pro and re-run this driver."
fi

echo ""
echo "== Total: $PASS pass / $FAIL fail =="
[ "$FAIL" -eq 0 ] || exit 1
