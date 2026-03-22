# Rockchip BSP Linux kernel 6.1 for RK3506.
#
# Vendor kernel from rockchip-linux/kernel (develop-6.1 branch). Required
# because mainline has minimal RK3506 support (clock/pinctrl only, no DTS).
{
  lib,
  fetchFromGitHub,
  buildLinux,
  ...
}:

(buildLinux {
  version = "6.1.118-rockchip";
  modDirVersion = "6.1.118";

  autoModules = false;
  preferBuiltin = false;

  src = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "kernel";
    rev = "d2b4477a1df699e6639e83837c7dc45ea1d1d73f";
    hash = "sha256-gAeNeCXqGxvccBhnF8UwYDiMMa+vXgMGLXp8ze0UcEs=";
  };

  defconfig = "rk3506_defconfig";

  structuredExtraConfig = with lib.kernel; {
    # Use gzip — lz4c isn't in the nix build env
    KERNEL_LZ4 = no;
    KERNEL_GZIP = yes;

    # cgroups v2 (finit uses cgroups)
    CGROUP_PIDS = yes;
    CGROUP_FREEZER = yes;
    MEMCG = yes;

    DEVTMPFS = yes;
    DEVTMPFS_MOUNT = yes;

    # initrd compression — finix defaults to zstd on 5.9+
    RD_ZSTD = yes;

    PACKET = yes;
    UNIX = yes;
    INET = yes;
    IPV6 = yes;

    OVERLAY_FS = module;

    # Remoteproc framework — needed for M0 core driver
    REMOTEPROC = yes;
    REMOTEPROC_CDEV = yes;

    # Disable vendor drivers that don't compile with GCC 14+.
    # RK3506 has no GPU; these are for other SoCs in the shared defconfig.
    MALI400 = no;
    MALI_MIDGARD = no;
    MALI_BIFROST = no;
    MALI_VALHALL = no;

    # Broken vendor hacks
    STMMAC_UIO = no;               # stmmac struct layout mismatch
    VIDEO_ROCKCHIP_PREISP = no;    # removed V4L2 APIs
    VIDEO_AR0822 = no;
    VIDEO_AR2020 = no;
    NVMEM_ROCKCHIP_SEC_OTP = no;   # removed TEE SHM APIs
  };

  extraMakeFlags = [
    "KCFLAGS=-Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion"
  ];

  extraMeta = {
    platforms = [ "armv7l-linux" ];
    description = "Rockchip BSP Linux kernel 6.1 for RK3506";
  };
}).overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    cp ${./kernel-dts/rk3506-luckfox-lyra.dtsi} arch/arm/boot/dts/rk3506-luckfox-lyra.dtsi
    cp ${./kernel-dts/rk3506g-luckfox-lyra-sd.dts} arch/arm/boot/dts/rk3506g-luckfox-lyra-sd.dts

    sed -i '/rk3506g-demo-display-control.dtb/a\\trk3506g-luckfox-lyra-sd.dtb \\' \
      arch/arm/boot/dts/Makefile
  '';
})
