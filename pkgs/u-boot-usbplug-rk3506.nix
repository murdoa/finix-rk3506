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

    # BootROM loads CODE472 (usbplug) at 0x00000000, not 0x00200000.
    # Other SoCs (rv1126, rk3528) do the same — see rv1126_common.h.
    sed -i 's|#define CONFIG_SYS_TEXT_BASE.*0x00200000|#ifdef CONFIG_SUPPORT_USBPLUG\n#define CONFIG_SYS_TEXT_BASE\t\t0x00000000\n#else\n#define CONFIG_SYS_TEXT_BASE\t\t0x00200000\n#endif|' \
      include/configs/rk3506_common.h

    # Remove the 32 MiB read limit — return actual flash data for readback
    sed -i 's|if ((blkstart + blkcnt) > RKUSB_READ_LIMIT_ADDR) {|if (0) {|' \
      cmd/rockusb.c

    # Force f_mass_storage.o to be compiled. CONFIG_USB_FUNCTION_MASS_STORAGE
    # is a plain C #define in rk3506_common.h, not a Kconfig symbol, so Make
    # can't see it. Just hardcode it in the Makefile.
    sed -i 's|obj-$(CONFIG_USB_FUNCTION_MASS_STORAGE) += f_mass_storage.o|obj-$(CONFIG_USB_GADGET_DOWNLOAD) += f_mass_storage.o|' \
      drivers/usb/gadget/Makefile

    # Debug: trace g_dnl_do_config linker list iteration
    sed -i 's|for (; callback != g_dnl_bind_callback_end(); callback++)|printf("g_dnl_do_config: s=%p start=%p end=%p\\n", s, callback, g_dnl_bind_callback_end()); for (; callback != g_dnl_bind_callback_end(); callback++)|' \
      drivers/usb/gadget/g_dnl.c

    # Disable Rockchip flash-based BBT for usbplug.
    # MTD_SPI_NAND force-selects MTD_NAND_BBT_USING_FLASH via Kconfig,
    # so we must patch both the Kconfig select and the runtime flag.
    sed -i '/select MTD_NAND_BBT_USING_FLASH/d' drivers/mtd/nand/spi/Kconfig
    sed -i 's|nand->bbt.option = NANDDEV_BBT_USE_FLASH;|nand->bbt.option = 0;|' \
      drivers/mtd/nand/spi/core.c

    # Skip bad block scanning in mtd_blk_probe — just expose the full flash.
    # The usbplug runs from RAM and writes raw images; it doesn't need BBT.
    # Replace the NAND if-branch with the simple lba = size >> 9 assignment.
    sed -i 's|if (mtd->type == MTD_NANDFLASH) {|if (0) {|' \
      drivers/mtd/mtd_blk.c
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
    cp .config $out/bin/dot-config
    cp u-boot $out/bin/u-boot.elf 2>/dev/null || true

    runHook postInstall
  '';

  meta = {
    description = "Open-source USB plug firmware for RK3506 SPI NAND flashing";
    homepage = "https://github.com/rockchip-linux/u-boot";
    license = lib.licenses.gpl2Only;
    platforms = [ "armv7l-linux" ];
  };
}
