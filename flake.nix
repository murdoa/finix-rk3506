{
  description = "finix on Rockchip RK3506G2";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    finix = {
      url = "github:finix-community/finix/0509ea488d45d79f39fd1663d106ab8591a8b06e";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      finix,
    }:
    let
      # Build host
      buildSystem = "x86_64-linux";

      # Target
      targetSystem = "armv7l-linux";

      allowRkbin = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "rkbin-rk3506" ];

      pkgsCross = import nixpkgs {
        localSystem = buildSystem;
        crossSystem = targetSystem;
        config.allowUnfreePredicate = allowRkbin;
        overlays = [
          # Embedded kernels have most drivers built-in, not as loadable modules.
          # The module closure builder doesn't know about builtins and errors out.
          # Same trick as nixos-xlnx/nixos-zedboard — let missing .ko files slide.
          (final: prev: {
            makeModulesClosure = x:
              prev.makeModulesClosure (x // { allowMissing = true; });
          })

          # Fix: security wrappers (built with pkgsStatic/musl) propagate
          # linuxHeaders into their runtime closure via propagated-build-inputs.
          # They're statically linked — they don't need headers at runtime.
          # This saves ~16.6 MiB. Part of the minimal.nix closure reduction effort.
          # Upstream should fix wrapper.nix to use nativeBuildInputs for linuxHeaders.
          (final: prev: {
            pkgsStatic = prev.pkgsStatic.extend (sfinal: sprev: let
              origCallPackage = sprev.callPackage;
              lib = nixpkgs.lib;
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
          })
        ];
      };

      pkgsNative = import nixpkgs {
        system = buildSystem;
        config.allowUnfreePredicate = allowRkbin;
      };

      finixModules = import "${finix}/modules";

      finixSystem =
        { modules ? [ ] }:
        pkgsCross.lib.evalModules {
          specialArgs = {
            # Pass finix module set so configs can import optional modules
            inherit finixModules;
            # Raw finix source path — needed by cross-toplevel.nix to reference
            # files like finit/switch-to-configuration.sh
            finixSrc = finix;
          };
          modules = [
            finixModules.default
            { nixpkgs.pkgs = pkgsCross; }
          ] ++ modules;
        };
    in
    {
      nixosConfigurations.rk3506 = finixSystem {
        modules = [
          ./configuration.nix
          ./modules/minimal.nix
          ./modules/u-boot-rockchip
          ./modules/cross-toplevel.nix
        ];
      };

      packages.${buildSystem} = rec {
        # Cross-compiled packages for the target
        rkbin = pkgsNative.callPackage ./pkgs/rkbin.nix { };
        linux-rockchip-rk3506 = pkgsCross.callPackage ./pkgs/linux-rockchip-rk3506.nix { };
        u-boot-rk3506 = pkgsCross.callPackage ./pkgs/u-boot-rk3506.nix {
          inherit rkbin;
        };

        # Bootable SD card image
        sdImage = pkgsNative.callPackage ./pkgs/sd-image.nix {
          pkgs = pkgsCross;
          inherit pkgsNative;
          lib = pkgsCross.lib;
          systemTopLevel = (finixSystem {
            modules = [
              ./configuration.nix
              ./modules/minimal.nix
              ./modules/u-boot-rockchip
              ./modules/cross-toplevel.nix
            ];
          }).config.system.topLevel;
          inherit u-boot-rk3506;
          kernel = linux-rockchip-rk3506;
        };
      };

      apps.${buildSystem} = import ./apps {
        pkgs = pkgsNative;
        sdImage = self.packages.${buildSystem}.sdImage;
      };
    };
}
