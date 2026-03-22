# SPI NAND boot profile for Luckfox Lyra.
#
# Boot flow: BootROM → idbloader → U-Boot → extlinux (mtd_blk) → kernel → UBI/UBIFS
#
# Flash layout (256 MiB SPI NAND, Winbond W25N02KV):
#   mtd0: env        (0x000000  - 0x040000,   256K)
#   mtd1: idblock    (0x040000  - 0x080000,   256K)
#   mtd2: uboot      (0x080000  - 0x400000,   3.5M)
#   mtd3: boot       (0x400000  - 0x1800000,  20M)
#   mtd4: ubi        (0x1800000 - 0x10000000, 232M) — UBIFS rootfs (LZO)
{ ... }:
{
  imports = [
    ./base.nix
    ../modules/filesystems/ubifs.nix
  ];

  boot.kernelParams = [
    # Auto-attach UBI to the partition named "ubi".
    # Using name instead of index because U-Boot injects cmdlinepart mtdparts
    # which may produce different numbering than the DTS fixed-partitions.
    "ubi.mtd=ubi"
  ];

  boot.initrd.kernelModules = [ "mmc_block" ];

  # UBIFS rootfs on UBI volume "rootfs"
  fileSystems."/" = {
    device = "ubi0:rootfs";
    fsType = "ubifs";
  };

  # No separate boot partition mount — boot lives on raw mtd_blk, not a
  # Linux-visible filesystem. U-Boot reads it directly via mtd_blk GPT.

  programs.u-boot-rockchip = {
    dtbPath = "/dtb/rk3506g-luckfox-lyra-nand.dtb";
    # For NAND boot, there's no single block device — U-Boot reads from
    # SPI NAND directly. The install hook is a no-op for NAND.
    bootDevice = "/dev/null";
  };
}
