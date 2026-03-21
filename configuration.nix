# finix configuration for RK3506G2
#
# This is the top-level system configuration. It targets SD card boot
# as the initial bring-up strategy (Phase 1-4 of the port roadmap).
{
  config,
  pkgs,
  lib,
  finixModules,
  ...
}:
let
  # TODO: replace with self.packages reference once flake wiring is finalised
  linux-rockchip-rk3506 = pkgs.callPackage ./pkgs/linux-rockchip-rk3506.nix { };
  u-boot-rk3506 = pkgs.callPackage ./pkgs/u-boot-rk3506.nix {
    rkbin = pkgs.callPackage ./pkgs/rkbin.nix { };
  };
in
{
  imports = [
    finixModules.sysklogd
  ];

  # --- Networking ---
  networking.hostName = "finix-rk3506";

  # --- Kernel ---
  boot.kernelPackages = pkgs.linuxPackagesFor linux-rockchip-rk3506;

  boot.kernelParams = [
    "console=ttyFIQ0"
    "earlycon=uart8250,mmio32,0xff0a0000"
    "rootwait"
    "rw"
  ];

  # ARM-specific initrd modules — mkForce to override finix's x86-centric defaults
  # (ahci, nvme, sata_*, etc. don't exist in the RK3506 kernel)
  boot.initrd.availableKernelModules = lib.mkForce [
    # SD card
    "dw_mmc"
    "dw_mmc_rockchip"
    "mmc_block"

    # SPI NAND (for future use)
    "spi_rockchip"
    "spi_mem"
    "mtd"

    # USB
    "dwc2"
    "usbhid"
    "hid_generic"
  ];

  boot.initrd.kernelModules = [
    "mmc_block"
  ];

  # --- Filesystems ---
  # SD card root partition (Phase 5a: simplest boot strategy)
  fileSystems."/" = {
    device = "/dev/mmcblk0p2";
    fsType = "ext4";
  };

  # Boot partition (FAT32 for extlinux.conf)
  fileSystems."/boot" = {
    device = "/dev/mmcblk0p1";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  # --- Bootloader ---
  programs.u-boot-rockchip = {
    enable = true;
    package = u-boot-rk3506;
    # DTB path as U-Boot resolves it from the boot partition
    # TODO: adjust for your specific board
    dtbPath = "/boot/dtb/rk3506g-evb1-v10.dtb";
    bootDevice = "/dev/mmcblk0";
  };

  providers.bootloader.backend = "u-boot-rockchip";

  # --- Users ---
  users.users.root = {
    # Set a password for initial bring-up
    # Generate with: mkpasswd -m sha-512
    # password = "$6$...";
  };

  # --- TTY ---
  # Serial console for headless bring-up
  finit.ttys.ttyFIQ0 = {
    runlevels = "2345";
    nowait = true;
  };

  # --- Desktop features we absolutely do not need on an embedded board ---
  xdg.portal.enable = false;



  # --- Services ---
  # sysklogd imported above — many finit conditions depend on syslogd
  services.sysklogd.enable = true;

  # --- Packages ---
  environment.systemPackages = with pkgs; [
    # Essentials for embedded bring-up
    util-linux
    iproute2
    mtdutils
  ];
}
