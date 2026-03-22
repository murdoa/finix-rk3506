# Pre-built Cortex-M0 blinky firmware for RK3506.
#
# Installs the blinkled.elf from test-elfs/ as /lib/firmware/rk3506-m0.elf
# for the rk3506_rproc kernel module to load via remoteproc framework.
{
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "rk3506-m0-firmware-bin";
  version = "0.3.0";

  src = ../m0-firmware/test-elfs;

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out/lib/firmware
    cp $src/blinkled.elf $out/lib/firmware/rk3506-m0.elf
  '';

  meta = with lib; {
    description = "Pre-built blinky Cortex-M0 firmware for RK3506 — ELF for remoteproc";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
