# Porting finix to the Rockchip RK3506G2

Roadmap and technical notes for running finix on RK3506-based hardware.

---

## SoC overview

The RK3506 (and its package variants RK3506G, RK3506G2, RK3506B) is a Rockchip
SoC from the RK35 series, based on the RK3502 die:

- **CPU**: 3× ARM Cortex-A7 @ up to ~1.4GHz
- **Architecture**: 32-bit ARMv7-A (`armv7l-linux`)
- **Memory**: 32-bit address space, external DDR (DDR init blob runs at 750MHz)
- **Interrupt controller**: ARM GIC-400
- **Timer**: ARMv7 generic timer @ 24MHz
- **Boot ROM**: Rockchip proprietary → SPL → U-Boot
- **Storage**: SPI NAND (FSPI), SD/SDIO (dw-mshc) — **no eMMC controller**
- **USB**: 2× USB 2.0 OTG (DWC2)
- **Ethernet**: 2× Gigabit (GMAC, RMII)
- **Display**: VOP with RGB + MIPI DSI output
- **Other**: 2× CAN-FD, SPI, I2C, UART, GPIO, SAI (audio), PWM, ADC
- **Security**: OP-TEE (TrustZone)

The "G2" suffix denotes a package variant (QFN128). Same silicon and DTS as
RK3506G.

### Mainline status

| Component | Mainline Linux | Mainline U-Boot |
|-----------|---------------|-----------------|
| Clock driver | ✅ (clk-rk3506.c) | ❌ |
| Everything else | ❌ | ❌ |

Mainline support is embryonic. The vendor BSP is required for initial bring-up.

### Vendor BSP sources

