# Redirect packages that drag in full util-linux to use util-linuxMinimal.
# Full util-linux pulls sqlite (4.9M via lastlog2), systemd-minimal-libs
# (3.6M via libudev), coreutils (1.7M via lastlog2 unit), and has a
# 12.8M lib vs minimal's 1.9M.
#
# Can't overlay util-linux globally due to cross-compilation splicing
# infinite recursion (util-linuxMinimal = util-linux.override{...}).
# Instead we surgically patch the specific consumers.
final: prev: let
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
}
