# U-Boot built as USB plug firmware for RK3506 (Luckfox Lyra).
#
# Replaces the proprietary rk3506_usbplug_v1.03.bin which corrupts page 63
# of random erase blocks when writing SPI NAND. This open-source usbplug
# uses U-Boot's MTD stack for correct ECC handling.
#
# Produces download.bin for: rkdeveloptool db result/download.bin
# Then flash normally: rkdeveloptool wl 0 result/nand.img
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
  pname = "u-boot-usbplug-rk3506";
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
    cp ${./u-boot-dts/rk3506_luckfox_usbplug_defconfig} configs/rk3506_luckfox_usbplug_defconfig

    # Remove the 32 MiB read limit — return actual flash data for readback
    sed -i 's|if ((blkstart + blkcnt) > RKUSB_READ_LIMIT_ADDR) {|if (0) {|' \
      cmd/rockusb.c
  '';

  configurePhase = ''
    runHook preConfigure
    make rk3506_luckfox_usbplug_defconfig CROSS_COMPILE=${stdenv.cc.targetPrefix}
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    make \
      CROSS_COMPILE=${stdenv.cc.targetPrefix} \
      KCFLAGS="-Wno-error=maybe-uninitialized -Wno-error=enum-int-mismatch -Wno-error=incompatible-pointer-types -Wno-error=int-conversion" \
      -j$NIX_BUILD_CORES

    # Pack into MiniLoaderAll format for rkdeveloptool db.
    # Replace the proprietary usbplug blob with our U-Boot usbplug.
    mkdir -p _merger/bin/rk35 _merger/tools
    cp ${rkbin}/bin/rk3506_ddr_750MHz_v1.06.bin _merger/bin/rk35/
    cp usbplug.bin                               _merger/bin/rk35/rk3506_usbplug_v1.03.bin
    # SPL slot is unused in DB mode but boot_merger requires it
    cp usbplug.bin                               _merger/bin/rk35/rk3506_spl_v1.11.bin
    cp ${rkbin}/bin/RK3506MINIALL.ini            _merger/MINIALL.ini
    cp ${rkbin}/tools/boot_merger                _merger/tools/boot_merger
    chmod +x _merger/tools/boot_merger
    pushd _merger
    tools/boot_merger MINIALL.ini
    popd

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp usbplug.bin $out/bin/
    cp u-boot.bin $out/bin/
    cp _merger/rk3506_spl_loader_v*.bin $out/bin/download.bin

    runHook postInstall
  '';

  meta = {
    description = "Open-source USB plug firmware for RK3506 SPI NAND flashing";
    homepage = "https://github.com/rockchip-linux/u-boot";
    license = lib.licenses.gpl2Only;
    platforms = [ "armv7l-linux" ];
  };
}
