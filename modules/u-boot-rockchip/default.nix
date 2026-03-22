# U-Boot bootloader module for Rockchip SoCs.
#
# Implements the `providers.bootloader` contract for finix using U-Boot with
# extlinux.conf (generic distro boot). This is the standard boot method for
# ARM boards running U-Boot.
#
# The Rockchip boot chain:
#   BootROM → idbloader.img (DDR + SPL) → u-boot.itb → extlinux.conf → kernel + DTB + initrd
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.u-boot-rockchip;

  # Script to install/update the bootloader and boot config on the target media
  installScript = pkgs.writeShellScript "u-boot-rockchip-install" ''
    set -euo pipefail

    systemConfig="$1"

    BOOT_MOUNT="${cfg.bootMountPoint}"

    echo "Installing finix boot configuration..."

    # Ensure boot mount exists
    mkdir -p "$BOOT_MOUNT/extlinux"

    # Write extlinux.conf
    cat > "$BOOT_MOUNT/extlinux/extlinux.conf" << EOF
    DEFAULT finix
    TIMEOUT 30
    PROMPT 0

    LABEL finix
      MENU LABEL finix
      LINUX $systemConfig/kernel
      INITRD $systemConfig/initrd
      FDT ${cfg.dtbPath}
      APPEND init=$systemConfig/init ${toString config.boot.kernelParams}
    EOF

    echo "Boot configuration updated."

    ${lib.optionalString cfg.installBootImages ''
      echo "Installing boot images to ${cfg.bootDevice}..."

      # Write idbloader.img at sector 64 (standard Rockchip SD card layout)
      dd if=${cfg.package}/bin/idbloader.img of=${cfg.bootDevice} seek=64 conv=notrunc 2>/dev/null

      # Write u-boot.itb at sector 16384 (8MB offset)
      if [ -f ${cfg.package}/bin/u-boot.itb ]; then
        dd if=${cfg.package}/bin/u-boot.itb of=${cfg.bootDevice} seek=16384 conv=notrunc 2>/dev/null
      fi

      echo "Boot images installed."
    ''}
  '';
in
{
  imports = [
    ./providers.bootloader.nix
  ];

  options.programs.u-boot-rockchip = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable U-Boot as the bootloader for Rockchip hardware.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The U-Boot package for your specific Rockchip SoC. Must provide
        `idbloader.img` and `u-boot.itb` in `$out/bin/`.
      '';
    };

    dtbPath = lib.mkOption {
      type = lib.types.str;
      example = "/boot/dtb/rk3506g-myboard.dtb";
      description = ''
        Path to the device tree blob, as U-Boot will resolve it. This can be:
        - An absolute path on the root filesystem (e.g., from the kernel's DTB output)
        - A path relative to the boot partition
      '';
    };

    bootMountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/boot";
      description = ''
        Where the boot partition is mounted.
      '';
    };

    bootDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/mmcblk0";
      example = "/dev/mmcblk0";
      description = ''
        The block device for writing raw boot images (idbloader, u-boot.itb).
        This is typically the SD card or eMMC device, NOT a partition.
      '';
    };

    installBootImages = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to write raw boot images (idbloader.img, u-boot.itb) to the
        boot device during switch-to-configuration. This is destructive and
        typically only needed on first install or U-Boot upgrades.

        When false, only the extlinux.conf is updated.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # U-Boot binaries are referenced directly by the install script via
    # cfg.package — no need to put them in systemPackages. Doing so leaks
    # the entire cross-toolchain closure (including build-host glibc) into
    # the target image.

    # NOTE: extlinux.conf is NOT placed in /etc — it lives on the boot
    # partition and is written by the install hook at switch-to-configuration
    # time. This avoids infinite recursion (extlinux.conf references
    # system.topLevel which depends on environment.etc).
  };
}
