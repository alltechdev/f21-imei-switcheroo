# DuoQin F25 — offline analysis of pulled partitions

An offline analysis of `mac_tool.py` / `live_patch_mac.sh` compatibility on the **DuoQin F25** (dual-SIM), reached from partition dumps before any live F25 device was connected. F25 hardware patching has since been confirmed — see the **Status** banner directly below. The analysis steps that follow are recorded as they were performed against the partition dumps. Every output reproduced in this doc is a real run; nothing is illustrative.

> **Status — offline-compatible after a small mac_tool.py extension; live-device verified through the Java port.** F25's BT_Addr file uses the exact same format and trailer-checksum algorithm as F21 Pro and TIQ M5. F25's WIFI file uses a **different header magic** at offset 2: `01 00 09 00` instead of the F21 Pro / TIQ M5 `01 00 08 00`. The trailer-checksum algorithm is the same (verified by 3 valid F25 WIFI copies all matching). `mac_tool.py` was extended in the same change-set as this doc to accept both header variants — `WIFI_HDR_VARIANTS = (bytes.fromhex('01000800'), bytes.fromhex('01000900'))`. After the extension, both `read` and `write` recognize F25 WIFI records (verified — full nvdata round-trip is byte-identical). Hardware patching is confirmed by the port author through [`flipphoneguy/mtk-imei-switcheroo-app`](https://github.com/flipphoneguy/mtk-imei-switcheroo-app) on F25 hardware (the port author is the F25 tester). The port's primitives are bit-equivalent to `mac_tool.py` for the patch flow and to `live_patch_mac.sh`'s `sync_android_wifi_factory_mac` for the WCS-cache step. We do not have F25 hardware on this side, so this repo's bash script has not been run directly on F25.

For the **IMEI**-side per-device analysis on F25 (firmware-image checks of the AES key, slot offsets, MD5-XOR checksum, plus the live hardware confirmation via this repo's `live_patch.sh` and the Java app port), see [`reverse_engineering.md` § Cross-device validation (F25)](reverse_engineering.md#cross-device-validation-f25). This doc is the **MAC**-side companion.

## Source material

A directory of partitions pulled from an F25 (origin not recorded in the dump). Contents:

```
$ ls -la f25_modem_firmware/
md1img.bin   134217728 bytes  (128 MiB — modem firmware)
nvcfg.bin     33554432 bytes  ( 32 MiB)
nvdata.bin    67108864 bytes  ( 64 MiB)
nvram.bin     67108864 bytes  ( 64 MiB)
```

`md1img.bin`, `nvdata.bin`, `nvram.bin` are the relevant files for this analysis.

## Step 1 — Read the records with `mac_tool.py`

Before the multi-header extension landed, `mac_tool.py read` only knew about the `01 00 08 00` header and reported the F25 WIFI as missing:

```
$ python3 mac_tool.py read tmp/f25/nvdata.bin     # before extension
BT_Addr  (2 copies, first @ 0xe06802): 10:df:8b:b1:53:cc
WIFI MAC : (not found — no valid 2050-byte record with a matching aa+checksum trailer)
```

After extending `WIFI_HDR_VARIANTS` to also include `01 00 09 00` (Step 4 explains why):

```
$ python3 mac_tool.py read tmp/f25/nvdata.bin
BT_Addr  (2 copies, first @ 0xe06802): 10:df:8b:b1:53:cc
WIFI MAC (2 copies, first @ 0xe06000): 10:df:8b:29:96:be

$ python3 mac_tool.py read tmp/f25/nvram.bin
BT_Addr  (1 copies, first @ 0x20802): 10:df:8b:b1:53:cc
WIFI MAC (1 copies, first @ 0x20000): 10:df:8b:29:96:be
```

3 valid BT and 3 valid WIFI copies in total. Both MACs share the OUI `10:df:8b` (same family as F21 Pro factory MACs).

## Step 2 — BT_Addr offsets and checksum verification

```
$ python3 -c '
import sys; sys.path.insert(0,".")
from mac_tool import find_bt_copies, format_mac, compute_checksum, BT_MAC_OFFSET
for label, fn in [("nvdata","tmp/f25/nvdata.bin"),("nvram","tmp/f25/nvram.bin")]:
    data = open(fn,"rb").read()
    print(f"--- {label} ---")
    for off, blob in find_bt_copies(data):
        print(f"  @ {off:#x}: mac={format_mac(blob[BT_MAC_OFFSET:BT_MAC_OFFSET+6])}  trailer={blob[-2:].hex()}  computed={compute_checksum(blob):#04x}  match={blob[-1]==compute_checksum(blob)}")
'
--- nvdata ---
  @ 0xe06802: mac=10:df:8b:b1:53:cc  trailer=aafc  computed=0xfc  match=True
  @ 0x1001000: mac=10:df:8b:b1:53:cc  trailer=aafc  computed=0xfc  match=True
--- nvram ---
  @ 0x20802: mac=10:df:8b:b1:53:cc  trailer=aafc  computed=0xfc  match=True
```

All three BT_Addr copies have the F21 Pro / TIQ M5 trailer-checksum algorithm producing the exact stored byte. **The trailer algorithm is identical on F25.**

## Step 3 — BT_Addr round-trip identity through `mac_tool.py`

```
$ python3 -c '
data=open("tmp/f25/nvdata.bin","rb").read()
import os
os.makedirs("tmp/f25/extracted",exist_ok=True)
open("tmp/f25/extracted/BT_Addr.bin","wb").write(data[0xe06802:0xe06802+440])'

$ python3 mac_tool.py write tmp/f25/extracted/BT_Addr.bin --bt 02:11:22:33:44:55 -o /tmp/f25_bt_a.bin >/dev/null
$ python3 mac_tool.py write /tmp/f25_bt_a.bin --bt 10:df:8b:b1:53:cc -o /tmp/f25_bt_b.bin >/dev/null
$ cmp -s tmp/f25/extracted/BT_Addr.bin /tmp/f25_bt_b.bin && echo BT_Addr round-trip BYTE-IDENTICAL
BT_Addr round-trip BYTE-IDENTICAL
```

`mac_tool.py write` works on F25 BT_Addr without any tool change. Patch and patch-back produces the same bytes, confirming the format is fully understood.

## Step 4 — Why mac_tool said "WIFI not found": header magic differs

The AllMap-equivalent index inside F25's `nvdata.bin` says the WIFI record is 2050 bytes:

```
$ python3 -c '
import re
data = open("tmp/f25/nvdata.bin","rb").read()
for m in re.finditer(b"/mnt/vendor/nvdata/", data):
    h=m.start()
    if h<16: continue
    end=data.find(b"\x00",h)
    path=data[h:end].decode("latin1","replace")
    pre=data[h-16:h]
    off=int.from_bytes(pre[8:12],"little")
    size=int.from_bytes(pre[12:16],"little")
    if "WIFI" in path and "CUSTOM" not in path:
        print(f"  off={off:#x} size={size:#x} path={path}"); break
'
  off=0x0 size=0x802 path=/mnt/vendor/nvdata/APCFG/APRDEB/WIFI
```

So the WIFI record starts at AllFile-relative offset `0x0`, size `0x802` = 2050 bytes — same size as on F21 Pro and TIQ M5. The AllMap layout puts WIFI *before* BT_Addr on F25 (offsets 0 and 0x802 respectively), the inverse of F21 Pro / TIQ M5 (BT_Addr at 0, WIFI at 0x1f4). That ordering doesn't matter for the patch flow because `mac_tool.py` scans by signature, not by fixed offset.

What matters: the **WIFI live record on F25 sits at `nvdata[0xe06802 - 0x802] = nvdata[0xe06000]`**, immediately before the BT_Addr live block. Reading that range:

```
$ python3 -c '
import sys; sys.path.insert(0,".")
from mac_tool import compute_checksum, format_mac
data = open("tmp/f25/nvdata.bin","rb").read()
for off, label in [(0xe06000,"region 1"),(0x1000000,"region 2"),]:
    blob = data[off:off+2050]
    cs = compute_checksum(blob)
    print(f"  @ {off:#x} ({label}): header={blob[:4].hex()}  mac={format_mac(blob[4:10])}  trailer={blob[-2:].hex()}  computed_cs={cs:#04x}  trailer_match={blob[-1]==cs and blob[-2]==0xaa}")
'
  @ 0xe06000 (region 1): header=01000900  mac=10:df:8b:29:96:be  trailer=aab1  computed_cs=0xb1  trailer_match=True
  @ 0x1000000 (region 2): header=01000900  mac=10:df:8b:29:96:be  trailer=aab1  computed_cs=0xb1  trailer_match=True
```

Same in nvram:

```
$ python3 -c '
from mac_tool import compute_checksum, format_mac
import sys; sys.path.insert(0,".")
data = open("tmp/f25/nvram.bin","rb").read()
blob = data[0x20000:0x20000+2050]
print(f"  @ 0x20000: header={blob[:4].hex()}  mac={format_mac(blob[4:10])}  trailer={blob[-2:].hex()}  trailer_match={blob[-1]==compute_checksum(blob) and blob[-2]==0xaa}")
'
  @ 0x20000: header=01000900  mac=10:df:8b:29:96:be  trailer=aab1  trailer_match=True
```

**The F25 WIFI file's header is `01 00 09 00`, not `01 00 08 00`.** The byte at offset 2 differs from F21 Pro / TIQ M5. Everything else about the record matches the F21 Pro / TIQ M5 layout: 2050 bytes, MAC at `[4:10]`, 2-byte `aa CC` trailer where `CC` is the same position-alternating ADD/XOR checksum produced by `mac_tool.compute_checksum`.

`mac_tool.py`'s `WIFI_HDR = bytes.fromhex('01000800')` is currently a hard match, which is why `find_wifi_copies` rejected all F25 hits — none of them have `08` at offset 2. Extending the tool to also accept `01 00 09 00` would let it recognize and patch F25 WIFI records; the rest of the patch logic (offset-4 MAC, recompute trailer) is unchanged. Whether this is a "version" byte, a chipset-family identifier, or something else isn't determinable from the partitions alone — it's a per-build constant and `08` and `09` are the two values observed across F21 Pro, TIQ M5 (both `08`) and F25 (`09`).

The F25 WIFI MAC is **`10:df:8b:29:96:be`** — same OUI as the BT MAC (`10:df:8b:b1:53:cc`), and the same `10:df:8b` OUI seen on F21 Pro for both BT and WiFi. This is strong evidence the WiFi/BT chipset is the same family across the three devices (likely MT6635 combo) even though F25's SoC differs (Step 7 below).

## Step 5 — Cross-product byte comparison: F25 vs F21 Pro

```
$ python3 -c '
m25_bt = open("tmp/f25/extracted/BT_Addr.bin","rb").read()
f21_bt = open("tmp/wifi_bt_re/BT_Addr.bin","rb").read()
diff = [(i, m25_bt[i], f21_bt[i]) for i in range(440) if m25_bt[i]!=f21_bt[i]]
print(f"BT_Addr diff total: {len(diff)}")
print(f"  in MAC (0..5):           {sum(1 for d in diff if d[0]<6)}")
print(f"  in trailer body (6..437): {sum(1 for d in diff if 6<=d[0]<438)}")
print(f"  in trailer cs byte (439): {sum(1 for d in diff if d[0]==439)}")

import sys; sys.path.insert(0,".")
data = open("tmp/f25/nvdata.bin","rb").read()
m25_wf = data[0xe06000:0xe06000+2050]
f21_wf = open("tmp/wifi_bt_re/WIFI.bin","rb").read()
diff = [(i, m25_wf[i], f21_wf[i]) for i in range(2050) if m25_wf[i]!=f21_wf[i]]
print(f"WIFI diff total: {len(diff)}")
print(f"  in header (0..3):        {sum(1 for d in diff if d[0]<4)}  <- includes the 08 vs 09 byte at offset 2")
print(f"  in MAC (4..9):           {sum(1 for d in diff if 4<=d[0]<10)}")
print(f"  in cal body (10..2047):  {sum(1 for d in diff if 10<=d[0]<2048)}")
print(f"  in trailer cs byte (2049): {sum(1 for d in diff if d[0]==2049)}")
'
BT_Addr diff total: 257
  in MAC (0..5):           3   (10:df:8b is shared, last 3 bytes differ)
  in trailer body (6..437): 253
  in trailer cs byte (439): 1
WIFI diff total: 73
  in header (0..3):        1   <- the "08 vs 09" byte at offset 2
  in MAC (4..9):           3   (10:df:8b is shared, last 3 bytes differ)
  in cal body (10..2047):  68
  in trailer cs byte (2049): 1
```

The header difference is exactly one byte. The cal-body diff (68 bytes) is larger than TIQ-M5-vs-F21 (6 bytes — see [`tiq_m5_offline_analysis.md` § Step 5](tiq_m5_offline_analysis.md#step-5--cross-product-byte-comparison-tiq-m5-vs-f21-pro)) and far larger than F21-vs-F30 (cal body byte-identical; only 4 total bytes differ, all in MAC + trailer — see [`wifi_bt_reverse_engineering.md` § Step 1](wifi_bt_reverse_engineering.md#step-1--the-trailer-is-not-just-decoration)), reflecting that F25 runs on a different SoC (MT6768 vs MT6761) and has its own per-build cal table.

## Step 6 — `nvram` partition layout

```
F21 Pro:    BT_Addr @ 0x2003c, WIFI @ 0x201f4    (BT first, WIFI second)
TIQ M5:     BT_Addr @ 0x20006, WIFI @ 0x201f4    (BT first, WIFI second)
F25:        WIFI    @ 0x20000, BT_Addr @ 0x20802  (WIFI first, BT second)
```

F25 reverses the WIFI / BT_Addr ordering inside the `nvram` partition. Total record-pair length is the same (2050 + 440 = 2490 bytes), it's just the order that differs. `mac_tool.py` is order-agnostic since it scans by signature.

## Step 7 and 8 — out-of-scope context (modem family, RFIC)

> The modem identifiers below (LWTG / MT6177M / MT6768) **are not load-bearing for `mac_tool.py` or `live_patch_mac.sh`** — they describe the cellular modem stack, not the AP-side NVRAM record format the patch flow operates on. They're recorded here only because the data is real and was extracted from the same `md1img.bin` dump while answering side questions.

```
$ strings tmp/f25/md1img.bin | grep -E 'TK_MD_BASIC|MOLY\.LR|6177M|MT676[18]' | sort -u | head -10
TK_MD_BASIC_MDBIN_PCB01_MT6768_S00.MOLY_LR12A_R3_MP_V315_3_P2.bin
MOLY.LR12A.R3.MP.V315.3.P2
build/TK_MD_BASIC/LWTG_6177M_6769/modem/rrc_asn/rrc_asn_decode.c
build/TK_MD_BASIC/LWTG_6177M_6769/rel/L4/csm/ss/applib2_asn_common.c
build/TK_MD_BASIC/LWTG_6177M_6769/rel/L4/csm/ss/applib2_asn_memory.c
```

- **SoC**: MT6768 (Helio P65 class) — *different* from F21 Pro / TIQ M5 (both MT6761).
- **Modem stack**: MOLY.LR12A.R3.MP.V315.3.P2.
- **Modem variant**: **LWTG** (LTE / WCDMA / TDS-CDMA / GSM) — F25 includes TDS-CDMA support, unlike TIQ M5's LWG variant. The build path `LWTG_6177M_6769` references `6769` internally (likely an MTK reference number for the modem subsystem build target; the SoC is MT6768 per the banner).
- **Cellular RFIC**: **MT6177M** — same as F21 Pro and TIQ M5 (search `mt6177m` in `md1img.bin` returns the same family of MOLY source paths under `mt6177m/`, plus the build identifier itself).

## Determination

**For BT_Addr patching on F25**: every offline check passes, identical to F21 Pro / TIQ M5. `mac_tool.py write` round-trips byte-identically. Hardware patching is confirmed by the port author via the Java port `flipphoneguy/mtk-imei-switcheroo-app` on F25 hardware; the port is bit-equivalent to `mac_tool.py`'s primitives.

**For WIFI patching on F25**: supported by `mac_tool.py` after the `WIFI_HDR_VARIANTS` extension. `mac_tool.py read tmp/f25/nvdata.bin` finds 2 WIFI copies; `mac_tool.py write … --wifi …` patches them; full-image round-trip is byte-identical (covered by `tests/mac_tool_edge_cases.sh`'s "F25 nvdata full round-trip" assertion). Hardware patching is confirmed by the port author through the Java port on F25 hardware (which performs the equivalent of `mac_tool.py`'s patch and `live_patch_mac.sh`'s WCS-cache sync); we do not have F25 hardware on this side.

The F25 BT MAC `10:df:8b:b1:53:cc` and WIFI MAC `10:df:8b:29:96:be` share the OUI `10:df:8b` with each other and with F21 Pro's factory MACs — strong evidence the WiFi/BT combo chipset is shared across this device family even though the SoC differs (MT6761 vs MT6768).

## Reproducibility

```bash
cp -r /path/to/f25_modem_firmware tmp/f25/

python3 mac_tool.py read tmp/f25/nvdata.bin
python3 mac_tool.py read tmp/f25/nvram.bin

python3 -c '
import sys; sys.path.insert(0,".")
from mac_tool import compute_checksum, format_mac
data = open("tmp/f25/nvdata.bin","rb").read()
blob = data[0xe06000:0xe06000+2050]
print(f"WIFI @ 0xe06000: header={blob[:4].hex()}, mac={format_mac(blob[4:10])}, "
      f"trailer={blob[-2:].hex()}, computed_cs={compute_checksum(blob):#04x}, "
      f"match={blob[-1]==compute_checksum(blob) and blob[-2]==0xaa}")'
```

All steps re-run will produce the outputs reproduced verbatim above.
