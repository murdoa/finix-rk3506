# Bare-metal Cortex-M0 firmware for RK3506 — ELF + raw binary.
#
# Produces both .elf (for remoteproc loading) and .bin (legacy).
# The ELF is installed as /lib/firmware/rk3506-m0.elf for the
# rk3506_rproc kernel module to load via remoteproc framework.
{
  lib,
  stdenvNoCC,
  gcc-arm-embedded,
}:

stdenvNoCC.mkDerivation {
  pname = "rk3506-m0-firmware-bin";
  version = "0.2.0";

  src = ../m0-firmware;

  nativeBuildInputs = [ gcc-arm-embedded ];

  dontConfigure = true;

  CROSS = "arm-none-eabi-";
  CPU_FLAGS = "-mcpu=cortex-m0 -mthumb";

  buildPhase = ''
    runHook preBuild

    CC="''${CROSS}gcc"
    OBJCOPY="''${CROSS}objcopy"
    SIZE="''${CROSS}size"

    CFLAGS="$CPU_FLAGS -Os -std=c99 -Wall -Wextra -Werror -g"
    CFLAGS="$CFLAGS -ffreestanding -ffunction-sections -fdata-sections"

    LDFLAGS="$CPU_FLAGS --specs=nosys.specs -nostartfiles"
    LDFLAGS="$LDFLAGS -Wl,--gc-sections -Wl,-T,linker.ld"
    LDFLAGS="$LDFLAGS -Wl,-Map=rk3506-m0.map"

    echo "CC  startup.S"
    $CC $CFLAGS -c startup.S -o startup.o

    echo "CC  main.c"
    $CC $CFLAGS -c main.c -o main.o

    echo "LD  rk3506-m0.elf"
    $CC $LDFLAGS startup.o main.o -o rk3506-m0.elf -lc -lm -lgcc

    echo "BIN rk3506-m0.bin"
    $OBJCOPY -O binary rk3506-m0.elf rk3506-m0.bin

    echo ""
    $SIZE rk3506-m0.elf

    runHook postBuild
  '';

  outputs = [ "out" "debug" ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/firmware
    cp rk3506-m0.elf $out/lib/firmware/
    cp rk3506-m0.bin $out/lib/firmware/

    mkdir -p $debug/share/m0-firmware
    cp rk3506-m0.elf $debug/share/m0-firmware/
    cp rk3506-m0.bin $debug/share/m0-firmware/
    cp rk3506-m0.map $debug/share/m0-firmware/

    runHook postInstall
  '';

  meta = with lib; {
    description = "Bare-metal Cortex-M0 firmware for RK3506 — ELF for remoteproc";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
