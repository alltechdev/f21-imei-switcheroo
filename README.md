# f21-imei-switcheroo

Read and write IMEI(s) in the NVRAM `LD0B_001` file on **DuoQin F21 Pro** (single-SIM), **DuoQin F25** (dual-SIM), and **TIQ M5** (dual-SIM, MT6761) — or in a full `nvdata` partition image — offline, no device needed.

> `live_patch.sh` is an interactive ADB script that patches a live rooted MTK device. On dual-SIM devices it prompts for slot 1 or 2 — see [Live device patching](#live-device-patching).

## Install

```bash
git clone https://github.com/alltechdev/f21-imei-switcheroo
cd f21-imei-switcheroo
pip install pycryptodome
```

That's it. Then run `./live_patch.sh` for the interactive flow, or call `python3 imei_tool.py` directly. Needs Python 3.6+; for live patching you also need `adb` (and `fastboot` if you'd rather flash the partition image).

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
- **F25 (dual-SIM), firmware image only** — `imei_tool.py read`, `write -s 1`, and `write -s 2` exercised against `LD0B_001` extracted from the stock F25 firmware ZIP. Both slots decrypt cleanly with the same AES key, both produce modem-valid MD5-XOR checksums when re-encoded, and both round-trip through `encrypt → decrypt → BCD-decode`. **No F25 hardware was tested**; live-write and reboot behavior on F25 has not been confirmed.
- **TIQ M5 (dual-SIM, MT6761), live device** — `nvdata.bin` pulled via mtkclient, both slots patched offline with `imei_tool.py write -s 1` / `-s 2`, patched image flashed back via mtkclient, device booted. Both IMEIs read back as the written value on-device, confirming the modem accepts patched bytes at runtime. This is the first dual-SIM device validated end-to-end on hardware. Surfaced a bug in `_patch_all_copies` (now fixed) where same-header copies with body differences were being homogenized — see [`docs/reverse_engineering.md` § Hardware validation (TIQ M5)](docs/reverse_engineering.md#hardware-validation-tiq-m5-dual-sim).

## Related

- [`flipphoneguy/f21-imei-switcheroo-app`](https://github.com/flipphoneguy/f21-imei-switcheroo-app) — Java/Android port. Cross-verified bit-for-bit against `imei_tool.py`: same AES key, slot offsets `{0x40, 0x60}`, plaintext layout, and MD5-XOR checksum.

## Credits

- AES key derivation algorithm from [bkerler/mtkclient](https://github.com/bkerler/mtkclient).
- NVRAM call chain and `LD0B_001` structure from the [MTK MOLY modem source](https://github.com/hyperion70/HSPA_MOLY.WR8.W1449.MD.WG.MP.V16) (MT6592, predates MT67xx checksum).
- Modem firmware (`md1img_a.bin`) unpacked with [R0rt1z2/md1imgpy](https://github.com/R0rt1z2/md1imgpy) to confirm key-derivation constants byte-for-byte against the live binary.
- Standard GSM BCD encoding cross-checked against [chuacw/WriteIMEI](https://github.com/chuacw/WriteIMEI) and 3GPP TS 23.003.
- The MD5-XOR checksum (introduced in the MT67xx generation, not present in the leaked MOLY source or any open-source tool) was reverse-engineered black-box on the F21 Pro by decrypting known-good `LD0B_001` files and iterating write/reboot/verify cycles. Full provenance trace in [`docs/reverse_engineering.md`](docs/reverse_engineering.md).
