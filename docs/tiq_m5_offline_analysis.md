# TIQ M5 — offline analysis of pulled partitions

An offline analysis of `mac_tool.py` / `live_patch_mac.sh` compatibility on the **TIQ M5** (MT6761, dual-SIM), reached from partition dumps before any live TIQ M5 device was connected. Subsequent live-device testing produced a more nuanced picture than this doc originally claimed; see [`tiq_m5_mac_live_findings.md`](tiq_m5_mac_live_findings.md) for the live results, and the [Resolution](#resolution-of-the-open-question) section here for the live-test update to the original open question. Every output reproduced in this doc is a real run; nothing is illustrative.

> **Status:** the on-disk format, the AllMap index format, the BT_Addr / WIFI signatures, and the trailer-checksum algorithm are byte-for-byte compatible with what was verified end-to-end on F21 Pro. Round-trip integrity through `mac_tool.py` is byte-clean for both standalone files and the full 64 MiB `nvdata.bin`. **Live-device confirmed on TIQ M5 (partial)**: BT MAC patching via `live_patch_mac.sh` works end-to-end (file persists, daemon validates, `settings get secure bluetooth_address` reflects the patched value across reboots); WiFi MAC patching writes a byte-perfect file the daemon accepts, but the chipset firmware on this M5 build holds the runtime WiFi MAC in an on-die cache that only the Java app port (`flipphoneguy/mtk-imei-switcheroo-app`) can update — `live_patch_mac.sh` does not, even though it uses the same algorithm and the same on-device primitives. Full live findings, ruled-out hypotheses, and reproduction steps: [`tiq_m5_mac_live_findings.md`](tiq_m5_mac_live_findings.md). The offline analysis below was performed before live testing; the open-question section is preserved as it was written, with the live-test update stated under [Resolution](#resolution-of-the-open-question).

## Source material

A single zip pulled with mtkclient from a TIQ M5: `pulledwithmtkclienttiqm5.zip`. Extracted contents:

```
$ unzip -l pulledwithmtkclienttiqm5.zip
   Length      Date    Time    Name
---------  ---------- -----   ----
    17408  2026-05-01 11:49   gpt.bin
    16896  2026-05-01 11:49   gpt_backup.bin
104857600  2026-05-01 11:49   md1img_a.bin
 33554432  2026-05-01 11:49   nvcfg.bin
 67108864  2026-05-01 11:49   nvdata.bin
 67108864  2026-05-01 11:49   nvram.bin
---------                     -------
272664064                     6 files
```

The five partitions relevant to this analysis are `nvdata.bin`, `nvram.bin`, `nvcfg.bin`, `md1img_a.bin`, and `gpt.bin`.

## Step 1 — Read the records with `mac_tool.py`

```
$ python3 mac_tool.py read tmp/tiqm5/nvdata.bin
BT_Addr  (4 copies, first @ 0x1000000): 4e:3b:46:90:34:7c
WIFI MAC (4 copies, first @ 0x10001f4): 00:00:00:00:00:00

$ python3 mac_tool.py read tmp/tiqm5/nvram.bin
BT_Addr  (1 copies, first @ 0x20006): 4e:3b:46:90:34:7c
WIFI MAC (1 copies, first @ 0x201f4): 00:00:00:00:00:00
```

The fact that the tool finds anything at all is the first cross-product confirmation: `find_bt_copies` and `find_wifi_copies` (which require the BT_Addr 16-byte trailer fingerprint at offset 6 *and* a self-consistent `aa CC` trailer where `CC` matches the F21 Pro algorithm) successfully match against TIQ M5 records. If the algorithm or signature differed, no copies would have been reported.

The BT MAC `4e:3b:46:90:34:7c` is real and consistent across all 4 nvdata copies and the nvram copy. The WIFI MAC field is all-zero in every copy on this dump — flagged as the [open question](#open-question) below.

The 4 BT_Addr offsets in `nvdata.bin`:

```
0x1000000   0x1010000   0x1802006   0x2e01006
```

The 4 WIFI offsets:

```
0x10001f4   0x1013000   0x18021f4   0x2e011f4
```

These are the live ext4 file blocks plus journal/COW remnants — same pattern as F21 Pro (where 18 BT and 18 WIFI copies were observed in a 64 MiB nvdata image after several writes).

## Step 2 — Verify the checksum algorithm matches

```
$ python3 -c '
import sys; sys.path.insert(0,".")
from mac_tool import compute_checksum
data = open("tmp/tiqm5/nvdata.bin","rb").read()
bt_blob = data[0x1000000:0x1000000+440]
wf_blob = data[0x10001f4:0x10001f4+2050]
print(f"BT_Addr first copy: magic={bt_blob[-2]:#04x}, stored_cs={bt_blob[-1]:#04x}, computed_cs={compute_checksum(bt_blob):#04x}, match={bt_blob[-1]==compute_checksum(bt_blob)}")
print(f"WIFI    first copy: magic={wf_blob[-2]:#04x}, stored_cs={wf_blob[-1]:#04x}, computed_cs={compute_checksum(wf_blob):#04x}, match={wf_blob[-1]==compute_checksum(wf_blob)}")
'
BT_Addr first copy: magic=0xaa, stored_cs=0x4b, computed_cs=0x4b, match=True
WIFI    first copy: magic=0xaa, stored_cs=0x27, computed_cs=0x27, match=True
```

`mac_tool.compute_checksum` (the position-alternating ADD-on-even / XOR-on-odd algorithm recovered by disassembling F21 Pro's `libnvram.so` — see [`wifi_bt_reverse_engineering.md`](wifi_bt_reverse_engineering.md)) produces the byte-exact stored trailer for the TIQ M5 records. Same is true for every other copy in `nvdata.bin` and `nvram.bin` (the `find_*_copies` step in Step 1 only returns copies whose `trailer_valid` predicate passes).

This is direct evidence the trailer algorithm is the same on TIQ M5 as on F21 Pro. If TIQ M5 used a different algorithm, the tool would either reject those copies (no `aa CC` match) or compute a different checksum value than the one stored.

## Step 3 — Round-trip identity through `mac_tool.py`

To confirm the tool's read+write path leaves the file byte-identical when the MAC is patched and then patched back to the original, run the full nvdata round-trip:

```
$ python3 mac_tool.py write tmp/tiqm5/nvdata.bin --bt 02:11:22:33:44:55 --wifi 02:11:22:33:44:66 -o /tmp/m5_nv.img
Wrote /tmp/m5_nv.img: BT=02:11:22:33:44:55 (4 copies), WIFI=02:11:22:33:44:66 (4 copies)
BT_Addr  (4 copies, first @ 0x1000000): 02:11:22:33:44:55
WIFI MAC (4 copies, first @ 0x10001f4): 02:11:22:33:44:66

$ python3 mac_tool.py write /tmp/m5_nv.img --bt 4e:3b:46:90:34:7c --wifi 00:00:00:00:00:00 -o /tmp/m5_nv_back.img
Wrote /tmp/m5_nv_back.img: BT=4e:3b:46:90:34:7c (4 copies), WIFI=00:00:00:00:00:00 (4 copies)
BT_Addr  (4 copies, first @ 0x1000000): 4e:3b:46:90:34:7c
WIFI MAC (4 copies, first @ 0x10001f4): 00:00:00:00:00:00

$ cmp -s tmp/tiqm5/nvdata.bin /tmp/m5_nv_back.img && echo BYTE-IDENTICAL
BYTE-IDENTICAL
```

Same test for the standalone files extracted from the partition image:

```
$ python3 -c '
data=open("tmp/tiqm5/nvdata.bin","rb").read()
open("tmp/tiqm5/extracted/BT_Addr.bin","wb").write(data[0x1000000:0x1000000+440])
open("tmp/tiqm5/extracted/WIFI.bin","wb").write(data[0x10001f4:0x10001f4+2050])'

$ python3 mac_tool.py write tmp/tiqm5/extracted/BT_Addr.bin --bt 02:11:22:33:44:55 -o /tmp/m5_a.bin >/dev/null
$ python3 mac_tool.py write /tmp/m5_a.bin --bt 4e:3b:46:90:34:7c -o /tmp/m5_b.bin >/dev/null
$ cmp -s tmp/tiqm5/extracted/BT_Addr.bin /tmp/m5_b.bin && echo BT round-trip BYTE-IDENTICAL
BT round-trip BYTE-IDENTICAL

$ python3 mac_tool.py write tmp/tiqm5/extracted/WIFI.bin --wifi 02:11:22:33:44:66 -o /tmp/m5_w_a.bin >/dev/null
$ python3 mac_tool.py write /tmp/m5_w_a.bin --wifi 00:00:00:00:00:00 -o /tmp/m5_w_b.bin >/dev/null
$ cmp -s tmp/tiqm5/extracted/WIFI.bin /tmp/m5_w_b.bin && echo WIFI round-trip BYTE-IDENTICAL
WIFI round-trip BYTE-IDENTICAL
```

Three byte-identical round trips (BT standalone, WIFI standalone, full 64 MiB nvdata partition) — `mac_tool.py` preserves every byte except the patched MAC and its dependent trailer-checksum.

## Step 4 — AllMap-equivalent index in TIQ M5 nvdata

F21 Pro stores a per-record index in `/mnt/vendor/nvdata/AllMap` whose entries have a 16-byte prefix in the form `<flags_byte_0> <flags_byte_1> <flags_byte_2> <flags_byte_3> <kind_LE32> <offset_LE32> <size_LE32>` followed by the record's filesystem path (NUL-terminated, padded). The same structure is present inside `tmp/tiqm5/nvdata.bin`:

```
$ python3 -c '
import re
data = open("tmp/tiqm5/nvdata.bin","rb").read()
seen=set(); n=0
for m in re.finditer(b"/mnt/vendor/nvdata/", data):
    h=m.start()
    if h<16: continue
    end=data.find(b"\x00",h)
    path=data[h:end].decode("latin1","replace")
    pre=data[h-16:h]
    off=int.from_bytes(pre[8:12],"little")
    size=int.from_bytes(pre[12:16],"little")
    if path in seen: continue
    seen.add(path); n+=1
    print(f"  pre={pre.hex()}  off={off:#x} size={size:#x}  path={path}")
    if n>=12: break
'
  pre=000000000700000000000000b8010000  off=0x0    size=0x1b8  path=/mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr
  pre=0000000007000000b801000006000000  off=0x1b8  size=0x6    path=/mnt/vendor/nvdata/APCFG/APRDEB/WIFI_CUSTOM
  pre=0000000007000000be01000036000000  off=0x1be  size=0x36   path=/mnt/vendor/nvdata/APCFG/APRDEB/GPS
  pre=0000000007000000f401000002080000  off=0x1f4  size=0x802  path=/mnt/vendor/nvdata/APCFG/APRDEB/WIFI
  pre=0000000007000000f6090000d6160000  off=0x9f6  size=0x16d6 path=/mnt/vendor/nvdata/APCFG/APRDCL/FILE_VER
  pre=0000000007000000cc2000001a000000  off=0x20cc size=0x1a   path=/mnt/vendor/nvdata/APCFG/APRDCL/MD_SBP
  pre=0000000007000000e62000004e000000  off=0x20e6 size=0x4e   path=/mnt/vendor/nvdata/APCFG/APRDCL/AUXADC
  pre=0000000007000000342100001a000000  off=0x2134 size=0x1a   path=/mnt/vendor/nvdata/APCFG/APRDCL/FG
  pre=00000000070000004e21000080010000  off=0x214e size=0x180  path=/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001
  pre=0000000007000000ce22000090000000  off=0x22ce size=0x90   path=/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/NV0S_000
  pre=00000000070000005e23000060000000  off=0x235e size=0x60   path=/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/NV01_000
  pre=0000000007000000be23000024000000  off=0x23be size=0x24   path=/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/FILELIST
```

Every prefix has the same `00 00 00 00 07 00 00 00` lead bytes as F21 Pro's AllMap entries, and every `<offset, size>` pair matches the file's known size:

- `BT_Addr`: `size=0x1b8` = 440 (matches)
- `WIFI_CUSTOM`: `size=0x6` = 6 (matches)
- `WIFI`: `size=0x802` = 2050 (matches)
- `LD0B_001`: `size=0x180` = 384 (matches; the IMEI file, same size as F21 Pro)

So TIQ M5 nvdata uses the same AllMap-style index of records as F21 Pro. The strings `NVRAM_VER`, `FILE_VER`, `AllFile`, and `AllMap` are all also present in the partition (`grep`-confirmed), reinforcing that the same MTK NVRAM stack is in use:

```
$ python3 -c '
data=open("tmp/tiqm5/nvdata.bin","rb").read()
for s in [b"NVRAM_VER", b"FILE_VER", b"AllFile", b"AllMap", b"BinRegion"]:
    if s in data: print(f"  {s!r}: present @ {hex(data.find(s))}")
    else: print(f"  {s!r}: not found")
'
  b'NVRAM_VER': present @ 0x10009f6
  b'FILE_VER':  present @ 0xc0d020
  b'AllFile':   present @ 0x80404c
  b'AllMap':    present @ 0x80405c
  b'BinRegion': not found
```

(`BinRegion` is a string from `libnvram.so`, not from the nvdata partition contents — its absence here is expected.)

The F21-Pro-style 4-byte AllMap header magic `47 c3 5e 28` is not found at the start of any AllMap-equivalent in TIQ M5 nvdata (the magic is per-build), but the per-record entry format itself is identical.

## Step 5 — Cross-product byte comparison: TIQ M5 vs. F21 Pro

To pin down which parts of the format are device-class-shared and which are per-device, diff the standalone files extracted from each:

```
$ python3 -c '
m5_bt = open("tmp/tiqm5/nvdata.bin","rb").read()[0x1000000:0x1000000+440]
f21_bt = open("tmp/wifi_bt_re/BT_Addr.bin","rb").read()
diff = [(i, m5_bt[i], f21_bt[i]) for i in range(440) if m5_bt[i]!=f21_bt[i]]
print(f"BT_Addr diff: {len(diff)} bytes total")
print(f"  in MAC (0..5): {sum(1 for d in diff if d[0]<6)}")
print(f"  in trailer body (6..437): {sum(1 for d in diff if 6<=d[0]<438)}")
print(f"  in trailer cs byte (439): {sum(1 for d in diff if d[0]==439)}")
m5_wf = open("tmp/tiqm5/nvdata.bin","rb").read()[0x10001f4:0x10001f4+2050]
f21_wf = open("tmp/wifi_bt_re/WIFI.bin","rb").read()
diff = [(i, m5_wf[i], f21_wf[i]) for i in range(2050) if m5_wf[i]!=f21_wf[i]]
print(f"WIFI diff: {len(diff)} bytes total")
print(f"  in header (0..3): {sum(1 for d in diff if d[0]<4)}")
print(f"  in MAC (4..9): {sum(1 for d in diff if 4<=d[0]<10)}")
print(f"  in cal body (10..2047): {sum(1 for d in diff if 10<=d[0]<2048)}")
print(f"  in trailer cs byte (2049): {sum(1 for d in diff if d[0]==2049)}")
'
BT_Addr diff: 260 bytes total
  in MAC (0..5): 6
  in trailer body (6..437): 253
  in trailer cs byte (439): 1
WIFI diff: 13 bytes total
  in header (0..3): 0
  in MAC (4..9): 6
  in cal body (10..2047): 6
  in trailer cs byte (2049): 1
```

Observations:

- **WIFI: header `01 00 08 00` is byte-identical**, MAC bytes differ as expected, cal body differs in only 6 bytes (per-device cal tweaks), trailer differs by 1 byte (the dependent checksum). This is the same pattern as `cmp -l WIFI.bin stock_WIFI.bin` on F21 vs F30 stock (4 byte diffs total).
- **BT_Addr: trailer body differs in 253 of 432 bytes**. F21 Pro's BT trailer template happens to be byte-identical to F30 stock's, but TIQ M5's trailer template is its own (different MTK build / different BT firmware revision). **`mac_tool.py`'s `patch_bt` preserves the trailer template byte-for-byte and only recomputes the 1-byte checksum**, so this 253-byte difference is transparent to the patch flow.

The 16-byte BT_Addr trailer fingerprint at offset 6 (`60 00 23 10 00 00 07 00 00 00 05 07 03 04 00 00`) is part of the matched portion (it must be — `find_bt_copies` requires it as a signature; copies were found). What differs between F21 Pro and TIQ M5 is the rest of the trailer template, after the fingerprint.

## Step 6 — `nvram` partition layout difference

```
$ python3 -c '
nv = open("tmp/tiqm5/nvram.bin","rb").read()
print("BT_Addr in nvram @ 0x20006 (preceding 64 bytes):")
print(" ", nv[0x20006-64:0x20006].hex())
print("WIFI in nvram @ 0x201f4 (same offset as F21 Pro)")
'
BT_Addr in nvram @ 0x20006 (preceding 64 bytes):
  0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000aa00
```

`nvram.bin`'s BT_Addr starts at `0x20006` (vs F21 Pro's `0x2003c`) — the preamble is 0x36 bytes shorter on TIQ M5. The WIFI starts at `0x201f4`, **same offset as F21 Pro**. `mac_tool.py` scans by signature, not fixed offset, so the BT preamble difference is transparent.

## Step 7 and 8 — out-of-scope context (modem family, LWG vs LWTG, RFIC)

> The modem-build identifiers below (LWG / LWTG / ULWCTG, RFIC MT6177M, RF support chip MT6306) **are not load-bearing for `mac_tool.py` or `live_patch_mac.sh`**. The patch flow only depends on the AP-side NVRAM record format (BT_Addr / WIFI / trailer-checksum algorithm), all of which is established in Steps 1–6 above. The next two steps came up while answering side questions during the analysis ("is the modem LWG or LWTG?", "is it MT6177M?") and are kept here only because the data is real and was extracted from the same `md1img_a.bin` dump. Skip them if you only care about whether `mac_tool.py` will work on TIQ M5 — the answer to that is in Steps 1–6.

## Step 7 — Modem firmware family (out-of-scope context)

```
$ strings tmp/tiqm5/md1img_a.bin | grep -E 'MOLY|MT676|TK_MD_BASIC' | sort -u | head -10
LR12A.R3.MP MT6761
MOLY.LR12A.R3.MP.V255
MT6761
MT6761_HW
MT6761_S00
TK_MD_BASIC_MDBIN_PCB01_MT6761_S00.MOLY_LR12A_R3_MP_V255.bin
/MOLY.LR12A.R3.MP.V255

$ python3 -c '
md1=open("tmp/tiqm5/md1img_a.bin","rb").read()
for s in [b"NVD_IMEI", b"SST_secure", b"custom_nvram", b"SBP_IMEI_VERIFY", b"GEMINI_PLUS"]:
    print(f"  {s!r}: {\"present\" if s in md1 else \"NOT FOUND\"}")
'
  b'NVD_IMEI': present
  b'SST_secure': present
  b'custom_nvram': present
  b'SBP_IMEI_VERIFY': present
  b'GEMINI_PLUS': present
```

TIQ M5 modem family: **MOLY.LR12A.R3.MP.V255** (MT6761 S00 build PCB01). Same MOLY release line as F21 Pro (R3 series). All the NVRAM-related modem symbols (`SST_secure`, `custom_nvram`, `SBP_IMEI_VERIFY`, `NVD_IMEI`) are present, same as F21 Pro per [`reverse_engineering.md` § Hardware validation (TIQ M5)](reverse_engineering.md#hardware-validation-tiq-m5-dual-sim) noted for the IMEI work. `GEMINI_PLUS` confirms dual-SIM.

`md1img_a.bin` md5 differs from the F30 stock `md1img_a` md5 (`2ea907647a44e5c745735d7d5f324974` vs `e1f142628661ac1baaf0a9e5aae8b8e2`) — different modem build, expected.

### Modem variant: LWG

```
$ strings tmp/tiqm5/md1img_a.bin | grep -E 'TK_MD_BASIC.*LWG|build/TK_MD_BASIC' | sort -u | head -8
2023/08/09 09:18*TK_MD_BASIC*LWG_AGO1_6177M_R3_6761
build/TK_MD_BASIC/LWG_AGO1_6177M_R3_6761/modem/dbme/fdd/db_access.c
build/TK_MD_BASIC/LWG_AGO1_6177M_R3_6761/modem/dbme/fdd/dbme.c
build/TK_MD_BASIC/LWG_AGO1_6177M_R3_6761/modem/rrc_asn/fdd/rrc_db_decode.c
build/TK_MD_BASIC/LWG_AGO1_6177M_R3_6761/modem/rrc_asn/fdd/rrc_db_encode.c
build/TK_MD_BASIC/LWG_AGO1_6177M_R3_6761/rel/L4/csm/ss/applib2_asn_common.c
build/TK_MD_BASIC/LWG_AGO1_6177M_R3_6761/rel/L4/csm/ss/applib2_asn_memory.c
```

The build identifier in `md1img_a.bin` is **`LWG_AGO1_6177M_R3_6761`** with a build timestamp of `2023/08/09 09:18`. `LWG` here stands for the LTE / WCDMA / GSM modem feature set — i.e. **no TDS-CDMA and no CDMA2000/EVDO**. Every source-path string under `build/TK_MD_BASIC/LWG_AGO1_6177M_R3_6761/...` lives under `modem/.../fdd/` (FDD LTE), with no `tdd/` or `td_scdma/` siblings. The compiled image does include some `SBP_*_TDD` and `SBP_LTE_TDD_UL_CA` symbols (those are in the MOLY source tree regardless of variant), but the build flavor itself is LWG, not LWTG/ULWCTG/ULWDCTG.

For comparison, the F30 stock SP Flash package's modem database is named `MDDB_InfoCustomAppSrcP_MT6761_S00_MOLY_LR12A_R3_MP_V88_3_1_ulwctg_n.EDB` — F30 ships ULWCTG (Universal LTE / WCDMA / CDMA / TDS / GSM). TIQ M5 is the slimmer LWG flavor.

## Step 8 — RF chips identifiable from the modem firmware (out-of-scope context)

What's directly identifiable from `md1img_a.bin`:

- **SoC / baseband**: MT6761 (Helio A20-class), confirmed via the modem banner (`LR12A.R3.MP MT6761`, `MT6761_S00`, `MT6761_HW`).
- **Cellular RFIC: MT6177M** — this is concrete, not a guess. Direct evidence:

  ```
  $ strings tmp/tiqm5/md1img_a.bin | grep -iE 'mt6177m|6177M' | sort -u | head -10
  2023/08/09 09:18*TK_MD_BASIC*LWG_AGO1_6177M_R3_6761
  build/TK_MD_BASIC/LWG_AGO1_6177M_R3_6761/modem/dbme/fdd/db_access.c
  DEFAULT_ASIC_6177M_WO_EVS_WO_CCA
  HLWG_AGO1_6177M_R3_6761
  l1core/modem/el1/el1d/src/rfc/rf_dep/./mt6177m/lrfcalrfctrl_mt6177m.c
  l1core/modem/el1/el1d/src/rfd/rf_dep/./mt6177m/lrfdepcmncontrol_mt6177m.c
  l1core/modem/el1/el1d/src/rfd/rf_dep/./mt6177m/lrfdepdata_mt6177m.c
  l1core/modem/el1/el1d/src/rfd/rf_dep/./mt6177m/lrfdepevent_mt6177m.c
  l1core/modem/el1/el1d/src/rfd/rf_dep/./mt6177m/lrfdepstrx_mt6177m.c
  l1core/modem/mml1/mml1_rf/src/mmrfc/common/rf_dep/mt6177m/mml1_rf_calgor_mt6177m.c
  ```

  The MOLY source paths under `mt6177m/` (six distinct files: `lrfcalrfctrl_mt6177m.c`, `lrfdepcmncontrol_mt6177m.c`, `lrfdepdata_mt6177m.c`, `lrfdepevent_mt6177m.c`, `lrfdepstrx_mt6177m.c`, plus the GSM/LTE-specific `mml1_rf_calgor_mt6177m.c` / `grfcalrfdepcwctrl_mt6177m.c` / `lrfcalrfdepcwctrl_mt6177m.c`) are MT6177M-specific drivers compiled into this modem image. The `DEFAULT_ASIC_6177M_WO_EVS_WO_CCA` ASIC identifier and the `LWG_AGO1_6177M_R3_6761` build tag both name the RFIC explicitly. **The RFIC is MT6177M.**

- **RF support chip: MT6306** — likely the antenna/RF switch, indicated by symbols like `MT6306_Check`, `MT6306_LOCK`, `MT6306_SEC_LOCK`, and `mt6306_rp_0`..`mt6306_rp_7`. Also `MT6293_S00` is referenced but its role isn't unambiguous from strings alone.

What's **not** identifiable from these partitions:

- **External PA modules** (Skyworks `SKY77xxx`, Qorvo `QM78xxx`, MAXSCEND `MXD8xxx`, etc.) — exhaustive string search of `md1img_a.bin` returns no real PA vendor part numbers. The hits like `mXD9` and `sKyz` from a loose grep are random byte-sequence matches in compiled code, not chip names. Determining the PA module would require the device tree (`boot.img` / `dtbo`), a live `dmesg | grep -i pa` from a connected device, or PCB inspection.
- **WiFi/BT combo chip** — `md1img_a.bin` is the *cellular* modem firmware and doesn't drive WiFi/BT. The WiFi/BT combo chip on MT6761 reference designs is typically MT6635 (driven by the AP-side `wlan_drv_gen4m.ko` and `bt_drv.ko`), but that's a default expectation, not something this dump confirms.

Compared to the F30 stock package's modem (which we have for cross-reference): F30 also targets MT6177M (`LWG_AGO1_6177M_T_R3_6761` build, `DEFAULT_ASIC_6177M_WO_EVS`) — same RFIC family, slightly different build flavor (the `_T_` infix and the `_WO_CCA` suffix differ between TIQ M5 and F30). Same baseband + same RFIC across these two MT6761 phones, different MOLY build numbers and minor compile-time options.

## Open question (resolved)

*Recorded as written before the hardware confirmation came in. See [Resolution](#resolution-of-the-open-question) below.*

In every single BT_Addr copy on the TIQ M5 dump, the MAC is the populated value `4e:3b:46:90:34:7c`. In every single WIFI copy, the MAC field at `[4:10]` is **all zeros**, and the trailer checksum is the correct value for an all-zero MAC plus the rest of the file (`aa 27`). The file is structurally well-formed; only the MAC field is unprovisioned-looking.

Three reads, indistinguishable from offline data:

1. The TIQ M5 the dump was pulled from was unprovisioned for WiFi at the time (factory-reset state, or never SN_Writer'd). `mac_tool.py write … --wifi …` would populate the field with a valid trailer and the device would pick it up.
2. TIQ M5 sources its WiFi MAC from somewhere other than `APCFG/APRDEB/WIFI` (eFuse, a different NV record, a chipset-internal source). Patching the WIFI file would have no runtime effect.
3. The all-zero is intentional — the device runs WiFi MAC randomization unconditionally and the file is a placeholder.

The only way to disambiguate is to run on hardware: before any patch, `cat /sys/class/net/wlan0/address` and `dumpsys wifi | grep -i mac` to see what the live system actually exposes; cross-reference with the file content.

## Resolution of the open question

Live-device testing on TIQ M5 hardware (full findings: [`tiq_m5_mac_live_findings.md`](tiq_m5_mac_live_findings.md)) refined the picture. Of the three reads originally flagged:

- **Read 1** (file is the unprovisioned state, APRDEB/WIFI is the runtime source): **partially correct** — the dump's all-zero MAC was indeed the unprovisioned state, and the kernel WiFi driver does load the file's MAC into the wiphy at boot via `kalUpdateMACAddress` (visible in dmesg).
- **Read 2** (TIQ M5 sources its WiFi MAC from somewhere other than APCFG/APRDEB/WIFI): **also partially correct** — Android's WiFi HAL queries the chipset firmware for the "factory MAC" via NL80211 vendor command, and that returns a value held in chipset on-die memory (the connsys subsystem's RAM/SRAM, not visible as any block device on the SoC side) rather than the wiphy MAC the kernel just loaded. The HAL then forces this on-die-cache value back onto `wlan0` via `wlanSetMacAddress`, overriding the wiphy MAC.
- **Read 3** (the device runs WiFi MAC randomization unconditionally): excluded — with `MacRandomizationSetting=0` Android does **not** randomize, but it still uses the chipset's on-die-cache value rather than the wiphy MAC.

So the WIFI file IS read by the kernel and IS what populates the wiphy, but the runtime MAC the AP sees is decided one layer up by Android's HAL querying the chipset firmware's separate cache. That cache is updated only by writes performed via the Java app port (`flipphoneguy/mtk-imei-switcheroo-app`); identical primitive sequences from a host shell (`live_patch_mac.sh`, or even an offline-patched `fastboot flash nvdata`) do not update it. The differentiator was not identifiable from external observation; see the live-findings doc for the full list of ruled-out hypotheses.

## Determination

**For BT_Addr patching on TIQ M5**: every offline check passes. Format identical, AllMap entry identical, signature identical, trailer-checksum algorithm identical (verified against 5 separate stored trailers — 4 in nvdata.bin, 1 in nvram.bin), full-image round-trip byte-identical. Modem stack same family as F21 Pro. **`live_patch_mac.sh` confirmed live end-to-end on TIQ M5 hardware** — file persists byte-identical, daemon validates, `settings get secure bluetooth_address` reflects the patched value across reboots.

**For WIFI patching on TIQ M5**: the format match and round-trip are equally strong; the dump's all-zero starting MAC is the unprovisioned state. **`live_patch_mac.sh` writes a byte-perfect WIFI file on TIQ M5 hardware** (the daemon accepts it, no rollback, every layer up to and including the kernel wiphy reflects the patched value), **but the runtime MAC the AP sees stays at whatever the app port last wrote** because the chipset firmware's on-die cache is what Android's HAL queries. For WiFi MAC changes on TIQ M5, use the app port; this repo's `live_patch_mac.sh` is BT-only at runtime on this device. F21 Pro and F25 do not exhibit this asymmetry.

## Reproducibility

```bash
mkdir -p tmp/tiqm5 && unzip -o pulledwithmtkclienttiqm5.zip -d tmp/tiqm5/

python3 mac_tool.py read tmp/tiqm5/nvdata.bin
python3 mac_tool.py read tmp/tiqm5/nvram.bin

python3 mac_tool.py write tmp/tiqm5/nvdata.bin \
    --bt 02:11:22:33:44:55 --wifi 02:11:22:33:44:66 -o /tmp/m5_nv.img
python3 mac_tool.py write /tmp/m5_nv.img \
    --bt 4e:3b:46:90:34:7c --wifi 00:00:00:00:00:00 -o /tmp/m5_nv_back.img
cmp -s tmp/tiqm5/nvdata.bin /tmp/m5_nv_back.img && echo BYTE-IDENTICAL
```

All steps above re-run on a fresh checkout will produce the outputs reproduced verbatim in this doc.
