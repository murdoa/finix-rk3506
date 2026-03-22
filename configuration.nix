# finix system configuration for Luckfox Lyra (RK3506G2), SD card boot.
{
  config,
  pkgs,
  lib,
  finixModules,
  ...
}:
let
  linux-rockchip-rk3506 = pkgs.callPackage ./pkgs/linux-rockchip-rk3506.nix { };
  u-boot-rk3506 = pkgs.callPackage ./pkgs/u-boot-rk3506.nix {
    rkbin = pkgs.callPackage ./pkgs/rkbin.nix { };
  };
  m0-kmod = pkgs.callPackage ./pkgs/m0-kmod.nix {
    kernel = linux-rockchip-rk3506;
  };
  # Switch to m0-firmware-bin for our own firmware once tested
  m0-firmware = pkgs.buildPackages.callPackage ./pkgs/m0-test-firmware.nix { };
in
{
  imports = [ finixModules.sysklogd ];

  networking.hostName = "finix-rk3506";

  boot.kernelPackages = pkgs.linuxPackagesFor linux-rockchip-rk3506;

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

  boot.initrd.kernelModules = [ "mmc_block" "ext4" ];

  boot.extraModulePackages = [ m0-kmod ];

  # GPT: part1=uboot (raw), part2=boot (FAT32), part3=rootfs (ext4)
  fileSystems."/" = {
    device = "/dev/mmcblk0p3";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/mmcblk0p2";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  programs.u-boot-rockchip = {
    enable = true;
    package = u-boot-rk3506;
    dtbPath = "/dtb/rk3506g-luckfox-lyra-sd.dtb";
    bootDevice = "/dev/mmcblk0";
  };

  providers.bootloader.backend = "u-boot-rockchip";

  users.users.root = {
    password = "$6$cqZKvfwHmoQwVp28$61S9QwBIB3Q5c8mUJt6sZW2cejQIta86KxSeFhDDd1CukI45/Nq0VL7GMVVsqOh9sHySkok2K4M3XpY1i404b/";
  };

  finit.ttys.ttyFIQ0 = {
    runlevels = "2345";
    nowait = true;
  };

  # xdg-desktop-portal provides D-Bus interfaces for sandboxed apps (file
  # choosers, screen sharing, etc). Pulled in by finix defaults; not applicable here.
  xdg.portal.enable = false;

  services.mdevd.enable = true;
  services.sysklogd.enable = true;

  # M0 firmware — ELF goes to /lib/firmware for remoteproc
  hardware.firmware = [ m0-firmware ];

  environment.systemPackages = with pkgs; [
    btop
    util-linux
    iproute2
    mtdutils
  ];
}
