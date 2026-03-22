# UBIFS filesystem support module for finix.
#
# Provides the boot.supportedFilesystems.ubifs and
# boot.initrd.supportedFilesystems.ubifs options that finix expects
# when fileSystems."/" uses fsType = "ubifs".
#
# On the RK3506 vendor kernel, all UBI/UBIFS/MTD drivers are built-in (=y),
# so no kernel modules need to be loaded. mtd-utils provides userspace tools.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  options = {
    boot.initrd.supportedFilesystems.ubifs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to enable UBIFS support in the initial ramdisk.";
      };

      packages = lib.mkOption {
        type = with lib.types; listOf package;
        default = [ ];
        description = "Packages providing UBIFS utilities for the initrd.";
      };
    };

    boot.supportedFilesystems.ubifs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to enable UBIFS filesystem support.";
      };

      packages = lib.mkOption {
        type = with lib.types; listOf package;
        default = [ ];
        description = "Packages providing UBIFS filesystem utilities.";
      };
    };
  };

  config = lib.mkIf config.boot.supportedFilesystems.ubifs.enable {
    # UBI/UBIFS/MTD are built-in on the vendor kernel, but add the module
    # names anyway for kernels where they might be modules.
    boot.initrd.availableKernelModules =
      lib.mkIf config.boot.initrd.supportedFilesystems.ubifs.enable [
        "ubi"
        "ubifs"
      ];

    # mtd-utils provides ubiattach, ubinfo, etc.
    boot.supportedFilesystems.ubifs.packages = [ pkgs.mtdutils ];
  };
}
