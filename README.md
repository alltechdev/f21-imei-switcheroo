# mtk-imei-switcheroo

Read and write IMEI(s) in the NVRAM `LD0B_001` file on **DuoQin F21 Pro** (single-SIM), **DuoQin F25** (dual-SIM), and **TIQ M5** (dual-SIM, MT6761) — or in a full `nvdata` partition image — offline, no device needed.

> `live_patch.sh` is an interactive ADB script that patches a live rooted MTK device. On dual-SIM devices it prompts for slot 1 or 2 — see [Live device patching](#live-device-patching).

## Install

```bash
git clone https://github.com/alltechdev/mtk-imei-switcheroo
cd mtk-imei-switcheroo
pip install pycryptodome    # only needed for the IMEI tools (imei_tool.py / live_patch.sh)
```

Then run `./live_patch.sh` for the interactive IMEI flow, or call `python3 imei_tool.py` directly. The WiFi/BT tools (`mac_tool.py` / `live_patch_mac.sh`) are stdlib-only and work without `pycryptodome`. All four need Python 3.6+; live patching also needs `adb` (and `fastboot` if you'd rather flash the partition image offline).

## How it works

On MediaTek MT67xx devices (verified on F21 Pro, F25, and TIQ M5), the modem firmware encrypts each IMEI in NVRAM using AES-128-ECB. The decrypted plaintext is a 32-byte block: BCD-encoded IMEI (8 bytes), a 2-byte filler at `[8:10]`, an 8-byte MD5-XOR checksum the modem validates on read, and 14 bytes of zero padding. The modem only validates the checksum — the 2-byte filler can be any value as long as the checksum is computed over it correctly. Single-SIM units (F21 Pro) populate one slot at `[0x40:0x60]`; dual-SIM units (F25, TIQ M5) populate a second at `[0x60:0x80]` with the same structure. This tool reimplements the encryption and the checksum so it can rewrite either IMEI without touching the device.

The AES key is `3f06bd14d45fa985dd027410f0214d22` — pre-computed once from MTK's standard NVRAM seed via the `SST_Get_NVRAM_SW_Key` derivation (see [bkerler/mtkclient](https://github.com/bkerler/mtkclient) for the algorithm) and hardcoded as `AES_KEY`.

## Usage

```bash
# Read both IMEI slots (single-SIM devices show slot 2 as `(empty)`)
python3 imei_tool.py read LD0B_001
python3 imei_tool.py read nvdata.img

# Write the first IMEI (default; the only slot used by the F21 Pro)
python3 imei_tool.py write LD0B_001 350859600862948 -o LD0B_001_new

# Write the second IMEI on dual-SIM devices (F25, TIQ M5)
python3 imei_tool.py write LD0B_001 350859600862948 -s 2 -o LD0B_001_new

# Patch a full partition image
python3 imei_tool.py write nvdata.img 350859600862948 -o nvdata_patched.img
```

## File formats

| Input | Description |
|-------|-------------|
| `LD0B_001` | 384-byte NVRAM IMEI file from `/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/` |
| `nvdata.img/.bin` | Full nvdata partition image (auto-detected by size > 1MB) |

The tool auto-detects whether the input is a standalone `LD0B_001` or a partition image. For partition images it scans for the `LDI` magic and patches every header-matching `LD0B_001` copy in place — live copy plus any ext4 journal/COW leftovers. Distinct copies whose 0x40-byte header differs (e.g. F25's factory backup) are skipped. No root or mounting needed.

## Live device patching

`live_patch.sh` patches a connected rooted MTK device in place: it pulls `/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001`, runs `imei_tool.py` to rewrite it, pushes it back, and offers to reboot. The script counts populated slots in the read output and prompts accordingly — dual-SIM gets `Change which IMEI? [1/2/n]`, single-SIM gets `Change IMEI? [y/N]`. After reboot the new IMEI is live in the radio and visible to `service call iphonesubinfo`.

### Verification status

- **F21 Pro (Android 11), live device** — end-to-end verified with random IMEIs via both paths: `live_patch.sh` (push patched `LD0B_001` back through ADB) and `fastboot flash nvdata` of a partition image patched offline by `imei_tool.py`. Slot 1 patches persisted across reboot and appeared in `iphonesubinfo`. Slot 2 reads as `(empty)` on this single-SIM device.
- **F25 (dual-SIM), live device** — confirmed end-to-end on F25 hardware via both this repo's `live_patch.sh` and the [`flipphoneguy/mtk-imei-switcheroo-app`](https://github.com/flipphoneguy/mtk-imei-switcheroo-app) Java port: patched IMEIs persist across reboot and the modem accepts the patched bytes at runtime. **F25 hardware testing is performed by the port author (also the F25 device tester); we do not have F25 hardware on this side.** Earlier offline validation against the stock F25 firmware ZIP exercised `imei_tool.py read`, `write -s 1`, and `write -s 2` (both slots decrypt cleanly with the same AES key, both produce modem-valid MD5-XOR checksums when re-encoded, both round-trip through `encrypt → decrypt → BCD-decode`).
- **TIQ M5 (dual-SIM, MT6761), live device** — `nvdata.bin` pulled via mtkclient, both slots patched offline with `imei_tool.py write -s 1` / `-s 2`, patched image flashed back via mtkclient, device booted. Both IMEIs read back as the written value on-device, confirming the modem accepts patched bytes at runtime. This was the first dual-SIM device validated end-to-end on hardware (F25 hardware confirmation followed; see above). Surfaced a bug in `_patch_all_copies` (now fixed) where same-header copies with body differences were being homogenized — see [`docs/reverse_engineering.md` § Hardware validation (TIQ M5)](docs/reverse_engineering.md#hardware-validation-tiq-m5-dual-sim). Subsequently, `./live_patch.sh` ran end-to-end on the same device: dual-SIM `[1/2/n]` prompt routed correctly, slot 1 and slot 2 each patched independently across separate runs (the other slot byte-identical post-patch), file md5 matches across reboot in both runs (modem persists). The script's pull mechanism was extended during this verification to handle a CRLF-injection observation on this device's Android 13 + Magisk combo (see the same RE doc section).

## WiFi MAC and Bluetooth address

The same NVRAM family also stores the WiFi MAC and Bluetooth address, plaintext but checksum-validated by the MTK NVRAM daemon. `mac_tool.py` (offline) and `live_patch_mac.sh` (live device) handle these the same way `imei_tool.py` / `live_patch.sh` handle IMEI.

```bash
# Offline read / write — operates on host-side files. The on-device source
# files live at /mnt/vendor/nvdata/APCFG/APRDEB/BT_Addr (440 bytes) and
# /mnt/vendor/nvdata/APCFG/APRDEB/WIFI (2050 bytes); pull them to the host
# via the binary-safe pattern in docs/live_patch.md before reading them
# locally, or pass a partition image (nvram.img / nvdata.img) directly.
python3 mac_tool.py read BT_Addr
python3 mac_tool.py read WIFI
python3 mac_tool.py read nvdata.img

python3 mac_tool.py write BT_Addr --bt   02:11:22:33:44:55 -o BT_Addr.patched
python3 mac_tool.py write WIFI    --wifi 02:11:22:33:44:66 -o WIFI.patched
python3 mac_tool.py write nvdata.img --bt   02:11:22:33:44:55 \
                                     --wifi 02:11:22:33:44:66 -o nvdata.patched.img

# Live device flow (interactive). Pulls, patches, pushes, offers reboot.
./live_patch_mac.sh
```

`live_patch_mac.sh` asks two independent prompts — `Change BT MAC? [y/N]` and `Change WiFi MAC? [y/N]` — so a single run can change BT only, WiFi only, both, or neither. If neither, the script exits without offering a reboot. The 6-byte MAC is validated client-side against `^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$` (colon or dash separators).

The trailer-byte algorithm (the only non-trivial piece) was recovered by disassembling `_Z18NVM_ComputeCheckNoPKcPcb` in `/vendor/lib64/libnvram.so` on the F21 Pro: walk the file excluding the last 2 bytes, ADD on even-indexed bytes, XOR on odd-indexed bytes, store the low 8 bits as the trailer byte after a fixed `0xaa` magic. Full step-by-step trace in [`docs/wifi_bt_reverse_engineering.md`](docs/wifi_bt_reverse_engineering.md). Reference docs: [`docs/mac_tool.md`](docs/mac_tool.md) and [`docs/live_patch_mac.md`](docs/live_patch_mac.md). The stock F30 partition images used as a known-good reference came from the classic "F30 US LTE Bands Package" originally posted on XDA ([forum thread](https://xdaforums.com/t/guide-xiaomi-qin-f21-pro-with-us-bands.4579393/)) — F30 and F21 Pro share the MT6761 platform and the same NVRAM record layouts.

### Verification status

**Offline-tool compatibility** verified on **F21 Pro**, **F25**, and **TIQ M5**. `mac_tool.py` recognizes BT_Addr / WIFI records on all three; the regression sweep `tests/mac_tool_edge_cases.sh` includes byte-identical full-image round-trip tests for each when the partition dumps are present in `tmp/{wifi_bt_re,tiqm5,f25}/`. F25's WIFI uses header `01 00 09 00` instead of `01 00 08 00` — `mac_tool.py`'s `WIFI_HDR_VARIANTS` accepts both. Per-device offline RE: [`docs/tiq_m5_offline_analysis.md`](docs/tiq_m5_offline_analysis.md), [`docs/f25_offline_analysis.md`](docs/f25_offline_analysis.md).

**Live-device verification** confirmed on F21 Pro and TIQ M5 directly; F25 confirmed through the upstream Java port (we do not have F25 hardware on this side):

- **F21 Pro** — exercised end-to-end via this repo's `live_patch_mac.sh` (ADB-push path) and `mac_tool.py` + `fastboot flash nvdata` (offline path). Each run wrote to a fresh test MAC, rebooted, and confirmed:
  - both `BT_Addr` and `WIFI` files survive reboot byte-identical to what was written;
  - `settings get secure bluetooth_address` returns the patched BT MAC byte-for-byte;
  - WiFi runtime byte-level read confirmed by setting `MacRandomizationSetting=0` on the active saved network (Settings → Wi-Fi → network → Privacy → "Use device MAC", or `sed -i 's|MacRandomizationSetting" value="1"|MacRandomizationSetting" value="0"|' /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml` + reboot) — `cat /sys/class/net/wlan0/address` and `dumpsys wifi`'s `mWifiInfo MAC` then both byte-match the patched `WIFI[4:10]`. With randomization back on, Android's per-SSID randomization re-asserts on top, but the chipset's permanent address (loaded from the patched file) is unchanged. The four prompt branches of `live_patch_mac.sh` (yy / yn / ny / nn) are also verified live.
- **F25** — verified through the Java port [`flipphoneguy/mtk-imei-switcheroo-app`](https://github.com/flipphoneguy/mtk-imei-switcheroo-app) on F25 hardware. The port is bit-equivalent to `mac_tool.py` for the checksum/patch/replace primitives, and v1.0.6's `RootRunner.syncAndroidWifiFactoryMac` is the equivalent of `live_patch_mac.sh`'s `sync_android_wifi_factory_mac` step. F25 hardware testing is performed by the port author; we do not have F25 hardware on this side and have not run this repo's bash script directly on F25.
- **TIQ M5** — `live_patch_mac.sh` works end-to-end for both BT and WiFi MAC on hardware. BT: file persists byte-identical, daemon validates, `settings get secure bluetooth_address` returns the patched value across reboots. WiFi: file persists byte-identical, daemon validates, **and** the script invalidates Android's cached factory WiFi MAC in `WifiConfigStore.xml` (the `wifi_sta_factory_mac_address` field, used by `WifiService` on Android 12+ to seed per-SSID MAC randomization and "use device MAC" mode); after reboot, `wlan0/address`, `dumpsys wifi`'s `mWifiInfo MAC`, and ARP TX SRC MAC all match the patched `WIFI[4:10]`. **Credit for the WCS-cache fix goes to [`flipphoneguy/mtk-imei-switcheroo-app`](https://github.com/flipphoneguy/mtk-imei-switcheroo-app)** — the port (which uses this repo's algorithms and primitives as its base) discovered the Android 12+ WCS-cache behavior while testing on F25 and added `RootRunner.syncAndroidWifiFactoryMac` in [v1.0.6](https://github.com/flipphoneguy/mtk-imei-switcheroo-app/commit/060697aae1167e3ef217bf7f58fcf867c0a79d9f); the equivalent step in `live_patch_mac.sh` is ported back from there. The behavior is Android-version-specific (Android 12+), not device-specific — F25 and TIQ M5 both run Android 12+ and both need the cache invalidation; F21 Pro / Android 11 doesn't have the field and the script's sync step is a silent no-op there. **Limitation: offline patch + `fastboot flash nvdata`** patches the file but does **not** invalidate the WCS cache (no Android process is running at fastboot time), so on Android 12+ the runtime WiFi MAC stays at the previous cached value until either `live_patch_mac.sh` is run once after boot or the field is sed-edited manually. Full saga of the investigation that led to this fix: [`docs/tiq_m5_mac_live_findings.md`](docs/tiq_m5_mac_live_findings.md).

> ⚠ Modifying an IMEI, Bluetooth, or WiFi MAC is illegal in some jurisdictions. You are responsible for checking your local laws and using this tool accordingly.

## Related

- [`flipphoneguy/mtk-imei-switcheroo-app`](https://github.com/flipphoneguy/mtk-imei-switcheroo-app) — Java/Android port. Cross-verified bit-for-bit against this repo's tools:
  - **IMEI side** (against `imei_tool.py`): same AES key, slot offsets `{0x40, 0x60}`, plaintext layout, and MD5-XOR checksum.
  - **BT MAC + WiFi MAC side** (v1.0.5, against `mac_tool.py`): `MacCrypto.computeChecksum` is a direct Java port of `mac_tool.compute_checksum`. Verified equivalent on real partition samples — F21 Pro live + stock, F25, TIQ M5, F30 stock — every stored trailer byte computes the same on both implementations, and `patchBt` / `patchWifi` produce byte-identical output to `patch_bt` / `patch_wifi` for the same input. Their "supported device gate" is the trailer-checksum match itself, which transparently handles F25's `01 00 09 00` WIFI header without needing a header whitelist (because the patch path leaves the header untouched).

## Credits

- AES key derivation algorithm from [bkerler/mtkclient](https://github.com/bkerler/mtkclient).
- NVRAM call chain and `LD0B_001` structure from the [MTK MOLY modem source](https://github.com/hyperion70/HSPA_MOLY.WR8.W1449.MD.WG.MP.V16) (MT6592, predates MT67xx checksum).
- Modem firmware (`md1img_a.bin`) unpacked with [R0rt1z2/md1imgpy](https://github.com/R0rt1z2/md1imgpy) to confirm key-derivation constants byte-for-byte against the live binary.
- Standard GSM BCD encoding cross-checked against [chuacw/WriteIMEI](https://github.com/chuacw/WriteIMEI) and 3GPP TS 23.003.
- The MD5-XOR checksum (introduced in the MT67xx generation, not present in the leaked MOLY source or any open-source tool) was reverse-engineered black-box on the F21 Pro by decrypting known-good `LD0B_001` files and iterating write/reboot/verify cycles. Full provenance trace in [`docs/reverse_engineering.md`](docs/reverse_engineering.md).
- Discovery and fix of the Android 12+ `WifiConfigStore.xml` cache (the `wifi_sta_factory_mac_address` field that `WifiService` seeds on first boot and then uses for "device MAC" / per-SSID randomization regardless of subsequent file changes) — credit to [`flipphoneguy/mtk-imei-switcheroo-app`](https://github.com/flipphoneguy/mtk-imei-switcheroo-app), which identified the cache while testing on F25 and shipped `RootRunner.syncAndroidWifiFactoryMac` in [v1.0.6](https://github.com/flipphoneguy/mtk-imei-switcheroo-app/commit/060697aae1167e3ef217bf7f58fcf867c0a79d9f); ported back into `live_patch_mac.sh` as `sync_android_wifi_factory_mac`.
