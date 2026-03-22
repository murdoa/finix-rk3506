# Security wrappers (built with pkgsStatic/musl) propagate linuxHeaders
# into their runtime closure via propagated-build-inputs. They're
# statically linked — they don't need headers at runtime.
# Saves ~16.6 MiB. Upstream should fix wrapper.nix to use
# nativeBuildInputs for linuxHeaders.
{ lib }:

final: prev: {
  pkgsStatic = prev.pkgsStatic.extend (sfinal: sprev: let
    origCallPackage = sprev.callPackage;
  in {
    callPackage = fn: args: let
      result = origCallPackage fn args;
      name = result.name or "";
    in
      if lib.hasPrefix "security-wrapper-" name then
        result.overrideAttrs (old: {
          postFixup = (old.postFixup or "") + ''
            rm -f $out/nix-support/propagated-build-inputs
          '';
        })
      else
        result;
  });
}
