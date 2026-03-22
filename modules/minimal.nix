# Closure size reductions for embedded use.
# Import this module to strip desktop/workstation bloat from the image.
#
# Cumulative savings vs default finix configuration:
#   - xdg.mime (shared-mime-info + glib chain):  ~22.5 MiB
#   - xdg.portal (desktop-portal + deps):        avoided
#   - perl → bash setup-etc rewrite:             ~51 MiB  (etc-setup-bash.nix)
#   - security-wrapper linuxHeaders leak:        ~16.6 MiB  (overlay in flake.nix)
#   - u-boot removed from system-path:           ~30 MiB  (x86 glibc chain)
#   - strip default system packages:             ~25 MiB  (curl, gawk, tar, etc.)
#   - DTBs → single board only:                  ~20 MiB  (kernel postInstall)
#   - System.map removal:                        ~2.7 MiB (kernel postInstall)
#   - locale stripping:                          ~2.9 MiB
{ pkgs, lib, ... }:

{
  imports = [ ./etc-setup-bash.nix ];

  # shared-mime-info (7.5 MiB) + glib dependency chain (~15 MiB).
  xdg.mime.enable = false;

  # xdg-desktop-portal: D-Bus interfaces for sandboxed desktop apps.
  xdg.portal.enable = false;

  # Override finix's fat default systemPackages. The upstream default pulls in
  # curl (+ openssl + krb5 + nghttp chain), gawk, gnutar, cpio, diffutils,
  # gnupatch, coreutils-full (dupe of coreutils), etc.
  #
  # Stripped to bare minimum for an offline serial-only embedded system.
  environment.systemPackages = lib.mkForce (with pkgs; [
    # Shell essentials
    bashInteractive
    coreutils
    findutils
    gnugrep
    gnused
    less
    which

    # System
    util-linux
    procps
    ncurses       # terminfo
    getent
    getconf
    gzip
    zstd
    su
    mkpasswd

    # Board-specific
    mtdutils
  ]);

  # Strip locales to just C/POSIX + UTF-8. Default ships full locale archive.
  i18n.supportedLocales = [ "C.UTF-8/UTF-8" ];

  # Finix default pathsToLink includes emacs, hunspell, themes, vulkan, etc.
  # Strip to what actually matters.
  environment.pathsToLink = lib.mkForce [
    "/bin"
    "/sbin"
    "/lib"
    "/share/terminfo"
  ];

  # No VGA/HDMI console — serial only. Kills kbd (2.5 MiB) and VESA blanking.
  hardware.console.enable = false;

  # The shadow module hardcodes pam_xauth in su's PAM config, pulling in
  # xauth → libX11 → libxcb (~4.2 MiB of X11 on a headless board).
  # Override with the same config minus the xauth line.
  security.pam.services.su.text = lib.mkForce ''
    # Account management.
    account required pam_unix.so # unix (order 10900)

    # Authentication management.
    auth sufficient pam_rootok.so # rootok (order 10200)
    auth required pam_faillock.so # faillock (order 10400)
    auth sufficient pam_unix.so likeauth try_first_pass # unix (order 11500)
    auth required pam_deny.so # deny (order 12300)

    # Password management.
    password sufficient pam_unix.so nullok yescrypt # unix (order 10200)

    # Session management.
    session required pam_env.so conffile=/etc/security/pam_env.conf readenv=0 # env (order 10100)
    session required pam_unix.so # unix (order 10200)
  '';
}
