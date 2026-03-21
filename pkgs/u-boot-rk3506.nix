# Rockchip vendor U-Boot for RK3506 (Luckfox Lyra).
#
# This builds U-Boot from the rockchip-linux/u-boot next-dev branch using
# Luckfox's defconfig and DTS files, then packs it into the FIT image that
# SPL expects:
#
#   - idbloader.img  (DDR init + SPL — written to raw sectors 64+ on SD card)
#   - u-boot.itb     (FIT: U-Boot + OP-TEE + DTB — partition 1 at sector 8192)
#
# Boot chain:
#   BootROM → idbloader.img → u-boot.itb → distro_bootcmd → extlinux.conf → kernel
{
  lib,
  stdenv,
  fetchFromGitHub,
  bison,
  flex,
  bc,
  dtc,
  openssl,
  swig,
  python3,
  ubootTools,
  rkbin,
  buildPackages,
}:

stdenv.mkDerivation {
  pname = "u-boot-rk3506";
  version = "unstable-2025-03-21";

  src = fetchFromGitHub {
    owner = "rockchip-linux";
    repo = "u-boot";
    rev = "b14196eade471bbc000c368f8555f2a2a1ecc17d";
    hash = "sha256-+poK56Y+AxZuXoEggbLUezzIIoZMpFZ7FtVmN7/XaQI=";
  };

  depsBuildBuild = [ buildPackages.stdenv.cc ];

  nativeBuildInputs = [
    bison
    flex
    bc
    dtc
    openssl
    swig
    python3
    ubootTools
  ];

  # Tell the Rockchip build scripts where to find rkbin blobs
  RKBIN = "${rkbin}";

  postPatch = ''
    patchShebangs scripts/ tools/ arch/arm/mach-rockchip/

    # --- Add Luckfox DTS files (not in upstream) ---
    cp ${./u-boot-dts/rk3506-luckfox.dts}  arch/arm/dts/rk3506-luckfox.dts
    cp ${./u-boot-dts/rk3506-luckfox.dtsi} arch/arm/dts/rk3506-luckfox.dtsi

    # --- Add Luckfox defconfig ---
    cp ${./u-boot-dts/rk3506_luckfox_defconfig} configs/rk3506_luckfox_defconfig
  '';

  configurePhase = ''
    runHook preConfigure

    make rk3506_luckfox_defconfig CROSS_COMPILE=${stdenv.cc.targetPrefix}

    # --- Override BOOTCOMMAND for extlinux distro boot ---
    # The Luckfox defconfig defaults to boot_fit/boot_android.
    # We want U-Boot to run distro_bootcmd which scans for extlinux.conf.
    echo 'CONFIG_BOOTCOMMAND="run distro_bootcmd"' >> .config

    # Regenerate the full config with our override applied
    make olddefconfig CROSS_COMPILE=${stdenv.cc.targetPrefix}

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Suppress vendor code warnings that are errors with GCC 15
    make \
      CROSS_COMPILE=${stdenv.cc.targetPrefix} \
      KCFLAGS="-Wno-error=maybe-uninitialized -Wno-error=enum-int-mismatch -Wno-error=incompatible-pointer-types -Wno-error=int-conversion" \
      -j$NIX_BUILD_CORES

    # --- Generate idbloader.img (DDR init + SPL) ---
    # BootROM loads this from sector 64 on SD card
    tools/mkimage -n rk3506 -T rksd \
      -d ${rkbin}/bin/rk3506_ddr_750MHz_v1.06.bin:spl/u-boot-spl.bin \
      idbloader.img

    # --- Generate u-boot.itb (FIT: U-Boot + OP-TEE) ---
    # Copy TEE binary where the FIT generator expects it
    cp ${rkbin}/bin/rk3506_tee_v2.10.bin tee.bin

    # The FIT generator reads autoconf.mk for load addresses:
    #   UBOOT_LOAD_ADDR = CONFIG_SYS_TEXT_BASE = 0x200000
    #   TEE_LOAD_ADDR   = CONFIG_SYS_SDRAM_BASE + TEE_OFFSET = 0 + 0x1000 = 0x1000
    # -t 0x1000 sets TEE_OFFSET (SDRAM_BASE is 0 on RK3506)
    bash arch/arm/mach-rockchip/make_fit_optee.sh -t 0x1000 > u-boot.its

    # Pack FIT image with external data (matches vendor build)
    tools/mkimage -f u-boot.its -E u-boot.itb

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin

    # Core boot images
    cp idbloader.img $out/bin/
    cp u-boot.itb    $out/bin/

    # Also keep these for debugging/reference
    cp u-boot.bin    $out/bin/ 2>/dev/null || true
    cp u-boot.its    $out/bin/ 2>/dev/null || true
    cp spl/u-boot-spl.bin $out/bin/ 2>/dev/null || true

    # Device trees
    mkdir -p $out/dtb
    cp arch/arm/dts/rk3506*.dtb $out/dtb/ 2>/dev/null || true

    # mkimage tool for boot script generation
    mkdir -p $out/tools
    cp tools/mkimage $out/tools/ 2>/dev/null || true

    runHook postInstall
  '';

  meta = {
    description = "Rockchip vendor U-Boot for RK3506 (Luckfox Lyra, distro boot)";
    homepage = "https://github.com/rockchip-linux/u-boot";
    license = lib.licenses.gpl2Only;
    platforms = [ "armv7l-linux" ];
  };
}
