# finix-rk3506

<p align="center">
  <img src="imgs/luckfox-lyra-b.jpg" alt="Luckfox Lyra" width="600">
</p>

[finix](https://github.com/finix-community/finix) running on the Rockchip RK3506 — a triple Cortex-A7 SoC for embedded and industrial use.

This is a complete board support package for the [Luckfox Lyra](https://www.luckfox.com/Luckfox-Lyra) ($12.99). It cross-compiles a bootable system from an x86_64 host, targeting either SD card or SPI NAND flash. One command to build, one command to flash.

## What's in the box

- **Nix flake** — cross-compiles everything (`x86_64-linux` → `armv7l-linux`), no target toolchain needed
- **Vendor BSP kernel** (Rockchip Linux 6.1) with custom device trees for SD and SPI NAND boot
- **U-Boot bootloader** with rkbin blob packaging (DDR init, SPL, OP-TEE)
- **Open-source USB flashing** — a U-Boot-based usbplug replaces Rockchip's proprietary `rk3506_usbplug_v1.03.bin` for writing SPI NAND over USB
- **SPI NAND support** — UBI/UBIFS rootfs on 256 MiB Winbond W25N02KV, flashed via `rkdeveloptool`
- **Cortex-M0 firmware** — bare-metal code for the RK3506's auxiliary M0 core, auto-loaded at boot via remoteproc
- **One-command build and flash** for both SD card and SPI NAND targets

## Quick start

```bash
# --- SD card ---
nix build .#sdImage
nix run .#flash              # interactive, writes to SD card

# --- SPI NAND (primary) ---
nix build .#nandImage
nix run .#flash-nand         # interactive, flashes via USB (rkdeveloptool)

# --- SPI NAND (fallback) ---
nix build .#nandFlasherImage
nix run .#flash-nand-sd      # writes a self-flashing SD card image
```

### How SPI NAND flashing works

The board enters Maskrom mode (hold BOOT, plug USB). `flash-nand` downloads an open-source U-Boot usbplug onto the SoC via `rkdeveloptool db`, which brings up U-Boot's MTD stack in RAM. The host then writes the full NAND image via `rkdeveloptool wl`. This replaces Rockchip's proprietary usbplug firmware, which had a bug that corrupted SPI NAND writes.

The fallback path (`flash-nand-sd`) writes an SD card that boots Linux and flashes the NAND UBI partition through the kernel MTD stack. It shows a countdown on the serial console — press any key to abort and get a shell instead.

## Hardware

Target board: **Luckfox Lyra** (RK3506G2, QFN128).

| | |
|---|---|
| **CPU** | 3× ARM Cortex-A7 @ 1.4 GHz |
| **MCU** | 1× ARM Cortex-M0 @ 200 MHz (48 KiB SRAM) |
| **Arch** | ARMv7-A (32-bit) |
| **Flash** | 256 MiB SPI NAND (Winbond W25N02KV) |
| **Storage** | SD/SDIO (no eMMC) |
| **USB** | 2× USB 2.0 OTG |
| **Ethernet** | 2× Gigabit (GMAC, RMII) |
| **Bus** | 2× CAN-FD, SPI, I2C, UART |
| **Display** | RGB + MIPI DSI |

## Cortex-M0

The RK3506 has a dedicated Cortex-M0 core with 48 KiB of SRAM and full peripheral access. This repo includes everything needed to run bare-metal firmware on it:

- **Out-of-tree remoteproc driver** (`rk3506_rproc`) — loads ELF firmware, handles SRAM remapping via Rockchip SIP calls, manages the M0 lifecycle through `/sys/class/remoteproc/`
- **Bare-metal firmware** — startup assembly, linker script, resource table, UART + GPIO example. Builds with `arm-none-eabi-gcc` in a Nix derivation
- **Development guide** — complete reference for the M0's memory map, peripheral access, pin muxing, clock gating, and constraints. See [`docs/m0-firmware-guide.md`](docs/m0-firmware-guide.md)

The firmware auto-loads at boot — the `rk3506_rproc` module is built, installed, and the ELF is placed in `/lib/firmware/` as part of the system closure.

## Project structure

```
├── flake.nix                      # Cross-compilation flake
├── configuration.nix              # System config (services, users, M0 firmware)
├── configuration-nand-flasher.nix # Standalone self-flashing SD card config
├── profiles/                      # Boot profiles (base hw, SD, NAND)
├── overlays/                      # Closure-reduction overlays
├── modules/                       # finix modules (u-boot, cross-toplevel, minimal)
├── m0-firmware/                   # Bare-metal Cortex-M0 firmware + remoteproc driver
├── pkgs/                          # Nix derivations (kernel, u-boot, images, usbplug)
│   ├── kernel-dts/                # Custom device tree sources (Linux)
│   └── u-boot-dts/                # Custom device tree + defconfigs (U-Boot)
├── apps/                          # Flash scripts (flash, flash-nand, flash-nand-sd)
└── docs/                          # M0 development guide
```

## Status

This boots on real hardware. The system comes up with finit as PID 1, mdevd for device management, serial console on the debug UART, and the M0 running firmware alongside Linux. Both SD card and SPI NAND boot paths are working and hardware-verified.

Remaining work:

- [ ] Shared memory / mailbox between A7 and M0


## Attributions

- **[finix](https://github.com/finix-community/finix)** — the NixOS alternative this is built on. finix's architecture-agnostic module system made this ARM port possible without forking anything.

- **[nvitya/rk3506-mcu](https://github.com/nvitya/rk3506-mcu)** — the remoteproc kernel driver for the RK3506's Cortex-M0 is based on nvitya's work. They reverse-engineered the SIP call interface and SRAM remapping that makes M0 firmware loading possible. The `rk3506_rproc` driver in this repo is derived from their implementation.

- **[nvitya/vihal](https://github.com/nvitya/vihal)** — nvitya's hardware abstraction library was an invaluable reference for RK3506 register definitions and peripheral initialization.

- **Rockchip** — vendor BSP kernel, U-Boot, and rkbin blobs from [rockchip-linux](https://github.com/rockchip-linux).

## License

Code in this repo is MIT. Vendor components carry their own licenses:
- rkbin blobs: Rockchip proprietary (redistributable)
- Vendor kernel: GPL-2.0
- Vendor U-Boot: GPL-2.0
- Remoteproc driver: GPL-2.0
