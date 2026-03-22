# Pre-built test firmware ELFs from nvitya's rk3506-mcu project.
# These are known-working on the Luckfox Lyra Plus.
# Use for initial testing before switching to our own firmware.
#
# blinkled.elf — blinks onboard LED
# uart.elf     — blinks LED + writes to UART4 at 1.5 Mbaud
{
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "rk3506-m0-test-firmware";
  version = "0.1.0";

  src = ../m0-firmware/test-elfs;

  dontUnpack = false;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/lib/firmware
    cp $src/blinkled.elf $out/lib/firmware/rk3506-m0.elf
    cp $src/blinkled.elf $out/lib/firmware/blinkled.elf
    cp $src/uart.elf     $out/lib/firmware/uart.elf
  '';

  meta = with lib; {
    description = "Pre-built M0 test firmware from nvitya/rk3506-mcu";
    license = licenses.gpl2Only;
    platforms = platforms.all;
  };
}
