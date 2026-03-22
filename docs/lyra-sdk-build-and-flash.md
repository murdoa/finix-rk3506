# Lyra SDK Build and Flash Pipeline

How the Luckfox Lyra SDK (based on Rockchip's RK3506 Linux SDK) builds firmware
images and flashes them to a device over USB.

## Overview

The SDK is a `repo`-managed multi-repository workspace. The entry point is
`build.sh` (symlinked from `device/rockchip/common/scripts/build.sh`), and
flashing is done via `rkflash.sh` (symlinked from
`device/rockchip/common/scripts/rkflash.sh`). Both live at the SDK root after
`repo sync`.

The full pipeline:

```
build.sh all
  ├─ mk-loader.sh      → MiniLoaderAll.bin, uboot.img, trust.img
  ├─ mk-kernel.sh      → boot.img (FIT image: kernel + dtb + resource)
  ├─ mk-rootfs.sh      → rootfs.img (ext4/ubifs/squashfs)
  ├─ mk-firmware.sh    → links everything into output/firmware/
  └─ mk-updateimg.sh   → packs update.img (monolithic flash image)
```

Then:

```
sudo ./rkflash.sh update    # flash update.img via USB
```

## SDK Directory Layout

After `repo sync`, the key directories:

```
lyra-sdk/
├── build.sh                → device/rockchip/common/scripts/build.sh
├── rkflash.sh              → device/rockchip/common/scripts/rkflash.sh
├── Makefile                → device/rockchip/common/Makefile
├── device/rockchip/
│   ├── .chips/rk3506/      board configs, parameter files, ITS templates
│   └── common/
│       ├── scripts/         all mk-*.sh build scripts
│       ├── build-hooks/     hook-based build system
│       └── post-hooks/      rootfs post-processing
├── u-boot/                  U-Boot source
├── kernel/ → kernel-6.1/    Linux kernel source
├── buildroot/               Buildroot source
├── rkbin/                   Rockchip binary blobs (DDR init, SPL, etc.)
├── tools/linux/
│   ├── Linux_Upgrade_Tool/  upgrade_tool binary
│   └── Linux_Pack_Firmware/ afptool, rkImageMaker binaries
├── output/
│   ├── firmware/            all final images (symlinks)
│   └── .config              selected board config
└── rockdev/ → output/firmware/
```

## Board Configuration

Each board variant has a defconfig in `.chips/rk3506/`. For example, the
Lyra SPI-NAND config (`luckfox_lyra_buildroot_spinand_defconfig`):

```ini
RK_BUILDROOT_BASE_CFG="rk3506_luckfox"
RK_ROOTFS_UBI=y
RK_UBOOT_CFG="rk3506_luckfox"
RK_UBOOT_SPL=y
RK_KERNEL_CFG="rk3506_luckfox_defconfig"
RK_KERNEL_CFG_FRAGMENTS="rk3506-display.config"
RK_KERNEL_DTS_NAME="rk3506g-luckfox-lyra"
RK_BOOT_COMPRESSED=y
RK_PARAMETER="parameter-lyra-spinand.txt"
RK_USE_FIT_IMG=y
```

The config is processed by `build.sh` via Kconfig-style `Config.in` and stored
in `output/.config`.

## Partition Table (parameter.txt)

Rockchip uses a proprietary `parameter.txt` format instead of (or alongside)
GPT. The SPI-NAND layout for the Lyra:

```
FIRMWARE_VER:8.1
MACHINE_MODEL:RK3506
TYPE: GPT
GROW_ALIGN: 0
CMDLINE:mtdparts=:0x00002000@0x00002000(uboot),0x00006000@0x00004000(boot),-@0x00010000(rootfs:grow)
```

All sizes are in 512-byte sectors. Decoded:

| Partition | Offset    | Size      | Bytes     |
|-----------|-----------|-----------|-----------|
| (hidden)  | 0x0000    | 0x2000    | 4 MiB (IDBlock + SPL) |
| uboot     | 0x2000    | 0x2000    | 4 MiB     |
| boot      | 0x4000    | 0x6000    | 12 MiB    |
| rootfs    | 0x10000   | grow      | rest of flash |

The hidden region at offset 0 contains the IDBlock (Rockchip's first-stage
loader) and the SPL. These are written by `upgrade_tool ul` (upload loader),
not by the partition-based `di` (download image) commands.

## Build Stages

### 1. Loader (mk-loader.sh)

Builds U-Boot and produces:

- **MiniLoaderAll.bin** — The combined first-stage loader (SPL + DDR init)
  used by `upgrade_tool` to bootstrap the device over USB. Built by U-Boot's
  `make.sh` using INI files from `rkbin/RKBOOT/` and `rkbin/RKTRUST/`.
- **uboot.img** — U-Boot proper (second stage), flashed to the `uboot`
  partition.
- **trust.img** — ARM trusted firmware (OP-TEE / ATF), if applicable.

The `--spl-new` flag is used when `RK_UBOOT_SPL=y` (as on the Lyra), which
packs a new-style SPL+TPL combined image.

### 2. Kernel (mk-kernel.sh)

Builds the Linux kernel and produces **boot.img**. On the RK3506 with
`RK_USE_FIT_IMG=y`, this is a FIT (Flattened Image Tree) image containing:

- Compressed kernel image
- Device tree blob (`rk3506g-luckfox-lyra.dtb`)
- Resource image (logos, etc.)

The FIT image is built by `mk-fitimage.sh` using an ITS (Image Tree Source)
template from `.chips/rk3506/zboot.its`:

```dts
images {
    kernel { data = /incbin/("@KERNEL_IMG@"); ... };
    fdt    { data = /incbin/("@KERNEL_DTB@"); ... };
    resource { data = /incbin/("@RESOURCE_IMG@"); ... };
};
```

The `@PLACEHOLDER@` values are sed-replaced with actual file paths, then
`rkbin/tools/mkimage -f` produces the final FIT binary.

### 3. Rootfs (mk-rootfs.sh)

Supports three rootfs systems:

- **Buildroot** (default for Lyra) — built via `mk-buildroot.sh`, which runs
  `make` in the `buildroot/` directory with the board's defconfig.
- **Debian** — pre-built base tarball + customization scripts.
- **Yocto** — OpenEmbedded/BitBake build.

The output is a filesystem image whose format depends on the storage type:

| Storage  | Config          | Image Format |
|----------|-----------------|--------------|
| SD/eMMC  | (default)       | ext4         |
| SPI NAND | `RK_ROOTFS_UBI` | UBIFS → UBI  |

For SPI NAND, `mk-image.sh` creates the UBIFS image via:

```bash
mkfs.ubifs -x lzo -e $LEBSIZE -m $MINIOSIZE -c $MAXLEBCNT -d $SRC_DIR -F -o vol.ubifs
ubinize -o $TARGET -m $MINIOSIZE -p $BLOCKSIZE ubinize.cfg
```

With default NAND parameters: 2 KiB page size, 128 KiB erase block.

Post-rootfs hooks (in `common/post-hooks/`) do final customization: installing
kernel modules, setting hostname, copying overlay files, etc.

### 4. Firmware Assembly (mk-firmware.sh)

Links all built images into `output/firmware/` (aliased as `rockdev/`):

```
output/firmware/
├── parameter.txt    → .chips/rk3506/parameter-lyra-spinand.txt
├── MiniLoaderAll.bin
├── uboot.img
├── boot.img
└── rootfs.img
```

Also validates that each image fits within its partition's size limit from
`parameter.txt`.

### 5. Update Image (mk-updateimg.sh)

If `RK_UPDATE` is set, `mk-firmware.sh` calls `mk-updateimg.sh` to produce
`update.img` — the monolithic image used for USB flashing.

The packing process:

1. **Generate `package-file`** — a manifest mapping partition names to image
   files:

   ```
   # NAME      PATH
   package-file    package-file
   parameter       parameter.txt
   bootloader      MiniLoaderAll.bin
   uboot           uboot.img
   boot            boot.img
   rootfs          rootfs.img
   ```

2. **`afptool -pack ./ update.raw.img`** — Android Firmware Pack Tool reads
   `package-file` and concatenates all images into a single blob with an index
   header.

3. **`rkImageMaker -$TAG MiniLoaderAll.bin update.raw.img update.img`** —
   Prepends the loader binary and a Rockchip-format header (tagged with the
   chip ID, e.g. `RK3506`). The `-os_type:androidos` flag is vestigial; it
   works identically for Linux images.

The resulting `update.img` structure:

```
┌──────────────────────┐
│  RK Header (chip ID) │
├──────────────────────┤
│  MiniLoaderAll.bin   │  ← First-stage loader for USB bootstrap
├──────────────────────┤
│  afptool index       │  ← Partition → offset mapping
├──────────────────────┤
│  parameter.txt       │
│  uboot.img           │
│  boot.img            │
│  rootfs.img          │
│  ...                 │
└──────────────────────┘
```

## Flashing (rkflash.sh + upgrade_tool)

### Prerequisites

The device must be in **Maskrom mode** (holding the BOOT button during power-on,
or with no valid bootloader in flash). The host sees a USB device with Rockchip's
VID/PID.

### upgrade_tool

The proprietary `upgrade_tool` binary (at
`tools/linux/Linux_Upgrade_Tool/Linux_Upgrade_Tool/upgrade_tool`) speaks
Rockchip's USB protocol. Key commands:

| Command | Description |
|---------|-------------|
| `ul <loader>` | Upload loader — sends MiniLoaderAll.bin to bootstrap the SoC |
| `di -p <param>` | Download parameter table |
| `di -uboot <img>` | Flash uboot partition |
| `di -b <img>` | Flash boot partition |
| `di -rootfs <img>` | Flash rootfs partition |
| `uf <update.img>` | Flash unified firmware image (extracts and flashes everything) |
| `rd` | Reset device |
| `EF <loader>` | Erase entire flash |

### rkflash.sh Modes

`rkflash.sh` is a thin wrapper around `upgrade_tool`:

| Mode | What it does |
|------|--------------|
| `update` | `upgrade_tool uf rockdev/update.img` — flash monolithic image |
| `all` | Upload loader, flash each partition individually, then reset |
| `loader` | Upload loader only |
| `boot` | Flash boot partition only |
| `rootfs` | Flash rootfs partition only |
| `uboot` | Flash uboot partition only |
| `erase` | Erase entire flash |
| `rd` | Reset device |

The `update` mode is the simplest — `upgrade_tool` handles extracting the
loader, bootstrapping the device, parsing the embedded parameter table, and
flashing each partition to the correct offset.

The `all` mode does the same thing manually:

```bash
upgrade_tool ul -noreset $LOADER        # bootstrap via USB
upgrade_tool di -p $PARAMETER           # write partition table
upgrade_tool di -uboot $UBOOT           # flash U-Boot
upgrade_tool di -trust $TRUST           # flash trusted firmware
upgrade_tool di -b $BOOT                # flash kernel
upgrade_tool di -r $RECOVERY            # flash recovery
upgrade_tool di -m $MISC                # flash misc
upgrade_tool di -oem $OEM               # flash OEM data
upgrade_tool di -userdata $USERDATA     # flash user data
upgrade_tool di -rootfs $ROOTFS         # flash rootfs
upgrade_tool rd                         # reset
```

### AMP (Asymmetric Multi-Processing)

The RK3506 has both Cortex-A7 (Linux) and Cortex-M0 (RTOS) cores. When
`RK_AMP` is configured, `mk-amp.sh` builds the RTOS firmware and packs it
into an AMP FIT image using `.chips/rk3506/amp_linux.its`. The RTOS binary
(RT-Thread by default) runs on CPU2 with shared RPMsg memory at 0x03c00000.

## Comparison with finix-rk3506

The finix-rk3506 project replaces the entire SDK build pipeline with Nix
derivations while reusing the same binary blobs and partition layout concepts:

| SDK Component | finix-rk3506 Equivalent |
|---------------|------------------------|
| `mk-loader.sh` + rkbin | `pkgs/u-boot-rk3506.nix` + `pkgs/rkbin.nix` |
| `mk-kernel.sh` | `pkgs/linux-rockchip-rk3506.nix` |
| `mk-rootfs.sh` (Buildroot) | NixOS cross-compiled system closure |
| `mk-image.sh` (UBIFS) | `pkgs/nand-image.nix` (mkfs.ubifs + ubinize) |
| `mk-firmware.sh` + `mk-updateimg.sh` | `pkgs/sd-image.nix` / `pkgs/nand-image.nix` |
| `rkflash.sh` + `upgrade_tool` | `apps/` (flash scripts using upgrade_tool or rkdeveloptool) |
| Buildroot post-hooks | NixOS module system + finix |
| `parameter.txt` | Partition offsets hardcoded in image builder scripts |
| AMP FIT image | `m0-firmware/` (custom M0 firmware, separate build) |

The SDK's `update.img` format is not currently used by finix-rk3506. Instead,
images are either written to SD card directly or flashed partition-by-partition
via `upgrade_tool` / `rkdeveloptool`.
