# Rockchip BSP Linux kernel 6.1 with full RK3506 support.
#
# This is the vendor kernel from rockchip-linux/kernel (develop-6.1 branch).
# Mainline Linux has minimal RK3506 support (clock driver only), so the vendor
# kernel is required for initial bring-up.
{
  lib,
  fetchFromGitHub,
  buildLinux,
  ...
}:

buildLinux {
  version = "6.1.99-rockchip";
  modDirVersion = "6.1.99";

  src = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "kernel";
    rev = "d2b4477a1df699e6639e83837c7dc45ea1d1d73f";
    # NOTE: hash needs to be computed on first build — use lib.fakeHash then replace
    hash = lib.fakeHash;
  };

  defconfig = "rk3506_defconfig";

  # The vendor defconfig already includes the essentials:
  #   CONFIG_DEVTMPFS=y, CONFIG_CGROUPS (implicit), CONFIG_TMPFS=y,
  #   CONFIG_BLK_DEV_INITRD=y, CONFIG_MTD=y, CONFIG_MTD_UBI=y,
  #   CONFIG_SQUASHFS=y, CONFIG_UBIFS_FS=y
  #
  # Add anything finix specifically needs that the vendor missed:
  structuredExtraConfig = with lib.kernel; {
    # Ensure cgroups v2 is available (finit uses cgroups)
    CGROUP_PIDS = yes;
    CGROUP_FREEZER = yes;
    MEMCG = yes;

    # Required by mdevd (finix default device manager)
    # (vendor config already has DEVTMPFS, but be explicit)
    DEVTMPFS = yes;
    DEVTMPFS_MOUNT = yes;

    # initrd compression — finix defaults to zstd on 5.9+
    RD_ZSTD = yes;

    # Networking basics
    PACKET = yes;
    UNIX = yes;
    INET = yes;
    IPV6 = yes;

    # For future overlayfs root
    OVERLAY_FS = module;
  };

  extraMeta = {
    # This is a 32-bit ARM kernel
    platforms = [ "armv7l-linux" ];
    description = "Rockchip BSP Linux kernel 6.1 for RK3506";
  };
}
