# System configuration for Luckfox Lyra (RK3506G2).
#
# Hardware-specific boot/filesystem config lives in profiles/.
# This file is the "what the system does" — services, users, firmware.
{ pkgs, finixModules, board, ... }:
{
  imports = [ finixModules.sysklogd ];

  networking.hostName = "finix-rk3506";

  # Cortex-M0 remoteproc
  boot.extraModulePackages = [ board.m0-kmod ];
  boot.kernelModules = [ "rk3506_rproc" ];
  hardware.firmware = [ board.m0-firmware ];

  users.users.root = {
    password = "$6$cqZKvfwHmoQwVp28$61S9QwBIB3Q5c8mUJt6sZW2cejQIta86KxSeFhDDd1CukI45/Nq0VL7GMVVsqOh9sHySkok2K4M3XpY1i404b/";
  };

  finit.ttys.ttyFIQ0 = {
    runlevels = "2345";
    nowait = true;
  };

  services.mdevd.enable = true;
  services.sysklogd.enable = true;
}
