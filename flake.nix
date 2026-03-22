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

      allowRkbin = pkg: (nixpkgs.lib.getName pkg) == "rkbin-rk3506";

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

          # Closure size: redirect packages that drag in full util-linux to use
          # util-linuxMinimal instead. Full util-linux pulls sqlite (4.9M via
          # lastlog2), systemd-minimal-libs (3.6M via libudev), coreutils (1.7M
          # via lastlog2 unit), and has a 12.8M lib vs minimal's 1.9M.
          #
          # Can't overlay util-linux globally due to cross-compilation splicing
          # infinite recursion (util-linuxMinimal = util-linux.override{...}).
          # Instead we surgically patch the specific consumers.
          (final: prev: let
            ulm = final.util-linuxMinimal;
          in {
            # unixtools.fsck wraps full util-linux's fsck binary → symlink
            # into full util-linux-bin closure. Replace with minimal.
            unixtools = prev.unixtools // {
              fsck = prev.runCommand "fsck-util-linux-minimal-${ulm.version}" { } ''
                mkdir -p $out/bin
                ln -s ${ulm}/bin/fsck $out/bin/fsck
              '';
            };

            # mtd-utils: mount.ubifs script hardcodes full util-linux mount path.
            mtdutils = prev.mtdutils.override {
              util-linux = ulm;
            };
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

      nixosConfigurations.rk3506-nand = finixSystem {
        modules = [
          ./configuration-nand.nix
          ./modules/minimal.nix
          ./modules/u-boot-rockchip
          ./modules/cross-toplevel.nix
        ];
      };

      nixosConfigurations.rk3506-nand-flasher = finixSystem {
        modules = [
          ./configuration-nand-flasher.nix
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
        u-boot-usbplug-rk3506 = pkgsCross.callPackage ./pkgs/u-boot-usbplug-rk3506.nix {
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

        # Bootable SPI NAND image (128 MiB, UBIFS rootfs)
        nandImage = pkgsNative.callPackage ./pkgs/nand-image.nix {
          pkgs = pkgsCross;
          inherit pkgsNative;
          lib = pkgsCross.lib;
          systemTopLevel = (finixSystem {
            modules = [
              ./configuration-nand.nix
              ./modules/minimal.nix
              ./modules/u-boot-rockchip
              ./modules/cross-toplevel.nix
            ];
          }).config.system.topLevel;
          inherit u-boot-rk3506;
          kernel = linux-rockchip-rk3506;
        };

        # SD card image that auto-flashes NAND UBI partition on boot
        nandFlasherImage = pkgsNative.callPackage ./pkgs/sd-nand-flasher-image.nix {
          pkgs = pkgsCross;
          inherit pkgsNative;
          lib = pkgsCross.lib;
          systemTopLevel = (finixSystem {
            modules = [
              ./configuration-nand-flasher.nix
              ./modules/minimal.nix
              ./modules/u-boot-rockchip
              ./modules/cross-toplevel.nix
            ];
          }).config.system.topLevel;
          inherit u-boot-rk3506;
          kernel = linux-rockchip-rk3506;
          ubiImage = "${nandImage}/ubi.img";
        };
      };

      apps.${buildSystem} = import ./apps {
        pkgs = pkgsNative;
        sdImage = self.packages.${buildSystem}.sdImage;
        nandImage = self.packages.${buildSystem}.nandImage;
        nandFlasherImage = self.packages.${buildSystem}.nandFlasherImage;
        rkbin = self.packages.${buildSystem}.rkbin;
        usbplug = self.packages.${buildSystem}.u-boot-usbplug-rk3506;
      };
    };
}
