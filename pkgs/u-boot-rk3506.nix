# Rockchip vendor U-Boot for RK3506 (Luckfox Lyra).
#
# Produces idbloader.img (DDR + SPL) and u-boot.itb (FIT: U-Boot + OP-TEE + DTB).
# Boot chain: BootROM → idbloader.img → u-boot.itb → distro_bootcmd → extlinux.conf
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
    bison flex bc dtc openssl swig python3 ubootTools
  ];

  RKBIN = "${rkbin}";

  postPatch = ''
    patchShebangs scripts/ tools/ arch/arm/mach-rockchip/

    cp ${./u-boot-dts/rk3506-luckfox.dts}  arch/arm/dts/rk3506-luckfox.dts
    cp ${./u-boot-dts/rk3506-luckfox.dtsi} arch/arm/dts/rk3506-luckfox.dtsi
    cp ${./u-boot-dts/rk3506_luckfox_defconfig} configs/rk3506_luckfox_defconfig

    # evb_rk3506.h #undefs CONFIG_BOOTCOMMAND and hardcodes it to
    # RKIMG_BOOTCOMMAND (boot_fit → boot_android — never runs extlinux).
    sed -i 's|#define CONFIG_BOOTCOMMAND RKIMG_BOOTCOMMAND|#define CONFIG_BOOTCOMMAND "run distro_bootcmd"|' \
      include/configs/evb_rk3506.h

    # rk3506_common.h defines CONFIG_EXTRA_ENV_SETTINGS but omits
    # BOOTENV_SHARED_MTD (the "mtd_boot=" script). Without it, distro
    # boot's bootcmd_mtd* targets try to "run mtd_boot" and fail with
    # "mtd_boot not defined". rk3588_common.h gets this right — we
    # replicate that fix here by prepending BOOTENV_SHARED_MTD.
    sed -i 's|#define CONFIG_EXTRA_ENV_SETTINGS \\|#define CONFIG_EXTRA_ENV_SETTINGS \\\n\tBOOTENV_SHARED_MTD \\|' \
      include/configs/rk3506_common.h
  '';

  configurePhase = ''
    runHook preConfigure
    make rk3506_luckfox_defconfig CROSS_COMPILE=${stdenv.cc.targetPrefix}
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    make \
      CROSS_COMPILE=${stdenv.cc.targetPrefix} \
      KCFLAGS="-Wno-error=maybe-uninitialized -Wno-error=enum-int-mismatch -Wno-error=incompatible-pointer-types -Wno-error=int-conversion" \
      -j$NIX_BUILD_CORES

    # idbloader.img: BootROM loads from sector 64 (SD/eMMC)
    tools/mkimage -n rk3506 -T rksd \
      -d ${rkbin}/bin/rk3506_ddr_750MHz_v1.06.bin:spl/u-boot-spl.bin \
      idbloader.img

    # idblock.img: NAND/SPI boot format via boot_merger with our U-Boot SPL.
    # Replicates what Luckfox SDK's scripts/spl.sh does.
    #
    # boot_merger writes temp files next to its own binary (!), so we must
    # copy the tool into a writable tree alongside the blobs and ini.
    mkdir -p _merger/bin/rk35 _merger/tools
    cp ${rkbin}/bin/rk3506_ddr_750MHz_v1.06.bin _merger/bin/rk35/
    cp ${rkbin}/bin/rk3506_usbplug_v1.03.bin    _merger/bin/rk35/
    cp spl/u-boot-spl.bin                        _merger/bin/rk35/rk3506_spl_v1.11.bin
    cp ${rkbin}/bin/RK3506MINIALL.ini            _merger/MINIALL.ini
    cp ${rkbin}/tools/boot_merger                _merger/tools/boot_merger
    chmod +x _merger/tools/boot_merger
    pushd _merger
    tools/boot_merger MINIALL.ini
    popd
    cp _merger/rk3506_spl_loader_v*.bin .
    cp _merger/rk3506_idblock_v*.img .
    rm -rf _merger

    # u-boot.itb: FIT containing U-Boot + OP-TEE
    cp ${rkbin}/bin/rk3506_tee_v2.10.bin tee.bin
    bash arch/arm/mach-rockchip/make_fit_optee.sh -t 0x1000 > u-boot.its
    tools/mkimage -f u-boot.its -E u-boot.itb

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp idbloader.img u-boot.itb $out/bin/
    cp rk3506_spl_loader_v*.bin $out/bin/download.bin
    cp rk3506_idblock_v*.img $out/bin/idblock.img
    cp u-boot.bin u-boot.its spl/u-boot-spl.bin $out/bin/ 2>/dev/null || true

    mkdir -p $out/dtb
    cp arch/arm/dts/rk3506*.dtb $out/dtb/ 2>/dev/null || true

    mkdir -p $out/tools
    cp tools/mkimage $out/tools/ 2>/dev/null || true

    runHook postInstall
  '';

  meta = {
    description = "Rockchip vendor U-Boot for RK3506 (Luckfox Lyra)";
    homepage = "https://github.com/rockchip-linux/u-boot";
    license = lib.licenses.gpl2Only;
    platforms = [ "armv7l-linux" ];
  };
}
