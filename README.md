# finix-rk3506

[finix](https://github.com/finix-community/finix) running on the Rockchip RK3506 — a triple Cortex-A7 SoC for embedded and industrial use.

finix is an experimental NixOS alternative using [finit](https://github.com/troglobit/finit) as PID 1 instead of systemd. This repo is a complete board support package that cross-compiles a bootable SD card image from an x86_64 host.

## What's in the box

- **Nix flake** that cross-compiles an entire system (`x86_64-linux` → `armv7l-linux`)
- **Vendor BSP kernel** (Rockchip Linux 6.1) with custom device tree for the [Luckfox Lyra](https://www.luckfox.com/Luckfox-Lyra)
- **U-Boot bootloader** with rkbin blob packaging (DDR init, SPL, OP-TEE)
- **Cortex-M0 firmware** — bare-metal code that runs on the RK3506's auxiliary M0 core via Linux remoteproc, loaded at boot
- **Remoteproc kernel module** — out-of-tree `rk3506_rproc` driver that manages the M0 lifecycle
- **One-command SD card image** — GPT image with U-Boot, boot partition, and Nix store rootfs
- **One-command flash** — `nix run .#flash` writes the image to an SD card

## Building

```bash
# Build the bootable SD card image
nix build .#packages.x86_64-linux.sdImage

# Flash it (interactive, with safety checks)
nix run .#flash

# Or build individual pieces
nix build .#linux-rockchip-rk3506
nix build .#u-boot-rk3506
nix build .#rkbin
```

## Hardware

The target board is the **Luckfox Lyra** (RK3506G2, QFN128 package).

| | |
|---|---|
| **CPU** | 3× ARM Cortex-A7 @ 1.4 GHz |
| **MCU** | 1× ARM Cortex-M0 @ 200 MHz (48 KiB SRAM) |
| **Arch** | ARMv7-A (32-bit) |
| **Storage** | SPI NAND, SD/SDIO (no eMMC) |
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
├── configuration.nix              # System config (kernel, modules, filesystems, services)
├── m0-firmware/                   # Bare-metal Cortex-M0 firmware
│   ├── main.c                     # UART4 hello + GPIO heartbeat
│   ├── startup.S                  # Vector table, BSS init, entry
│   ├── linker.ld                  # Memory layout (32K TCM @ 0x0)
│   └── kmod/                      # Out-of-tree remoteproc driver
├── pkgs/
│   ├── linux-rockchip-rk3506.nix  # BSP kernel 6.1
│   ├── u-boot-rk3506.nix          # U-Boot + rkbin blob assembly
│   ├── rkbin.nix                   # DDR init, SPL, OP-TEE blobs
│   ├── m0-firmware-bin.nix         # M0 firmware derivation
│   ├── m0-kmod.nix                 # Remoteproc driver derivation
│   ├── sd-image.nix                # Bootable SD card image
│   ├── kernel-dts/                 # Custom device tree sources
│   └── u-boot-dts/                 # Custom U-Boot device tree + defconfig
├── modules/
│   ├── u-boot-rockchip/            # finix bootloader provider for Rockchip U-Boot
│   └── cross-toplevel.nix          # Cross-compilation glue for finix
├── apps/
│   └── flash.nix                   # SD card writer with safety checks
└── docs/
    ├── rk3506-port.md              # Full porting roadmap
    └── m0-firmware-guide.md        # M0 development reference
```

## Status

This boots on real hardware. The system comes up with finit as PID 1, mdevd for device management, serial console on the debug UART, and the M0 running firmware alongside Linux.

Remaining work:

- [ ] Mainline kernel migration (currently vendor BSP only; mainline has clock driver, nothing else)
- [ ] SPI NAND boot (currently SD card only)
- [ ] Shared memory / mailbox between A7 and M0
- [ ] SWD debugging for M0 (debug mux registers are undocumented)

See [`docs/rk3506-port.md`](docs/rk3506-port.md) for the full roadmap.

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
