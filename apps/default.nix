{ pkgs, sdImage }:

let
  # Hardcode YOUR card reader here. Find it with:
  #   ls -la /dev/disk/by-id/ | grep usb
  sdCardById = "/dev/disk/by-id/usb-Generic_STORAGE_DEVICE_000000000819-0:0";

  mkApp = name: script: {
    type = "app";
    program = toString (pkgs.writeShellScript name script);
  };
in
{
  flash = import ./flash.nix { inherit pkgs mkApp sdCardById sdImage; };
}
