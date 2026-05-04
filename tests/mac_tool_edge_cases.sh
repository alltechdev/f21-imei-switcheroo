#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$ROOT/mac_tool.py"

EDGE="$ROOT/tmp/edge"
SAMPLES="$ROOT/tmp/wifi_bt_re"
rm -rf "$EDGE"
mkdir -p "$EDGE"
trap 'rm -rf "$EDGE"' EXIT INT TERM

[ -f "$SAMPLES/BT_Addr.bin" ]    || { echo "missing $SAMPLES/BT_Addr.bin (pull a live BT_Addr first)";   exit 2; }
[ -f "$SAMPLES/WIFI.bin" ]       || { echo "missing $SAMPLES/WIFI.bin (pull a live WIFI first)";        exit 2; }
[ -f "$SAMPLES/live_nvram.img" ] || { echo "missing $SAMPLES/live_nvram.img (dd /dev/block/by-name/nvram first)"; exit 2; }

PASS=0
FAIL=0

assert_pass() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS   $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL   $label (expected exit 0, got $?)"
        FAIL=$((FAIL+1))
    fi
}

assert_fail() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  FAIL   $label (expected nonzero exit)"
        FAIL=$((FAIL+1))
    else
        echo "  PASS   $label"
        PASS=$((PASS+1))
    fi
}

assert_stderr() {
    local label="$1" pattern="$2"; shift 2
    local out
    out=$("$@" 2>&1 >/dev/null)
    if echo "$out" | grep -qF "$pattern"; then
        echo "  PASS   $label  (matched: \"$pattern\")"
        PASS=$((PASS+1))
    else
        echo "  FAIL   $label  (no match for \"$pattern\")"
        echo "         got: $out" | head -1
        FAIL=$((FAIL+1))
    fi
}

assert_stdout() {
    local label="$1" pattern="$2"; shift 2
    local out
    out=$("$@" 2>/dev/null)
    if echo "$out" | grep -qF "$pattern"; then
        echo "  PASS   $label  (matched: \"$pattern\")"
        PASS=$((PASS+1))
    else
        echo "  FAIL   $label  (no match for \"$pattern\")"
        echo "         got: $out" | head -1
        FAIL=$((FAIL+1))
    fi
}

echo "== Read OK =="
assert_pass  "read BT_Addr"        python3 "$TOOL" read "$SAMPLES/BT_Addr.bin"
assert_pass  "read WIFI"           python3 "$TOOL" read "$SAMPLES/WIFI.bin"
assert_pass  "read partition"      python3 "$TOOL" read "$SAMPLES/live_nvram.img"

echo "== Read failures =="
assert_fail   "missing file"                  python3 "$TOOL" read /nonexistent
: >"$EDGE/empty.bin"
assert_fail   "empty file"                    python3 "$TOOL" read "$EDGE/empty.bin"
python3 -c "open('$EDGE/junk440.bin','wb').write(b'X'*440)"
assert_stderr "junk 440 -> sig mismatch hint" "trailer signature" python3 "$TOOL" read "$EDGE/junk440.bin"
python3 -c "open('$EDGE/junk2050.bin','wb').write(b'X'*2050)"
assert_stderr "junk 2050 -> hdr mismatch hint" "header magic"      python3 "$TOOL" read "$EDGE/junk2050.bin"
python3 -c "open('$EDGE/junk1234.bin','wb').write(b'X'*1234)"
assert_stderr "wrong size hint"               "expected 440"        python3 "$TOOL" read "$EDGE/junk1234.bin"

echo "== MAC format validation =="
assert_pass  "BT colon-separated"             python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02:11:22:33:44:55 -o "$EDGE/bt_colon.bin"
assert_pass  "BT dash-separated"              python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02-11-22-33-44-55 -o "$EDGE/bt_dash.bin"
assert_pass  "BT mixed case"                  python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02:11:AA:bB:Cc:Dd -o "$EDGE/bt_mixedcase.bin"
assert_stderr "BT 5 parts"        "5 parts"   python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02:11:22:33:44      -o "$EDGE/bt_5p.bin"
assert_stderr "BT 7 parts"        "7 parts"   python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02:11:22:33:44:55:66 -o "$EDGE/bt_7p.bin"
assert_stderr "BT 1-digit byte"   "6 parts"   python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02:1:22:33:44:55     -o "$EDGE/bt_1d.bin"
assert_stderr "BT non-hex"        "non-hex"   python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02:11:22:33:44:5g    -o "$EDGE/bt_nh.bin"
assert_stderr "BT no separators"  "1 parts"   python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 021122334455         -o "$EDGE/bt_ns.bin"
assert_stderr "BT embedded space" "6 parts"   python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt "02:11:22:33:44: 55" -o "$EDGE/bt_es.bin"

