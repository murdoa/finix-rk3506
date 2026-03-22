# Out-of-tree remoteproc driver for the RK3506 Cortex-M0.
# Based on https://github.com/nvitya/rk3506-mcu
#
# Requires CONFIG_REMOTEPROC=y in the kernel.
{
  lib,
  stdenv,
  kernel,
}:

stdenv.mkDerivation {
  pname = "rk3506-m0-rproc";
  version = "0.2.0";

  src = ../m0-firmware/kmod;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = [
    "KERNELDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "INSTALL_MOD_PATH=$(out)"
  ];

  buildPhase = ''
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
      M=$(pwd) \
      ARCH=arm \
      CROSS_COMPILE=${stdenv.cc.targetPrefix} \
      modules
  '';

  installPhase = ''
    install -D rk3506_rproc.ko \
      $out/lib/modules/${kernel.modDirVersion}/extra/rk3506_rproc.ko
  '';

  meta = with lib; {
    description = "RK3506 Cortex-M0 remoteproc driver";
    license = licenses.gpl2Only;
    platforms = [ "armv7l-linux" ];
  };
}