| Repo | Branch | Purpose |
|------|--------|---------|
| [rockchip-linux/kernel](https://github.com/rockchip-linux/kernel) | `develop-6.1` | Linux 6.1 BSP kernel with full RK3506 support |
| [rockchip-linux/u-boot](https://github.com/rockchip-linux/u-boot) | `next-dev` | U-Boot with RK3506 board support |
| [rockchip-linux/rkbin](https://github.com/rockchip-linux/rkbin) | `master` | DDR init blob, SPL, TEE, USB plug binaries |

Key rkbin blobs:
- `bin/rk35/rk3506_ddr_750MHz_v1.06.bin` — DDR initialisation
- `bin/rk35/rk3506_spl_v1.11.bin` — first-stage loader
- `bin/rk35/rk3506_tee_v2.10.bin` — OP-TEE (TrustZone)

---

## Roadmap

### Phase 1: cross-compilation and QEMU validation

**Goal**: build a finix system closure for `armv7l-linux` and boot it in QEMU.

finix's module system is architecture-agnostic. The only x86-gated code is in
`boot/kernel.nix` (initrd module lists) and it already uses
`lib.optionals pkgs.stdenv.hostPlatform.isx86` guards.

```nix
# Cross-compile from x86_64 build host
nixpkgs.pkgs = import nixpkgs {
  localSystem = "x86_64-linux";
  crossSystem = "armv7l-linux";
};
```

finix already has `armv7l-linux` in its QEMU matrix (`qemu-system-arm -machine
virt,accel=kvm:tcg`). Use this to validate the base system boots before
touching hardware.

**Tasks**:
- [ ] Cross-build finix system closure for `armv7l-linux`
- [ ] Fix any cross-compilation issues in finix modules
- [ ] Boot in QEMU with a generic ARM kernel (e.g. `pkgs.linuxPackages` for armv7l)
- [ ] Validate finit starts, reaches runlevel 2, TTY works

### Phase 2: vendor BSP kernel package

**Goal**: package the Rockchip BSP kernel 6.1 with RK3506 support.

```nix
# pkgs/linux-rockchip-rk3506.nix
{ lib, fetchFromGitHub, buildLinux, ... }:

buildLinux {
  version = "6.1.x-rockchip";
  modDirVersion = "6.1.x";

  src = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "kernel";
    rev = "<pin-to-specific-commit>";
    hash = "sha256-...";
  };

  # arch/arm/configs/ in the BSP tree
  defconfig = "rk3506_defconfig";

  structuredExtraConfig = with lib.kernel; {
    # Required by finit
    DEVTMPFS = yes;
    DEVTMPFS_MOUNT = yes;
    CGROUPS = yes;
    TMPFS = yes;

    # Required by mdevd (finix default device manager)
    UEVENT_HELPER = no;

    # For initrd
    BLK_DEV_INITRD = yes;
    RD_GZIP = yes;
    RD_ZSTD = yes;
  };
}
```

Usage:
```nix
boot.kernelPackages = pkgs.linuxPackagesFor rockchip-rk3506-kernel;
```

**Tasks**:
- [ ] Package `rockchip-linux/kernel` `develop-6.1` as a Nix derivation
- [ ] Identify correct defconfig (`rk3506_defconfig` or board-specific)
- [ ] Ensure kernel config includes finit requirements (cgroups, devtmpfs, tmpfs)
- [ ] Verify DTBs are built (`arch/arm/boot/dts/rk3506*.dtb`)
- [ ] Test in QEMU with the vendor kernel (generic virt DTB, not rk3506-specific)

### Phase 3: U-Boot bootloader provider

**Goal**: new `providers.bootloader` backend for Rockchip U-Boot.

The RK3506 boot chain:
```
BootROM → DDR blob + SPL (from rkbin) → U-Boot proper → kernel + DTB + initrd
```

This is fundamentally different from Limine (the only current bootloader in
finix). Limine is x86/aarch64 EFI only and explicitly asserts against ARM:

```nix
# from modules/programs/limine/default.nix
assertion = pkgs.stdenv.hostPlatform.isx86_64
         || pkgs.stdenv.hostPlatform.isi686
         || pkgs.stdenv.hostPlatform.isAarch64;
```

A new module is needed:

```
modules/programs/u-boot-rockchip/
├── default.nix                   # options, U-Boot package, DTB, rkbin blobs
└── providers.bootloader.nix      # providers.bootloader backend implementation
```

The install hook needs to:
1. Build `idbloader.img` (DDR blob + SPL, via `mkimage` or `tools/mkimage`)
2. Build `u-boot.itb` (U-Boot + ATF/TEE as FIT image)
3. Write boot image to target media (SD card sectors or SPI NAND)
4. Generate `extlinux.conf` or U-Boot FIT boot script pointing at the finix
   system closure (`/nix/store/.../kernel`, `/nix/store/.../initrd`)

**Tasks**:
- [ ] Package `rockchip-linux/u-boot` `next-dev` for RK3506
- [ ] Package rkbin blobs (DDR, SPL, TEE) as a Nix derivation
- [ ] Create `modules/programs/u-boot-rockchip/default.nix`
- [ ] Implement `providers.bootloader` backend with install hook
- [ ] Support extlinux.conf generation (U-Boot's generic distro boot)
- [ ] Support SD card image generation (for initial bring-up)

### Phase 4: device tree and board support

**Goal**: boot finix on actual RK3506G2 hardware.

If using an EVB or known board, the vendor DTS can be used directly. For custom
boards, a board-specific DTS is needed.

finix currently has no `hardware.deviceTree` module. Options:

1. **Pass DTB via U-Boot** — U-Boot loads the DTB and passes it to the kernel.
   This is the standard Rockchip flow. The DTB lives alongside the kernel in the
   boot partition. No finix module changes needed.

2. **Add a `hardware.deviceTree` module** — for DTB overlays, programmatic DTB
   selection, etc. Nice to have but not blocking.

```nix
# For now, DTB selection happens in U-Boot config / extlinux.conf:
# FDT /nix/store/.../dtbs/rk3506g-myboard.dtb
```

**Tasks**:
- [ ] Select or create board DTS (EVB1 DTS works for Rockchip EVBs)
- [ ] Ensure DTBs are included in system closure
- [ ] Configure U-Boot to load correct DTB
- [ ] First hardware boot — SD card with vendor kernel + finix rootfs
- [ ] Validate: finit PID 1, mdevd, seatd, TTY, networking

### Phase 5: storage (SPI NAND / SD card)

**Goal**: production-ready root filesystem strategy.

The EVB boots from SPI NAND with UBI + SquashFS. For finix, options are:

#### Option A: SD card root (simplest, start here)
```nix
fileSystems."/" = {
  device = "/dev/mmcblk0p2";
  fsType = "ext4";
};
```

#### Option B: SPI NAND + UBI + SquashFS (embedded-appropriate)
Requires:
- `mtd-utils` in initrd (`ubiattach`, `ubimkvol`)
- Kernel config: `CONFIG_MTD`, `CONFIG_MTD_UBI`, `CONFIG_UBIFS_FS`, `CONFIG_SQUASHFS`
- Modified initrd to attach UBI before mounting root
- New finix filesystem module for UBI/UBIFS

#### Option C: SPI NAND + SquashFS + overlayfs (read-only root)
Most robust for embedded — immutable Nix store as SquashFS, writable overlay
for `/etc`, `/var`, etc. Aligns well with Nix's philosophy.

**Tasks**:
- [ ] Phase 5a: boot from SD card (ext4 root)
- [ ] Phase 5b: add UBI/MTD support to finix initrd
- [ ] Phase 5c: implement SquashFS + overlayfs root (stretch)

### Phase 6: mainline kernel and U-Boot

**Goal**: migrate from vendor BSP to mainline where possible.

This phase happens **after** the system is validated end-to-end on vendor BSP.
The purpose is to reduce maintenance burden and benefit from upstream
improvements.

#### Mainline kernel

Current mainline status is clock driver only. Realistically, full mainline
RK3506 support requires upstreaming:
- Pin controller / pinmux
- GPIO
- UART
- dw-mshc (SD/MMC) — generic driver exists, needs DT bindings
- FSPI (SPI NAND)
- USB DWC2 — generic driver exists
- GMAC (stmmac) — generic driver exists, needs DT bindings
- GIC-400, ARMv7 timer — already supported generically
- VOP display — Rockchip-specific, lower priority

Some of these (USB, Ethernet, SD) may work with existing generic drivers once
proper DT bindings are upstreamed. Others (pin controller, clock — already done)
need new code.

**Strategy**: test mainline kernel progressively, enabling peripherals one at a
time. Keep vendor BSP as fallback. Track upstreaming efforts in the Rockchip
community.

#### Mainline U-Boot

Zero mainline U-Boot support exists today. Upstreaming U-Boot support requires:
- SoC support (`arch/arm/mach-rockchip/rk3506/`)
- Board support
- Clock, pinctrl, MMC, SPI drivers
- SPL support (or continue using rkbin SPL with mainline U-Boot proper)

**Pragmatic approach**: use rkbin SPL blob + mainline U-Boot proper. This is a
common pattern in the Rockchip ecosystem — the SPL/DDR blob is hard to replace,
but mainline U-Boot proper can often be made to work with vendor SPL.

**Tasks**:
- [ ] Test mainline kernel with vendor DTB — identify what works out of the box
- [ ] Identify missing drivers / DT bindings
- [ ] Test mainline U-Boot proper with vendor SPL blob
- [ ] Track upstream RK3506 support progress
- [ ] Migrate to mainline as support matures

---

## Architecture notes

### finix compatibility

finix is largely architecture-agnostic:

| Component | ARM impact |
|-----------|-----------|
| finit (PID 1) | Pure C, should cross-compile cleanly for armv7l |
| Module system | Nix-level, no arch dependency |
| initrd | Uses busybox + kmod + finit — all portable |
| mdevd | Pure C, portable |
| seatd | Portable (irrelevant for headless, needed for display) |
| Limine bootloader | ❌ x86/aarch64 only — need U-Boot alternative |
| `boot/kernel.nix` | x86 modules guarded by `isx86` — clean |

### Cross-compilation

nixpkgs handles `armv7l-linux` cross-compilation. Use `crossSystem`:

```nix
import nixpkgs {
  localSystem = "x86_64-linux";
  crossSystem = "armv7l-linux";
}
```

Or for native compilation on an ARM builder:
```nix
import nixpkgs { system = "armv7l-linux"; }
```

Some packages may have cross-compilation issues — these are nixpkgs bugs, not
finix bugs, and should be reported/fixed upstream.

### Memory constraints

The RK3506 is a resource-constrained SoC (likely 64-256MB RAM depending on
board). Consider:

- Minimal system packages — strip unnecessary programs
- SquashFS root to reduce RAM usage
- `zram` swap
- Reduced kernel config — disable unused subsystems
- finix's lazy module loading is an advantage here — smaller eval, smaller closure
