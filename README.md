# f21-imei-switcheroo

Read and write the IMEI in the **DuoQin F21 Pro**'s NVRAM `LD0B_001` file (or in a full `nvdata` partition image dumped from one) — offline, no device needed.

> `live_patch.sh` is an interactive ADB script that patches a live rooted F21 Pro — see [Live device patching](#live-device-patching).

## Install

```bash
git clone https://github.com/alltechdev/f21-imei-switcheroo
cd f21-imei-switcheroo
pip install pycryptodome
```

That's it. Then run `./live_patch.sh` for the interactive flow, or call `python3 imei_tool.py` directly. Needs Python 3.6+; for live patching you also need `adb` (and `fastboot` if you'd rather flash the partition image).

## How it works

The F21 Pro's modem firmware encrypts the IMEI in NVRAM using AES-128-ECB. The decrypted plaintext is a 32-byte block: BCD-encoded IMEI (8 bytes), a 2-byte filler at `[8:10]`, an 8-byte MD5-XOR checksum the modem validates on read, and 14 bytes of zero padding. The modem only validates the checksum — the 2-byte filler can be any value as long as the checksum is computed over it correctly. This tool reimplements the encryption and the checksum so it can rewrite the IMEI without touching the device.

The AES key is `3f06bd14d45fa985dd027410f0214d22` — pre-computed once from MTK's standard NVRAM seed via the `SST_Get_NVRAM_SW_Key` derivation (see [bkerler/mtkclient](https://github.com/bkerler/mtkclient) for the algorithm) and hardcoded as `AES_KEY`.

## Usage

```bash
# Read the IMEI
python3 imei_tool.py read LD0B_001
python3 imei_tool.py read nvdata.img

# Write a new IMEI
python3 imei_tool.py write LD0B_001 350859600862948 -o LD0B_001_new
python3 imei_tool.py write nvdata.img 350859600862948 -o nvdata_patched.img
```

## File formats

| Input | Description |
|-------|-------------|
| `LD0B_001` | 384-byte NVRAM IMEI file from `/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/` |
| `nvdata.img/.bin` | Full nvdata partition image (auto-detected by size > 1MB) |

The tool auto-detects whether the input is a standalone `LD0B_001` or a partition image. For partition images it scans for the `LDI` magic, patches every backup copy with a matching header, and writes a verified output image — no root or mounting needed.

## Live device patching

`live_patch.sh` patches a connected rooted F21 Pro in place: it pulls `/mnt/vendor/nvdata/md/NVRAM/NVD_IMEI/LD0B_001`, runs `imei_tool.py` to rewrite it, pushes it back, and offers to reboot. After reboot the new IMEI is live in the radio and visible to `service call iphonesubinfo`.

End-to-end verified on the F21 Pro (Android 11) with random IMEIs via two paths:
- `live_patch.sh` (push the patched file back through ADB), and
- `fastboot flash nvdata` of a partition image patched by `imei_tool.py`.

In both cases the new IMEI persisted across reboot and showed up in `iphonesubinfo`.

## Credits

- AES key derivation algorithm from [bkerler/mtkclient](https://github.com/bkerler/mtkclient).
- NVRAM call chain and `LD0B_001` structure from the [MTK MOLY modem source](https://github.com/hyperion70/HSPA_MOLY.WR8.W1449.MD.WG.MP.V16) (MT6592, predates MT67xx checksum).
- Modem firmware (`md1img_a.bin`) unpacked with [R0rt1z2/md1imgpy](https://github.com/R0rt1z2/md1imgpy) to confirm key-derivation constants byte-for-byte against the live binary.
- Standard GSM BCD encoding cross-checked against [chuacw/WriteIMEI](https://github.com/chuacw/WriteIMEI) and 3GPP TS 23.003.
- The MD5-XOR checksum (introduced in the MT67xx generation, not present in the leaked MOLY source or any open-source tool) was reverse-engineered black-box on the F21 Pro by decrypting known-good `LD0B_001` files and iterating write/reboot/verify cycles. Full provenance trace in [`docs/reverse_engineering.md`](docs/reverse_engineering.md).