echo "== Write argument errors =="
assert_stderr "no input"            "usage:"           python3 "$TOOL" write
assert_stderr "no MAC at all"       "at least one of"  python3 "$TOOL" write "$SAMPLES/BT_Addr.bin"
assert_stderr "--bt no value"       "requires a MAC"   python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt
assert_stderr "--wifi no value"     "requires a MAC"   python3 "$TOOL" write "$SAMPLES/WIFI.bin"    --wifi
assert_stderr "-o no value"         "requires a path"  python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" -o
assert_stderr "BT input + --wifi"   "BT_Addr file"     python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --wifi 02:11:22:33:44:66
assert_stderr "WIFI input + --bt"   "WIFI file"        python3 "$TOOL" write "$SAMPLES/WIFI.bin"    --bt   02:11:22:33:44:55
assert_stderr "unknown long flag"   "unexpected"       python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02:11:22:33:44:55 --bogus
assert_stderr "unknown command"     "expected"         python3 "$TOOL" foobar

echo "== Write IO errors =="
assert_stderr "non-existent out dir" "cannot write" python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02:11:22:33:44:55 -o /nonexistent_dir/x.bin
assert_pass   "out=/dev/null"        python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt 02:11:22:33:44:55 -o /dev/null

echo "== Round-trip identity =="
ORIG_BT_MAC=$(python3 "$TOOL" read "$SAMPLES/BT_Addr.bin" | awk '{print $2}')
ORIG_WF_MAC=$(python3 "$TOOL" read "$SAMPLES/WIFI.bin"    | awk '{print $3}')
[ -n "$ORIG_BT_MAC" ] && [ -n "$ORIG_WF_MAC" ] || { echo "  FAIL   could not read original MACs from samples"; FAIL=$((FAIL+1)); }
python3 "$TOOL" write "$SAMPLES/BT_Addr.bin" --bt   02:11:22:33:44:55 -o "$EDGE/rt_bt_a.bin" >/dev/null
python3 "$TOOL" write "$EDGE/rt_bt_a.bin"    --bt   "$ORIG_BT_MAC"    -o "$EDGE/rt_bt_b.bin" >/dev/null
if cmp -s "$SAMPLES/BT_Addr.bin"   "$EDGE/rt_bt_b.bin";   then echo "  PASS   BT  round-trip byte-identical (orig=$ORIG_BT_MAC)";   PASS=$((PASS+1)); else echo "  FAIL   BT round-trip differs (orig=$ORIG_BT_MAC)";  FAIL=$((FAIL+1)); fi
python3 "$TOOL" write "$SAMPLES/WIFI.bin"    --wifi 02:11:22:33:44:66 -o "$EDGE/rt_wf_a.bin" >/dev/null
python3 "$TOOL" write "$EDGE/rt_wf_a.bin"    --wifi "$ORIG_WF_MAC"    -o "$EDGE/rt_wf_b.bin" >/dev/null
if cmp -s "$SAMPLES/WIFI.bin"      "$EDGE/rt_wf_b.bin";   then echo "  PASS   WIFI round-trip byte-identical (orig=$ORIG_WF_MAC)"; PASS=$((PASS+1)); else echo "  FAIL   WIFI round-trip differs (orig=$ORIG_WF_MAC)"; FAIL=$((FAIL+1)); fi

echo "== Partition image edge cases =="
python3 -c "
data=bytearray(open('$SAMPLES/live_nvram.img','rb').read())
data[0x2003c+439] ^= 0x55
open('$EDGE/nvram_bad_bt_cs.img','wb').write(bytes(data))"
assert_stdout "BT trailer corrupt -> not found" "(not found"  python3 "$TOOL" read "$EDGE/nvram_bad_bt_cs.img"

python3 -c "
sig=bytes.fromhex('60002310000007000000050703040000')
data=bytearray(b'\x00'*(1024*1024+10))
data[100:100+len(sig)]=sig
open('$EDGE/sig_at_end.img','wb').write(bytes(data))"
assert_stdout "sig with no room for full record -> not found" "(not found"  python3 "$TOOL" read "$EDGE/sig_at_end.img"

assert_stderr "partition with no BT records, --bt requested" "no valid BT_Addr record" python3 "$TOOL" write "$EDGE/sig_at_end.img" --bt 02:11:22:33:44:55 -o "$EDGE/x.img"

echo ""
echo "== Total: $PASS pass / $FAIL fail =="
[ "$FAIL" -eq 0 ] || exit 1
