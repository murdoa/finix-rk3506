# Closure-reduction overlays for embedded ARMv7 target.
{ lib }:

[
  (import ./allow-missing-modules.nix)
  (import ./strip-security-wrapper-headers.nix { inherit lib; })
  (import ./util-linux-minimal.nix)
]
