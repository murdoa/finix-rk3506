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
    # fw_devlink=on (default in 6.1) blocks device probe until all DT suppliers
    # are ready. On the RK3506, this causes the MMC controller to sit in deferred
    # probe indefinitely — something in the supplier chain never resolves.
    # "permissive" still creates the device links but doesn't enforce probe ordering.
    "fw_devlink=permissive"
  ];

  # ARM-specific initrd modules — mkForce to override finix's x86-centric defaults
  # (ahci, nvme, sata_*, etc. don't exist in the RK3506 kernel)
  boot.initrd.availableKernelModules = lib.mkForce [
    # SD card (builtin in vendor defconfig, but listed for documentation)
    "dw_mmc"
    "dw_mmc_rockchip"
    "mmc_block"

    # Filesystems — ext4 is =m in vendor defconfig, must be in initrd to mount rootfs
    "ext4"

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
    "ext4"
  ];

  # --- Initrd ---
  # Wait for MMC device to appear before mounting rootfs.
  # The MMC controller probe is deferred so /dev/mmcblk0p3 isn't available
  # immediately after mdevd coldplug. The fs-import retry loop (30x1s)
  # re-runs this until the device shows up.
  boot.initrd.fileSystemImportCommands = ''
    echo "fs-import: ls /dev/mmcblk*:" >/dev/console 2>&1
    ls /dev/mmcblk* >/dev/console 2>&1 || true
    echo "fs-import: ls /dev/mmc*:" >/dev/console 2>&1
    ls /dev/mmc* >/dev/console 2>&1 || true
    echo "fs-import: testing /dev/mmcblk0p3" >/dev/console 2>&1
    test -b /dev/mmcblk0p3
  '';

  # --- Filesystems ---
  # GPT layout: part1=uboot (raw), part2=boot (FAT32), part3=rootfs (ext4)
  fileSystems."/" = {
    device = "/dev/mmcblk0p3";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/mmcblk0p2";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  # --- Bootloader ---
  programs.u-boot-rockchip = {
    enable = true;
    package = u-boot-rk3506;
    # DTB path relative to /boot — extlinux.conf FDT directive
    dtbPath = "/dtb/rk3506g-luckfox-lyra-sd.dtb";
    bootDevice = "/dev/mmcblk0";
  };

  providers.bootloader.backend = "u-boot-rockchip";

  # --- Users ---
  users.users.root = {
    # Set a password for initial bring-up
    # Generate with: mkpasswd -m sha-512
    hashedPassword = "$6$cqZKvfwHmoQwVp28$61S9QwBIB3Q5c8mUJt6sZW2cejQIta86KxSeFhDDd1CukI45/Nq0VL7GMVVsqOh9sHySkok2K4M3XpY1i404b/";
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
  # mdevd — device manager for initrd coldplug and runtime hotplug.
  # Without this, /dev/mmcblk0p3 doesn't exist when the initrd tries
  # to mount the rootfs at /sysroot.
  services.mdevd.enable = true;

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
