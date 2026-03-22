# finix system configuration for Luckfox Lyra (RK3506G2), SPI NAND boot.
#
# Boot flow: BootROM → idbloader (raw) → U-Boot (raw) → extlinux.conf
#            (mtd_blk boot partition) → kernel → ubi.mtd=4 → UBIFS rootfs
#
# Flash layout (256 MiB SPI NAND, Winbond W25N02KV):
#   mtd0: env        (0x000000  - 0x040000,   256K)
#   mtd1: idblock    (0x040000  - 0x080000,   256K)
#   mtd2: uboot      (0x080000  - 0x400000,   3.5M)
#   mtd3: boot       (0x400000  - 0x1800000,  20M) — extlinux, kernel, initrd, DTB
#   mtd4: ubi        (0x1800000 - 0x10000000, 232M) — UBIFS rootfs (LZO)
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
  m0-firmware = pkgs.buildPackages.callPackage ./pkgs/m0-firmware-bin.nix { };
in
{
  imports = [
    finixModules.sysklogd
    ./modules/filesystems/ubifs.nix
  ];

  networking.hostName = "finix-rk3506";

  boot.kernelPackages = pkgs.linuxPackagesFor linux-rockchip-rk3506;

  boot.kernelParams = [
    "console=ttyFIQ0"
    "earlycon=uart8250,mmio32,0xff0a0000"
    "rootwait"
    "rw"
    # Auto-attach UBI to the partition named "ubi".
    # Using name instead of index because U-Boot injects cmdlinepart mtdparts
    # which may produce different numbering than the DTS fixed-partitions.
    "ubi.mtd=ubi"
  ];

  # mkForce: override finix's x86-centric defaults (ahci, nvme, etc.)
  # All SPI NAND / UBI / UBIFS drivers are built-in (=y in vendor defconfig),
  # so no modules needed for the boot path. Keep SD card modules for recovery.
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

  boot.initrd.kernelModules = [ "mmc_block" ];

  boot.extraModulePackages = [ m0-kmod ];
  boot.kernelModules = [ "rk3506_rproc" ];

  # UBIFS rootfs on UBI volume "rootfs"
  fileSystems."/" = {
    device = "ubi0:rootfs";
    fsType = "ubifs";
  };

  # No separate boot partition mount — boot lives on raw mtd_blk, not a
  # Linux-visible filesystem. U-Boot reads it directly via mtd_blk GPT.

  programs.u-boot-rockchip = {
    enable = true;
    package = u-boot-rk3506;
    dtbPath = "/dtb/rk3506g-luckfox-lyra-nand.dtb";
    # For NAND boot, there's no single block device — U-Boot reads from
    # SPI NAND directly. The install hook is a no-op for NAND (flash is
    # done via rkdeveloptool or SD card self-flash, not dd).
    bootDevice = "/dev/null";
  };

  providers.bootloader.backend = "u-boot-rockchip";

  users.users.root = {
    password = "$6$cqZKvfwHmoQwVp28$61S9QwBIB3Q5c8mUJt6sZW2cejQIta86KxSeFhDDd1CukI45/Nq0VL7GMVVsqOh9sHySkok2K4M3XpY1i404b/";
  };

  finit.ttys.ttyFIQ0 = {
    runlevels = "2345";
    nowait = true;
  };

  services.mdevd.enable = true;
  services.sysklogd.enable = true;

  hardware.firmware = [ m0-firmware ];
}
