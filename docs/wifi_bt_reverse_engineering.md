# Reverse engineering the WiFi MAC and Bluetooth address NVRAM format

> **Scope: the RE walkthrough below is F21 Pro.** Every disassembly, hex dump, byte offset, and write-reboot-verify run reproduced in this doc was performed against a single live **DuoQin F21 Pro** (MT6761, Android 11 + Magisk). The format and algorithm recovered have since been confirmed compatible on **F25** and **TIQ M5** (see [Hardware validation](#hardware-validation) at the bottom of this doc and the per-device [`f25_offline_analysis.md`](f25_offline_analysis.md) / [`tiq_m5_offline_analysis.md`](tiq_m5_offline_analysis.md)). The reproducibility instructions in this doc reference F21 Pro paths and outputs because that's the device the RE was performed on; the `mac_tool.py` / `live_patch_mac.sh` *flow* is multi-device.

A step-by-step walkthrough of how the WiFi MAC and Bluetooth address storage on the F21 Pro was reverse-engineered from scratch. Every claim is backed by a command you can run or a byte offset you can verify. No prior knowledge of the format is assumed beyond "this phone stores its WiFi MAC and BT address somewhere on disk."

The on-disk format turns out to be plaintext — no AES, no MD5, no key derivation — but it is checksum-validated by the system NVRAM daemon at boot. Without recomputing the checksum, the daemon detects the edit and silently restores the original. Identifying that checksum is the load-bearing piece of the RE; once we have the algorithm, the live-patch flow is a few hundred bytes of file copies.

Throughout this doc, the **live F21 Pro's** factory MACs are written as `10:df:8b:XX:YY:ZZ` (BT) and `10:df:8b:UU:VV:WW` (WiFi) — the OUI `10:df:8b` is the chipset-family prefix shared across this device class and is reproduced verbatim, but the per-device suffix is abstracted (project rule on not committing real device IDs). Stock F30 MAC values from the publicly-distributed SP Flash Tool package are reproduced verbatim because they ship with the firmware and aren't device-unique.

## Source material

| Source | What it provided |
|---|---|
| Live, rooted F21 Pro / Android 11 + Magisk | `/mnt/vendor/nvdata/APCFG/APRDEB/{BT_Addr, WIFI}` files; `/mnt/vendor/nvdata/{AllFile, AllMap}`; the raw `nvram` partition (BinRegion) at `/dev/block/by-name/nvram`. Used for both observation and end-to-end write/reboot/verify. |
| Stock F30 SP Flash Tool package — the classic "F30 US LTE Bands Package" originally posted on XDA ([forum thread](https://xdaforums.com/t/guide-xiaomi-qin-f21-pro-with-us-bands.4579393/), filename `F30 Modem Files for Flashing with SPFlash Tool/`) | Stock `nvram` and `nvdata` partition images (factory pristine layout) and the `MT6761_Android_scatter - edited.txt` partition table (which marks the `nvram` partition as `operation_type: BINREGION`). Provides a second known-good (mac, trailer) pair for each of BT_Addr and WIFI. F30 and F21 Pro share the same MT6761 platform and the same NVRAM record layouts, which is why a stock F30 image is a useful reference for the F21 Pro. |
| `/vendor/lib64/libnvram.so` (pulled from the device) | The runtime NVRAM library. Disassembling `NVM_CheckFile` and `NVM_ComputeCheckNo` reveals the trailer-byte algorithm and the validation flow. |
| `/vendor/bin/wlan_assistant`, `/vendor/lib/modules/wlan_drv_gen4m.ko` | The userspace assistant and kernel driver that consume the WIFI file at boot — confirms what reads the on-disk MAC and pushes it to the WiFi chipset. |
| `SN_Write_Tool_v1.1916.00` (factory provisioning tool, Windows) | The "supported" provisioning path: META-mode NVRAM writes against `AP_CFG_RDEB_FILE_BT_ADDR_LID` and `AP_CFG_RDEB_FILE_WIFI_LID` followed by `REQ_BackupNvram2BinRegion`. Useful as a sanity check that this is solvable on the AP side at all. |

## Step 0 — Find the files on disk

On a rooted F21 Pro, search likely paths under `/mnt/vendor/nvdata/`:

```
$ adb shell su -c 'find /mnt/vendor/nvdata -maxdepth 4 -type f 2>/dev/null \
                 | grep -iE "wifi|bt|bluetooth|wlan|mac"'
/mnt/vendor/nvdata/APCFG/APRDEB/WIFI_CUSTOM
/mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr
/mnt/vendor/nvdata/APCFG/APRDEB/WIFI
/mnt/vendor/nvdata/md/NVRAM/CALIBRAT/ULBT_000
```

`BT_Addr` is `root:bluetooth`, mode `0660`. `WIFI` is `root:system`, mode `0660`. `WIFI_CUSTOM` is 6 bytes (a runtime override flag, not the MAC). `ULBT_000` is BT cal data, not the MAC. The two we want are `BT_Addr` and `WIFI`.

Pull both binary-safely (`cp via su /sdcard + adb pull`, the same pattern documented for IMEI in [`live_patch.md` § Pull current IMEI](live_patch.md#pull-current-imei)):

```
$ adb shell su -c 'cp /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr /sdcard/BT_Addr && \
                  cp /mnt/vendor/nvdata/APCFG/APRDEB/WIFI    /sdcard/WIFI    && \
                  chmod 644 /sdcard/BT_Addr /sdcard/WIFI'
$ adb pull /sdcard/BT_Addr
$ adb pull /sdcard/WIFI
$ adb shell su -c 'rm /sdcard/BT_Addr /sdcard/WIFI'
$ wc -c BT_Addr WIFI
 440 BT_Addr
2050 WIFI
2490 total
```

The size is the first thing that matters: every BT_Addr we've ever observed (live, stock F30, factory template in `nvram` partition) is exactly **440 bytes**, every WIFI exactly **2050 bytes**. A non-440-byte BT_Addr or non-2050-byte WIFI is corrupted and the rest of this analysis doesn't apply.

## File layouts

### `BT_Addr` (440 bytes)

Hex dump of the live-device file (BT MAC abstracted as `10 df 8b XX YY ZZ`):

```
00000000  10 df 8b XX YY ZZ 60 00  23 10 00 00 07 00 00 00  |......`.#.......|
00000010  05 07 03 04 00 00 00 00  00 80 00 ff ff ff 00 00  |................|
00000020  00 00 00 00 00 00 ff ff  ff ff ff ff ff ff ff ff  |................|
00000030  ff ff ff 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
00000040  …                                                  (0x00 bytes through 0x16f)
00000170  ff ff ff ff ff ff ff ff  ff ff ff ff ff ff ff ff  |................|
…                                                            (0xff bytes through 0x1b5)
000001b0  ff ff ff ff ff ff aa CC                           |........|       ← aa CC trailer
                                                              000001b8 = 440
```

Layout:

```
offset  size   contents
─────────────────────────────────────────────────────────────────────
0x000     6    Bluetooth MAC, big-endian on-the-wire order
0x006   432    fixed trailer template — byte-identical between the F21 Pro
               and the stock F30 partition image, apart from the device-
               unique MAC at the start. Begins with the 16-byte fingerprint
               60 00 23 10 00 00 07 00 00 00 05 07 03 04 00 00, the rest is
               the format-fixed body of zeros and 0xFF padding bytes.
0x1b6     2    "aa CC" trailer marker — magic 0xaa, then 1 checksum byte CC
─────────────────────────────────────────────────────────────────────
                                                          total = 0x1b8 = 440 bytes
```

The 16-byte fingerprint at `[0x06:0x16]` is what `mac_tool.py` uses to recognize a BT_Addr file inside a partition image. It's a stable per-format byte sequence — unrelated to the per-device MAC — that does not appear elsewhere in the live nvdata partition.

### `WIFI` (2050 bytes)

Hex dump (WiFi MAC abstracted, calibration body shown by region only):

```
00000000  01 00 08 00 10 df 8b UU  VV WW 00 00 00 00 00 00  |................|   header + MAC
00000010  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
…                                                            (zeros through 0x0ff)
00000100  00 03 01 02 9f 01 32 27  27 27 27 23 23 23 23 23  |......2''''#####|   cal data start
00000110  23 22 22 23 23 23 23 23  21 21 21 21 21 21 21 21  |#""#####!!!!!!!!|
…                                                            (cal body through 0x7ff, 1792 bytes)
00000800  aa CC                                              |..|              ← aa CC trailer
                                                              0x802 = 2050
```

Layout:

```
offset  size   contents
─────────────────────────────────────────────────────────────────────
0x000     4    fixed header   01 00 08 00
0x004     6    WiFi MAC, big-endian on-the-wire order
0x00a   246    zero padding
0x100   1792   WiFi calibration / channel-power tables. On the live F21 Pro
               this body is byte-identical to the stock F30 image's body —
               i.e. the calibration here is firmware-default, not per-device
               cal — apart from the trailer byte at 0x801 (see next).
0x800     2    "aa CC" trailer marker — magic 0xaa, then 1 checksum byte CC
─────────────────────────────────────────────────────────────────────
                                                          total = 0x802 = 2050 bytes
```

The 4-byte header `01 00 08 00` is what `mac_tool.py` uses to recognize a WIFI file inside a partition image **on F21 Pro and TIQ M5**. F25 uses `01 00 09 00` for the same role (one byte different at offset 2, otherwise identical layout); see [`f25_offline_analysis.md`](f25_offline_analysis.md). `mac_tool.py`'s `WIFI_HDR_VARIANTS` tuple accepts both.

## Live MAC vs on-disk MAC

It's worth pinning down what the OS-level reads of the MAC actually return, because the WiFi value you see at runtime is **not** the file's MAC.

```
$ adb shell su -c 'settings get secure bluetooth_address'
10:DF:8B:XX:YY:ZZ          ← byte-for-byte equal to BT_Addr[0x00:0x06]

$ adb shell su -c 'cat /sys/class/net/wlan0/address'
4e:82:67:97:c9:06          ← Android's per-network randomized MAC

$ adb shell su -c 'cat /sys/class/net/wlan0/addr_assign_type'
3                          ← NET_ADDR_RANDOM (kernel constant 3)

$ adb shell su -c 'dumpsys wifi 2>/dev/null | grep -E "macRandomization|mRandomized"' | head
 macRandomizationSetting: 1
 mRandomizedMacAddress: 4e:82:67:97:c9:06
```

So Bluetooth is direct — the runtime address is exactly the file's first 6 bytes. WiFi is gated by Android's per-SSID randomization layer (`addr_assign_type=3`, `macRandomizationSetting: 1`), which generates a fresh random MAC per saved network and assigns it to `wlan0`. The factory MAC at `WIFI[4:10]` is what the kernel WiFi driver registers as the wiphy's permanent address — Android's randomization layer just hides it from netdev consumers. After patching the WIFI file, the file-level read is what proves the change took.

## The runtime consumers

`wlan_assistant` (`/vendor/bin/wlan_assistant`, ARM64 ELF, ~20 KB) reads the WIFI file at boot and pushes the MAC into the WiFi chipset via `/dev/wmtWifi`:

```
$ strings /vendor/bin/wlan_assistant | grep -iE "APRDEB|wmtWifi|mac|nvram"
/dev/wmtWifi
Unable to access mac file
[WLAN-ASSISTANT]
WR-BUF:NVRAM
will sync to driver, changed %#x
stat WIFI_LOADER_DEV fail
/mnt/vendor/nvdata/APCFG/APRDEB
mac[%d] = %x
custom nvram filename = %s
```

The kernel WiFi driver (`/vendor/lib/modules/wlan_drv_gen4m.ko`) is the corresponding consumer on the kernel side; it parses the same WIFI file as part of `glLoadNvram`. The Bluetooth side is more straightforward — `BT_Addr[0:6]` is read by the BT HAL and presented as `settings get secure bluetooth_address`.

## Step 1 — The trailer is not just decoration

Pull `BT_Addr` and `WIFI` from a few sources and compare the last 2 bytes. The five samples used here are: the live F21 Pro's `BT_Addr` and `WIFI` (pulled in Step 0), the corresponding files extracted from the stock F30 `nvdata` image (`stock_BT_Addr.bin`, `stock_WIFI.bin`, scanned out of `F30 Modem Files for Flashing with SPFlash Tool/nvdata`), and one more — the **factory template** WIFI record sitting at offset `0x201f4` of the stock F30 `nvram` partition (which is what would get written to a fresh device before SN_Writer assigns the per-device MAC):

```
$ python3 -c '
import sys
data = open("stock_nvram.img","rb").read()
open("stock_nvram_WIFI.bin","wb").write(data[0x201f4:0x201f4+2050])'

$ for f in BT_Addr.bin WIFI.bin stock_BT_Addr.bin stock_WIFI.bin stock_nvram_WIFI.bin; do
    printf "%-26s len=%-4d mac@0=%s mac@4=%s tail=%s\n" \
      "$f" "$(wc -c < $f)" \
      "$(xxd -s 0 -l 6 $f | awk '{print $2$3}' | head -c12)" \
      "$(xxd -s 4 -l 6 $f | awk '{print $2$3}' | head -c12)" \
      "$(xxd -s -2 -l 2 $f | awk '{print $2}' | head -c4)"
  done
BT_Addr.bin                len=440  mac@0=10df8bXXXXXX mac@4=…             tail=aaCC
WIFI.bin                   len=2050 mac@0=01000800XXXX mac@4=10df8bUUUUUU tail=aaDD
stock_BT_Addr.bin          len=440  mac@0=10df8ba3b44e mac@4=b44e60002310 tail=aaf4
stock_WIFI.bin             len=2050 mac@0=0100080010df mac@4=10df8b1c3f62 tail=aa6d
stock_nvram_WIFI.bin       len=2050 mac@0=0100080010ab mac@4=10ab1a1b1c12 tail=aa2a
```

(BT_Addr's MAC is at offset 0; WIFI's MAC is at offset 4 — behind the 4-byte `01 00 08 00` header — so for WIFI files the meaningful MAC column is `mac@4`. The live-device entries have their per-device suffixes abstracted as `XX`/`UU`; the publicly-distributed stock F30 values and the factory template are reproduced verbatim.)

Across the stock F30 sources and the factory template in the `nvram` partition, the trailer's first byte is **always 0xaa** and the second byte (`CC`/`f4`/`DD`/`6d`/`2a`) varies. Three observations narrow it from "decorative" to "computed":

1. **Within a single file, the trailer changes whenever the body changes.** Stock F30 WIFI and live F21 WIFI are byte-identical *except* in the MAC bytes and the trailer byte (verifiable with `cmp` once you have both files side-by-side):

   ```
   $ cmp -l WIFI.bin stock_WIFI.bin | wc -l
   4
   $ cmp -l WIFI.bin stock_WIFI.bin | awk '{print $1}'
   8
   9
   10
   2050
   ```

   Four bytes differ — at 1-indexed offsets 8, 9, 10 (the last 3 bytes of the 6-byte MAC at `[4:10]`, where the OUI prefix `10:df:8b` is shared between F21 Pro and stock F30 and only the device-unique suffix differs) and 2050 (the trailer's checksum byte). So the trailer covaries with the MAC.

2. **The trailer isn't a function of the MAC alone.** Naive single-byte hypotheses tested against the (mac, trailer) pairs we have — `tail = sum(mac) & 0xff`, `tail = xor(mac)`, `tail = -sum(mac) mod 256`, file-wide `sum(file) ≡ 0 mod 256` (i.e. trailer chosen to make the byte sum vanish), and a sample of common CRC-8 polynomials applied to the 6-byte MAC — all fail to match all known pairs simultaneously. A deeper CRC-8 brute force over (poly, init, refin, refout, xorout) was started but cut short once disassembly recovered the algorithm directly (Step 3 below); the brute force result is therefore "no match in the partial sweep performed", not "no match exists in any CRC-8 variant".

3. **The MTK runtime daemon explicitly checks it.** Strings in `/vendor/lib64/libnvram.so` reveal the validation flow:

   ```
   $ strings libnvram.so | grep -iE "ProtectUserData|RestoreFromBinRegion|CheckFile|SetCheckSum|ComputeCheckNo"
   NVM_ProtectDataFile
   NVM_ProtectUserData:Check Failed!!!
   NVM_ProtectUserData Restore Success
   NVM_RestoreFromBinRegion_OneFile
   File is not exist, try to restore from binregion!!!
   _Z18NVM_ComputeCheckNoPKcPcb
   _Z15NVM_SetCheckSumj
   NVM_CheckFile
   ```

   So we have an `NVM_CheckFile` validator and an `NVM_ComputeCheckNo` worker, called as part of an "NVM_ProtectUserData" path that on failure does `NVM_RestoreFromBinRegion_OneFile`. This is the rollback we observe: edit the file with a MAC that doesn't match the existing trailer → daemon validates → mismatch → daemon restores from BinRegion.

So the trailer is a self-checksum and we need to recover the algorithm.

## Step 2 — Disassembling `NVM_CheckFile`

`libnvram.so` exports both `NVM_CheckFile` and `NVM_ComputeCheckNo` as symbols. Dump `NVM_CheckFile` with the NDK's `llvm-objdump`:

```
$ NDK=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin
$ $NDK/llvm-objdump -d --disassemble-symbols=NVM_CheckFile libnvram.so | head -90
00000000000112a8 <NVM_CheckFile>:
   112a8: d10103ff      sub  sp, sp, #0x40
   112ac: a9017bfd      stp  x29, x30, [sp, #0x10]
   …
   112e4: 9400469b      bl   0x22d50 <_Z18NVM_ComputeCheckNoPKcPcb@plt>
   112e8: 394003e8      ldrb w8, [sp]              ← reads the [out] byte
   112ec: 7103fd1f      cmp  w8, #0xff
   112f0: 54000420      b.eq 0x11374              ← if [out]==0xff, jump to fail
   112f4: 2a0003f4      mov  w20, w0              ← w20 = ComputeCheckNo's return value (the computed checksum)
   112f8: aa1303e0      mov  x0, x19              ← x0 = filename
   112fc: 2a1f03e1      mov  w1, wzr              ← O_RDONLY
   11300: 940045f8      bl   0x22ae0 <__open_2@plt>
   …
   1130c: 92800021      mov  x1, #-0x2            ← seek offset = -2
   11310: 52800042      mov  w2, #0x2             ← SEEK_END
   11318: 940045f6      bl   0x22af0 <lseek@plt>
   …
   11320: 910013e1      add  x1, sp, #0x4         ← buffer at sp+4
   11324: 2a1303e0      mov  w0, w19              ← fd
   11328: 52800042      mov  w2, #0x2             ← read 2 bytes
   1132c: 94004601      bl   0x22b30 <read@plt>
   …
   11338: 394013e8      ldrb w8, [sp, #0x4]       ← buf[0]
   1133c: 7102a91f      cmp  w8, #0xaa            ← compare to magic 0xaa
   11340: 54000461      b.ne 0x113cc              ← if not 0xaa, fail
   11344: 394017e8      ldrb w8, [sp, #0x5]       ← buf[1]
   11348: 6b34011f      cmp  w8, w20, uxtb        ← compare to computed checksum
   1134c: 540004a1      b.ne 0x113e0              ← if not equal, fail
   11350: …             return 1                  ← OK
```

So `NVM_CheckFile(filename)` does exactly:

```c
char outflag = 0;
unsigned char computed = NVM_ComputeCheckNo(filename, &outflag, /*exclude_last_2=*/true);
if (outflag == 0xff) return 0;          // ComputeCheckNo signaled failure
int fd = open(filename, O_RDONLY);
lseek(fd, -2, SEEK_END);
unsigned char buf[2]; read(fd, buf, 2);
if (buf[0] != 0xaa)        return 0;    // magic byte
if (buf[1] != computed)    return 0;    // checksum byte
close(fd); return 1;                    // file is valid
```

The trailer is exactly what we suspected: **2 bytes, magic `0xaa` then a 1-byte checksum**, and the checksum is whatever `NVM_ComputeCheckNo(filename, _, true)` returns.

## Step 3 — Disassembling `NVM_ComputeCheckNo`

Same approach:

```
$ $NDK/llvm-objdump -d --disassemble-symbols=_Z18NVM_ComputeCheckNoPKcPcb libnvram.so | head -160
0000000000012630 <_Z18NVM_ComputeCheckNoPKcPcb>:
   12630: d10343ff      sub   sp, sp, #0xd0
   …
   12670: aa0103f3      mov   x19, x1                ← x19 = out_byte ptr
   12674: 910003e1      mov   x1, sp                 ← stat() into a local stat buf
   12678: 2a0203f5      mov   w21, w2                ← w21 = bool exclude_last_2
   1267c: aa0003f4      mov   x20, x0                ← x20 = filename
   12680: 940040fc      bl   0x22a70 <stat@plt>
   …
   12688: aa1403e0      mov  x0, x20                 ← reopen by name
   1268c: 2a1f03e1      mov  w1, wzr                 ← O_RDONLY
   12690: 94004114      bl   0x22ae0 <__open_2@plt>
   …
   1269c: b94033e8      ldr  w8, [sp, #0x30]         ← w8 = st.st_size
   126a0: 720002bf      tst  w21, #0x1               ← test exclude_last_2 bit
   126a4: 2a0003f4      mov  w20, w0                 ← w20 = fd
   126a8: 2a1f03f5      mov  w21, wzr                ← w21 = checksum, init 0
   126ac: 381f43bf      sturb wzr, [x29, #-0xc]      ← out byte = 0
   126b0: 51000909      sub  w9, w8, #0x2            ← count if (size - 2)
   126b4: 1a881137      csel w23, w9, w8, ne         ← w23 = exclude ? (size-2) : size
   126b8: 34000217      cbz  w23, 0x126f8            ← skip loop if count==0
   126bc: 2a1f03f8      mov  w24, wzr                ← w24 = parity bit, init 0
   <loop>
   126c0: d10033a1      sub  x1, x29, #0xc           ← read 1 byte into [x29-0xc]
   126c4: 2a1403e0      mov  w0, w20                 ← fd
   126c8: 52800022      mov  w2, #0x1                ← 1 byte
   126cc: 94004119      bl   0x22b30 <read@plt>
   …
   126d8: 385f43a8      ldurb w8, [x29, #-0xc]       ← w8 = byte
   126dc: 7200031f      tst  w24, #0x1               ← Z flag : 1 if w24 even
   126e0: 52000318      eor  w24, w24, #0x1          ← toggle parity for next iter
   126e4: 4a0802a9      eor  w9, w21, w8             ← w9 = checksum XOR byte
   126e8: 0b0802a8      add  w8, w21, w8             ← w8 = checksum + byte
   126ec: 1a881135      csel w21, w9, w8, ne         ← w21 = (parity_was_odd ? XOR : ADD)
   126f0: 710006f7      subs w23, w23, #0x1          ← decrement counter
   126f4: 54fffe61      b.ne 0x126c0                 ← loop
   <after loop>
   126f8: 2a1403e0      mov  w0, w20                 ← close(fd)
   126fc: 94004105      bl   0x22b10 <close@plt>
   …
   1276c: 2a1503e0      mov  w0, w21                 ← return checksum (low 8 bits)
```

The flag manipulation around `tst`/`csel` is worth pinning down: `tst w24, #0x1` sets the Z flag if `(w24 & 1) == 0` (parity is even). Then `csel w21, w9 (XOR), w8 (ADD), ne` selects `w9` (XOR) when **NE** (Z flag clear, i.e. parity was odd) and `w8` (ADD) otherwise. Since `w24` starts at 0 and toggles each iteration, the sequence is:

```
iteration 0   w24=0  (even) → ADD
iteration 1   w24=1  (odd)  → XOR
iteration 2   w24=0  (even) → ADD
iteration 3   w24=1  (odd)  → XOR
…
```

Combined with the `count = size - 2` from the earlier `csel w23, w9, w8, ne` (under the `tst w21, #0x1` of the input bool), the algorithm in C is:

```c
unsigned char NVM_ComputeCheckNo(const char *filename, char *out_byte,
                                  bool exclude_last_2) {
    *out_byte = 0;
    struct stat st;
    if (stat(filename, &st) < 0) { *out_byte = 0xff; return 0; }
    int fd = open(filename, O_RDONLY);
    if (fd < 0)                  { *out_byte = 0xff; return 0; }

    size_t count = exclude_last_2 ? (st.st_size - 2) : st.st_size;
    unsigned int cs = 0;
    for (size_t i = 0; i < count; i++) {
        unsigned char b;
        if (read(fd, &b, 1) != 1) { *out_byte = 0xff; close(fd); return 0; }
        if ((i & 1) == 0)  cs += b;     // even index: ADD
        else               cs ^= b;     // odd  index: XOR
    }
    close(fd);
    return (unsigned char)(cs & 0xff);
}
```

i.e. **walk the bytes (excluding the last 2), maintaining an 8-bit running checksum, ADD on even-indexed bytes, XOR on odd-indexed bytes**. The final low byte is the trailer's `CC`.

Reproduced as Python (this is what `mac_tool.py` ships with):

```python
def compute_checksum(data):
    cs = 0
    for i, b in enumerate(data[:-2]):
        cs = ((cs + b) if i % 2 == 0 else (cs ^ b)) & 0xff
    return cs
```

## Step 4 — Verify against known files

Run the algorithm against every file we have a known trailer for:

```
$ python3 -c '
def compute_checksum(data):
    cs = 0
    for i, b in enumerate(data[:-2]):
        cs = ((cs + b) if i % 2 == 0 else (cs ^ b)) & 0xff
    return cs
for fn in ["BT_Addr","stock_BT_Addr.bin","WIFI","stock_WIFI.bin"]:
    d = open(fn,"rb").read()
    print(f"{fn:22s} computed={compute_checksum(d):#04x}  stored={d[-1]:#04x}  magic={d[-2]:#04x}  match={compute_checksum(d)==d[-1]}")
'
BT_Addr                computed=0xda  stored=0xda  magic=0xaa  match=True
stock_BT_Addr.bin      computed=0xf4  stored=0xf4  magic=0xaa  match=True
WIFI                   computed=0x94  stored=0x94  magic=0xaa  match=True
stock_WIFI.bin         computed=0x6d  stored=0x6d  magic=0xaa  match=True
```

All four pairs match. The algorithm is recovered.

## Step 5 — Confirm by write/reboot/verify

To confirm the trailer is actually what gates the rollback (and not, say, some additional out-of-band signature we haven't found), we run a controlled experiment with **two test runs**: one without the checksum recompute (which we expect to be reverted) and one with it (which we expect to survive). The test MACs are `02:11:22:33:44:55` (BT) and `02:11:22:33:44:66` (WiFi) — the locally-administered bit is set on both so they don't conflict with any real OUI.

### Run A — patch MAC, leave the trailer byte unchanged

```
$ python3 -c '
import hashlib
bt   = bytearray(open("BT_Addr","rb").read())
wifi = bytearray(open("WIFI","rb").read())
bt[0:6]    = bytes.fromhex("021122334455")     # only the MAC bytes change
wifi[4:10] = bytes.fromhex("021122334466")     # trailer byte left as-is
open("BT_Addr.macOnly.bin","wb").write(bt)
open("WIFI.macOnly.bin","wb").write(wifi)
print("BT  patched md5:",hashlib.md5(bt).hexdigest())
print("WIFI patched md5:",hashlib.md5(wifi).hexdigest())
'
BT  patched md5: 5a4df893ce7aa97ee619a00ea40ac226
WIFI patched md5: 3bf3196a4a6f1fb4da6294785b614f42
```

Push, reboot, read back:

```
$ adb push BT_Addr.macOnly.bin /data/local/tmp/BT_Addr.new
$ adb push WIFI.macOnly.bin    /data/local/tmp/WIFI.new
$ adb shell su -c '
    cp /data/local/tmp/BT_Addr.new /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr
    chown root:bluetooth /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr
    chmod 660 /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr
    cp /data/local/tmp/WIFI.new    /mnt/vendor/nvdata/APCFG/APRDEB/WIFI
    chown root:system    /mnt/vendor/nvdata/APCFG/APRDEB/WIFI
    chmod 660 /mnt/vendor/nvdata/APCFG/APRDEB/WIFI
    md5sum /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr /mnt/vendor/nvdata/APCFG/APRDEB/WIFI'
5a4df893ce7aa97ee619a00ea40ac226  /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr
3bf3196a4a6f1fb4da6294785b614f42  /mnt/vendor/nvdata/APCFG/APRDEB/WIFI

$ adb reboot && adb wait-for-device && \
  until [ "$(adb shell getprop sys.boot_completed | tr -d '\r\n')" = "1" ]; do sleep 4; done

$ adb shell su -c 'md5sum /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr /mnt/vendor/nvdata/APCFG/APRDEB/WIFI'
3b1e3de947c00f84d65d3bf37308bd6e  /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr
3759d4a7f89466c8df6dee34a3996ed5  /mnt/vendor/nvdata/APCFG/APRDEB/WIFI

$ adb shell su -c 'settings get secure bluetooth_address'
10:DF:8B:XX:YY:ZZ                                                # original — patch did NOT take
```

Both files are byte-for-byte back to the pre-patch md5 (`3b1e3de9…` for BT_Addr and `3759d4a7…` for WIFI). The daemon detected the trailer mismatch and restored from BinRegion.

### Run B — patch MAC and recompute the trailer byte

```
$ python3 -c '
import hashlib

def compute_checksum(data):
    cs = 0
    for i, b in enumerate(data[:-2]):
        cs = ((cs + b) if i % 2 == 0 else (cs ^ b)) & 0xff
    return cs

bt   = bytearray(open("BT_Addr","rb").read())
wifi = bytearray(open("WIFI","rb").read())
bt[0:6]    = bytes.fromhex("021122334455")
bt[-1]     = compute_checksum(bytes(bt))
wifi[4:10] = bytes.fromhex("021122334466")
wifi[-1]   = compute_checksum(bytes(wifi))
open("BT_Addr.cksum.bin","wb").write(bt)
open("WIFI.cksum.bin","wb").write(wifi)
print(f"BT   new_cs={bt[-1]:#04x}   md5={hashlib.md5(bt).hexdigest()}")
print(f"WIFI new_cs={wifi[-1]:#04x} md5={hashlib.md5(wifi).hexdigest()}")
'
BT   new_cs=0xc8   md5=6d9e7faff80ca25ed61f39e7fba30910
WIFI new_cs=0x9e   md5=b55202a3376ef098a9c8a4a6e137cce6
```

Same push, same reboot, read back:

```
$ adb shell su -c 'md5sum /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr /mnt/vendor/nvdata/APCFG/APRDEB/WIFI'
6d9e7faff80ca25ed61f39e7fba30910  /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr
b55202a3376ef098a9c8a4a6e137cce6  /mnt/vendor/nvdata/APCFG/APRDEB/WIFI

$ adb shell su -c 'dd if=/mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr bs=1 count=6 2>/dev/null | xxd'
00000000: 0211 2233 4455                           ."3DU

$ adb shell su -c 'dd if=/mnt/vendor/nvdata/APCFG/APRDEB/WIFI bs=1 skip=4 count=6 2>/dev/null | xxd'
00000000: 0211 2233 4466                           ."3Df

$ adb shell su -c 'settings get secure bluetooth_address'
02:11:22:33:44:55
```

Both files are byte-identical to what we wrote (md5 `6d9e7faf…` and `b55202a3…`). The Bluetooth runtime address is the new MAC — the BT stack picked up the change at boot. **The daemon validates the trailer and accepts files where the trailer matches the body.**

## What does *not* need to be patched

A natural follow-up is "do we need to also patch the BinRegion mirrors?" The mirror layout: the same WIFI and BT_Addr file content appears at three places on the device:

1. `/mnt/vendor/nvdata/APCFG/APRDEB/{BT_Addr, WIFI}` — the live FS files. These are what the consumers (BT HAL, `wlan_assistant`) read.
2. `/mnt/vendor/nvdata/AllFile` (442 KB) — an in-FS concatenation of the same record content as the `nvram` partition. Indexed by `/mnt/vendor/nvdata/AllMap`. BT_Addr lives at `AllFile[0x3c:0x3c+440]`, WIFI at `AllFile[0x1f4:0x1f4+2050]`.
3. `/dev/block/by-name/nvram` — the `nvram` partition (64 MiB; `operation_type: BINREGION` per the F30 SP Flash scatter file). BT_Addr at `nvram[0x2003c:0x2003c+440]`, WIFI at `nvram[0x201f4:0x201f4+2050]`.

After Run B above, dump 2 and 3 to see how they compare to the patched primary:

```
$ adb shell su -c 'md5sum /mnt/vendor/nvdata/AllFile'
ff5ffa16bb3b31f8e8070909320ecf14   ← unchanged (still pre-patch md5)

$ start=$(adb shell su -c 'cat /sys/block/mmcblk0/mmcblk0p14/start' | tr -d '\r\n')
$ adb shell su -c "dd if=/dev/block/mmcblk0 bs=512 skip=$start count=131072 2>/dev/null | md5sum"
1ce606f8318e52570524a8d2af804d92   ← unchanged (still pre-patch md5)

$ adb shell su -c "dd if=/dev/block/mmcblk0 bs=1 skip=\$(( $start*512 + 0x2003c )) count=6 2>/dev/null | xxd"
00000000: 10df 8bXX YYZZ                           ......   ← original BT MAC, not the patched one
```

So both mirrors are *still* the pre-patch values, but `settings get secure bluetooth_address` reports the patched MAC and the BT_Addr file md5 is the patched md5. **The APRDEB files alone are what the consumers read at runtime; the BinRegion mirrors are out-of-band and don't propagate forward without a separate `BackupToBinRegion` call.** That's a known asymmetry of the MTK NVRAM setup: META-mode writes (via `SN_Writer`) go to BinRegion and propagate forward; AP-side runtime writes go to APRDEB and stay there.

This is what `mac_tool.py` and `live_patch_mac.sh` rely on: only the two APRDEB files need to be patched, and they're tiny (440 + 2050 = 2490 bytes total). The BinRegion mirrors would only matter on a factory-reset path that wipes APRDEB and then has to re-populate it from BinRegion — at which point the user would re-run the patch.

## Block-device write protection (for the patient reader)

A side note useful to anyone working on this generation of MTK device: writes to the partition device node **`/dev/block/by-name/nvram`** (alias `/dev/block/mmcblk0p14`) report success but are silently discarded. Read-back returns the original content even after `sync` and `echo 3 > /proc/sys/vm/drop_caches`:

```
$ adb shell su -c '
    printf PROBE_NVRAM_TEST_AAAA_BBBB_CCCC > /data/local/tmp/probe.bin
    dd if=/data/local/tmp/probe.bin of=/dev/block/by-name/nvram bs=512 count=1 conv=notrunc,fsync
    sync; echo 3 > /proc/sys/vm/drop_caches; sleep 1
    dd if=/dev/block/by-name/nvram bs=512 count=1 2>/dev/null | head -c 32 | xxd'
0+1 records in
0+1 records out
32 bytes (32 B) copied, 0.000990 s, 32 K/s
00000000: 1056 0000 15bf 0600 ffff ffff 47c3 5e28  .V..........G.^(   ← original bytes, not the probe
```

The same write via the **whole-disk node** `/dev/block/mmcblk0` with a sector-aligned `seek=` derived from the partition's `start` value works:

```
$ adb shell su -c '
    start=$(cat /sys/block/mmcblk0/mmcblk0p14/start)
    dd if=/data/local/tmp/probe.bin of=/dev/block/mmcblk0 bs=512 seek=$start count=1 conv=notrunc,fsync
    dd if=/dev/block/mmcblk0       bs=512 skip=$start count=1 2>/dev/null | head -c 32 | xxd
    dd if=/dev/block/by-name/nvram bs=512 count=1 2>/dev/null               | head -c 32 | xxd'
0+1 records in
0+1 records out
32 bytes (32 B) copied, 0.000929 s, 24 K/s
00000000: 5052 4f42 455f 4e56 5241 4d5f 5445 5354  PROBE_NVRAM_TEST   ← whole-disk read shows the probe
00000000: 1056 0000 15bf 0600 ffff ffff 47c3 5e28  .V..........G.^(   ← partition-node read still serves stale
```

So there's an MTK MMC-driver hook that filters writes addressed by partition device but lets writes go through when addressed by sector on the whole-disk device. Not relevant to the live-patch flow on this branch (we only touch the 2 APRDEB files), but this is a load-bearing footnote for anyone patching `nvram` directly via mtkclient or for offline tooling that wants to flash a patched `nvram.img`. Use the whole-disk path.

## Summary of provenance

```
mac_tool.py component             Primary source                     How verified
────────────────────────────────────────────────────────────────────────────────────────
File layouts                      Hex dump of live and stock         All known files round-trip:
(BT_Addr 440B / WIFI 2050B)       BT_Addr / WIFI files               read-back equals what was written

Trailer marker (aa CC)            Disassembled NVM_CheckFile in      Modem accepts files where
                                  /vendor/lib64/libnvram.so          NVM_CheckFile passes (Run B)
                                                                      and silently restores files
                                                                      where it fails (Run A)

Checksum algorithm                Disassembled NVM_ComputeCheckNo    Computes correct checksum
(ADD on even index, XOR on odd,    in /vendor/lib64/libnvram.so       byte for all four known
exclude last 2 bytes)                                                  (file, trailer) pairs

WIFI hdr (01 00 08 00) +          Hex dump of every WIFI file we     Used to find WIFI/BT_Addr
BT_Addr trailer fingerprint       have                                copies inside an nvdata or
                                                                      nvram partition image without
                                                                      mounting the filesystem
```

## Reproducibility

Every step above can be reproduced with:

1. A rooted DuoQin F21 Pro (Magisk).
2. `adb` over USB.
3. Python 3.6+ (stdlib only — no `pycryptodome` needed; the format is plaintext).
4. Android NDK (any recent version) for `llvm-objdump`. Disassembly uses `--disassemble-symbols=NVM_CheckFile` and `--disassemble-symbols=_Z18NVM_ComputeCheckNoPKcPcb`.
5. `dd`, `xxd`, `wc`, `cmp` on the host.

Pull commands use the binary-safe `cp via su /sdcard + adb pull` for filesystem files (or `dd` to `/sdcard` + `adb pull` for raw partition reads). The same patterns documented for IMEI in [`live_patch.md`](live_patch.md) apply unchanged.

## Hardware validation

- **F21 Pro / Android 11 + Magisk, live device, ADB push path** — verified end-to-end with `02:11:22:33:44:55` (BT) and `02:11:22:33:44:66` (WiFi). Both files survived reboot byte-identical to what was written, `settings get secure bluetooth_address` reported the patched BT MAC, the BT stack initialized cleanly. The corresponding `live_patch_mac.sh` end-to-end run (pull → patch → push → reboot → verify) is documented above and is the script's primary self-test.

- **F21 Pro / Android 11 + Magisk, fastboot flash nvdata path** — verified separately with `02:aa:bb:cc:dd:ee` (BT) and `02:aa:bb:cc:dd:ff` (WiFi). Procedure: pull the live `nvdata` partition (`dd if=/dev/block/by-name/nvdata of=/sdcard/nvdata.img bs=1M` then `adb pull`), patch offline with `python3 mac_tool.py write nvdata.img --bt 02:aa:bb:cc:dd:ee --wifi 02:aa:bb:cc:dd:ff -o nvdata_patched.img` (which patches all 18 signature-matching copies — the live ext4 file blocks plus journal/COW remnants), then `adb reboot bootloader` → `fastboot flash nvdata nvdata_patched.img` → `fastboot reboot`. After boot, `mac_tool.py read` on the freshly-pulled `BT_Addr` and `WIFI` files reports `02:aa:bb:cc:dd:ee` and `02:aa:bb:cc:dd:ff` respectively, and `settings get secure bluetooth_address` returns `02:AA:BB:CC:DD:EE`. This confirms `mac_tool.py`'s partition-image mode produces an image whose live ext4 blocks are correctly patched and whose flashed-back state is consistent enough for the runtime daemon to accept it without invoking BinRegion restore.

- **WiFi runtime byte-level confirmation** — Android randomizes `wlan0` per saved-network by default (`addr_assign_type=3`, `macRandomizationSetting: 1`), which masks the chipset's permanent MAC behind a per-SSID random one. To read the chipset's actual MAC at runtime, disable randomization on the active saved network and observe `wlan0/address` after re-associating. The supported user-facing path is Settings → Wi-Fi → network → Privacy → "Use device MAC". The same effect from the shell:

  ```
  $ adb shell su -c '
      sed -i "s|<int name=\"MacRandomizationSetting\" value=\"1\" />|<int name=\"MacRandomizationSetting\" value=\"0\" />|" \
        /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml'
  $ adb reboot   # WifiConfigStore is read at boot
  ```

  After reboot the device re-associates to the saved network with its permanent MAC. With the offline-flash test that wrote `02:0f:f1:1e:11:02` into `WIFI[4:10]`:

  ```
  $ adb shell su -c 'cat /sys/class/net/wlan0/address'
  02:0f:f1:1e:11:02

  $ adb shell su -c 'dumpsys wifi 2>/dev/null | grep "mWifiInfo SSID"'
  mWifiInfo SSID: <ssid-redacted>, BSSID: <bssid-redacted>,
  MAC: 02:0f:f1:1e:11:02, Supplicant state: COMPLETED, …
   macRandomizationSetting: 0
  ```

  Byte-for-byte equal to the patched WIFI file's MAC. Confirms `BT_Addr[0:6]` propagates to `settings get secure bluetooth_address` and `WIFI[4:10]` propagates to `wlan0`'s perm address (visible once Android's randomization layer is turned off for the network). Both consumers got the patched bytes. Re-enable randomization with the inverse `sed` and a reboot if the user wants the privacy layer back.

  An earlier capture of `wpa_supplicant: p2p0: Own MAC address: <patched>` in logcat looked like a runtime confirmation but didn't reproduce on subsequent boots — `p2p0` is also `addr_assign_type=3` on this build, so its userspace-visible MAC is randomized too. The reliable runtime read is via `wlan0/address` with `MacRandomizationSetting=0`, as documented above; ignore the earlier p2p0 line.

- **TIQ M5 (live-tested — full, end-to-end)** — partition dumps analyzed in [`tiq_m5_offline_analysis.md`](tiq_m5_offline_analysis.md); live-device findings in [`tiq_m5_mac_live_findings.md`](tiq_m5_mac_live_findings.md). BT_Addr format / WIFI format / trailer-checksum algorithm all match F21 Pro byte-for-byte; `mac_tool.py` round-trips full `nvdata.bin` byte-identically. **BT MAC patching via `live_patch_mac.sh` works end-to-end on TIQ M5 hardware** — verified across reboots: file persists, daemon validates, `settings get secure bluetooth_address` returns the patched MAC. **WiFi MAC patching also works end-to-end via `live_patch_mac.sh`** — file persists byte-identical, daemon validates, the script's `sync_android_wifi_factory_mac` step invalidates Android 12+'s `WifiConfigStore.xml` cache (the `wifi_sta_factory_mac_address` field, used by `WifiService` to seed per-SSID MAC randomization and "use device MAC" mode), and after reboot `wlan0/address`, `dumpsys wifi`'s `mWifiInfo MAC`, and ARP TX SRC MAC all match the patched `WIFI[4:10]`. The WCS-cache step is credited to the Java port [`flipphoneguy/mtk-imei-switcheroo-app`](https://github.com/flipphoneguy/mtk-imei-switcheroo-app) (whose `MacCrypto.java` is bit-for-bit equivalent to `mac_tool.compute_checksum` and whose `RootRunner.replaceFile` runs the same `mount remount,rw → cp → chmod 660 → chown root:system` primitives), which discovered the cache behavior while testing on F25 and added the equivalent `RootRunner.syncAndroidWifiFactoryMac` in [v1.0.6](https://github.com/flipphoneguy/mtk-imei-switcheroo-app/commit/060697aae1167e3ef217bf7f58fcf867c0a79d9f); the bash version was ported back. Limitation: offline patch + `fastboot flash nvdata` still works for the file but does not invalidate the WCS cache (no Android process at fastboot time), so on Android 12+ the runtime stays at the cached value until either `live_patch_mac.sh` is run once after boot or the field is sed-edited manually. The behavior is Android-version-specific (Android 12+), not chipset- or device-specific — F25 and TIQ M5 hit the same code path; F21 Pro / Android 11 doesn't have the WCS field and is unaffected by this whole class. Full investigation, including the wrong-theory saga that delayed the resolution, in `tiq_m5_mac_live_findings.md`.

- **F25 (offline directly + live-device verified through the Java port)** — partition dumps analyzed in [`f25_offline_analysis.md`](f25_offline_analysis.md). BT_Addr format identical to F21 Pro. WIFI format uses **header `01 00 09 00` instead of `01 00 08 00`** at offset 2; trailer-checksum algorithm is the same. `mac_tool.py` was extended (`WIFI_HDR_VARIANTS = (b'\x01\x00\x08\x00', b'\x01\x00\x09\x00')`) to accept both; full nvdata.bin round-trip is byte-identical. Hardware patching is confirmed by the port author via [`flipphoneguy/mtk-imei-switcheroo-app`](https://github.com/flipphoneguy/mtk-imei-switcheroo-app) on F25 (the port author is the F25 tester). The port is bit-equivalent to `mac_tool.py` for `compute_checksum` / `patch_bt` / `patch_wifi` and to the `push_replace` flow in `live_patch_mac.sh` for the on-device replace primitives, and v1.0.6's `RootRunner.syncAndroidWifiFactoryMac` mirrors `sync_android_wifi_factory_mac`. We do not have F25 hardware on this side; this repo's bash script has not been run directly on F25. The per-device byte at offset 2 (08 vs 09) is what changes across the WiFi-firmware family — the on-disk format and AP-side validation logic are otherwise the same.

- **Other MT67xx / MT67/MT68 devices not in the list above** — **not yet tested for WiFi/BT MAC patching.** Re-running the disassembly and validation steps above against the new device's `/vendor/lib64/libnvram.so` and a known-good `BT_Addr` / `WIFI` file is the first step. If the WIFI header at offset 2 is a value other than 08 or 09, add it to `WIFI_HDR_VARIANTS` after confirming the trailer-checksum still validates on the new sample.
