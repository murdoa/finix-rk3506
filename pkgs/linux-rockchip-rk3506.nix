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

(buildLinux {
  version = "6.1.118-rockchip";
  modDirVersion = "6.1.118";

  # Do NOT let nixpkgs' buildLinux force-enable every tristate as =m
  # or apply common-config.nix on top of the vendor defconfig.
  # We want the vendor defconfig as-is.
  autoModules = false;
  preferBuiltin = false;



  src = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "kernel";
    rev = "d2b4477a1df699e6639e83837c7dc45ea1d1d73f";
    hash = "sha256-gAeNeCXqGxvccBhnF8UwYDiMMa+vXgMGLXp8ze0UcEs=";
  };

  defconfig = "rk3506_defconfig";

  # The vendor defconfig already includes the essentials:
  #   CONFIG_DEVTMPFS=y, CONFIG_CGROUPS (implicit), CONFIG_TMPFS=y,
  #   CONFIG_BLK_DEV_INITRD=y, CONFIG_MTD=y, CONFIG_MTD_UBI=y,
  #   CONFIG_SQUASHFS=y, CONFIG_UBIFS_FS=y
  #
  # Add anything finix specifically needs that the vendor missed:
  structuredExtraConfig = with lib.kernel; {
    # Override vendor's LZ4 kernel compression — lz4c isn't in the nix build env.
    # Use gzip instead (always available).
    KERNEL_LZ4 = no;
    KERNEL_GZIP = yes;
    # Ensure cgroups v2 is available (finit uses cgroups)
    CGROUP_PIDS = yes;
    CGROUP_FREEZER = yes;
    MEMCG = yes;

    # Required by mdevd (finix default device manager)
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

    # Disable vendor GPU drivers that don't compile with modern GCC.
    # The RK3506 has no GPU — these are for other Rockchip SoCs and the
    # defconfig enables them because it's a shared config.
    MALI400 = no;
    MALI_MIDGARD = no;
    MALI_BIFROST = no;
    MALI_VALHALL = no;

    # Disable stmmac UIO — vendor hack broken against stmmac struct layout
    STMMAC_UIO = no;

    # Disable camera/media drivers with removed V4L2 APIs
    VIDEO_ROCKCHIP_PREISP = no;  # rk1608_dphy.c
    VIDEO_AR0822 = no;
    VIDEO_AR2020 = no;

    # Disable rockchip secure OTP — uses removed TEE SHM APIs
    NVMEM_ROCKCHIP_SEC_OTP = no;
  };

  # The vendor kernel has some code that doesn't compile with GCC 15.
  # -Werror=implicit-function-declaration and -Werror=incompatible-pointer-types
  # are now default errors in GCC 14+.
  extraMakeFlags = [
    "KCFLAGS=-Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion"
  ];

  extraMeta = {
    # This is a 32-bit ARM kernel
    platforms = [ "armv7l-linux" ];
    description = "Rockchip BSP Linux kernel 6.1 for RK3506";
  };
}).overrideAttrs (old: {
  # Add Luckfox Lyra DTS files (not present in upstream rockchip-linux/kernel).
  # These are from Luckfox's kernel fork, branch luckfox-linux-6.1-rk3506.
  postPatch = (old.postPatch or "") + ''
    cp ${./kernel-dts/rk3506-luckfox-lyra.dtsi} arch/arm/boot/dts/rk3506-luckfox-lyra.dtsi
    cp ${./kernel-dts/rk3506g-luckfox-lyra-sd.dts} arch/arm/boot/dts/rk3506g-luckfox-lyra-sd.dts

    # Register in the DTS Makefile so `make dtbs` builds it
    sed -i '/rk3506g-demo-display-control.dtb/a\\trk3506g-luckfox-lyra-sd.dtb \\' \
      arch/arm/boot/dts/Makefile
  '';
})
