# finix-rk3506

[finix](https://github.com/finix-community/finix) on the Rockchip RK3506G2.

finix is an experimental NixOS alternative using [finit](https://github.com/troglobit/finit) as PID 1 instead of systemd. This repo ports it to the RK3506 — a triple Cortex-A7 (ARMv7) SoC targeting embedded/industrial use.

## Status

**Phase 1** — bootstrapping. Nothing boots yet. We're building the scaffolding:

- [x] Flake structure with cross-compilation (`x86_64-linux` → `armv7l-linux`)
- [x] Rockchip rkbin blob packaging (DDR init, SPL, TEE)
- [x] Vendor BSP kernel package (rockchip-linux/kernel 6.1)
- [x] Vendor U-Boot package (rockchip-linux/u-boot)
- [x] `providers.bootloader` backend for Rockchip U-Boot + extlinux.conf
- [x] System configuration targeting SD card boot
- [ ] SD card image generation (TODO: rethink as a proper Nix derivation)
- [ ] First successful cross-build of system closure
- [ ] QEMU validation
- [ ] First hardware boot
- [ ] Mainline kernel/u-boot migration

See [docs/rk3506-port.md](docs/rk3506-port.md) for the full roadmap.

## Building

```bash
# Build the system closure (cross-compiled from x86_64)
nix build .#nixosConfigurations.rk3506.config.system.topLevel

# Build individual packages
nix build .#packages.x86_64-linux.rkbin
nix build .#packages.x86_64-linux.linux-rockchip-rk3506
nix build .#packages.x86_64-linux.u-boot-rk3506
```

## SD card image

TODO: SD card image generation needs a proper rethink — ideally a pure Nix derivation instead of an imperative bash script with `sudo`.

## Hardware

The RK3506G2 is a Rockchip SoC with:
- 3× ARM Cortex-A7 @ ~1.4GHz
- 32-bit ARMv7-A
- SPI NAND + SD/SDIO storage (no eMMC)
- 2× USB 2.0 OTG, 2× Gigabit Ethernet, 2× CAN-FD
- RGB + MIPI DSI display output

## License

Code in this repo is MIT. Vendor components have their own licenses:
- rkbin blobs: Rockchip proprietary (redistributable)
- Vendor kernel: GPL-2.0
- Vendor U-Boot: GPL-2.0
