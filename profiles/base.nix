# Base hardware profile for Luckfox Lyra (RK3506G2).
#
# Board-level constants: kernel, kernel params, initrd modules, u-boot.
# Imported by profiles/sd.nix, profiles/nand.nix, and the flasher config.
{ pkgs, lib, board, ... }:
{
  boot.kernelPackages = pkgs.linuxPackagesFor board.kernel;

  boot.kernelParams = [
    "console=ttyFIQ0"
    "earlycon=uart8250,mmio32,0xff0a0000"
    "rootwait"
    "rw"
  ];

  # mkForce: override finix's x86-centric defaults (ahci, nvme, etc.)
  boot.initrd.availableKernelModules = lib.mkForce [
    "dw_mmc"
    "dw_mmc_rockchip"
    "mmc_block"
    "ext4"
    "spi_rockchip"
    "spi_mem"
    "mtd"
    "dwc2"
    "usbhid"
    "hid_generic"
  ];

  programs.u-boot-rockchip = {
    enable = true;
    package = board.u-boot;
  };

  providers.bootloader.backend = "u-boot-rockchip";
}
