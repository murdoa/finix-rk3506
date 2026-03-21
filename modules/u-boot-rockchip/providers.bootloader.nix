# providers.bootloader implementation for Rockchip U-Boot.
#
# Wires the u-boot-rockchip module into finix's bootloader provider contract.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.u-boot-rockchip;

  installHook = pkgs.writeShellScript "u-boot-rockchip-install-hook" ''
    set -euo pipefail

    systemConfig="$1"
    bootMount="${cfg.bootMountPoint}"

    mkdir -p "$bootMount/extlinux"

    cat > "$bootMount/extlinux/extlinux.conf" << EXTLINUX
    DEFAULT finix
    TIMEOUT 30
    PROMPT 0

    LABEL finix
      MENU LABEL finix
      LINUX $systemConfig/kernel
      INITRD $systemConfig/initrd
      FDT ${cfg.dtbPath}
      APPEND init=$systemConfig/init ${toString config.boot.kernelParams}
    EXTLINUX

    echo "extlinux.conf updated for $systemConfig"
  '';
in
{
  options.providers.bootloader = {
    backend = lib.mkOption {
      type = lib.types.enum [ "u-boot-rockchip" ];
    };
  };

  config = lib.mkIf (config.providers.bootloader.backend == "u-boot-rockchip") {
    providers.bootloader.installHook = installHook;
  };
}
