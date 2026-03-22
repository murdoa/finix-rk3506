# SD card boot profile for Luckfox Lyra.
#
# GPT: part1=uboot (raw), part2=boot (FAT32), part3=rootfs (ext4)
{ ... }:
{
  imports = [ ./base.nix ];

  boot.initrd.kernelModules = [ "mmc_block" "ext4" ];

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
    dtbPath = "/dtb/rk3506g-luckfox-lyra-sd.dtb";
    bootDevice = "/dev/mmcblk0";
  };
}
