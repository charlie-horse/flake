{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    mkMerge
    ;
  inherit (lib.generators)
    toGitINI
    ;
  # sops secrets from modules/system/yubikey.nix.
  inherit (config.sops)
    secrets
    ;
  inherit (config.custom)
    yubikey
    ;

  systemConfig = {
    url."git@github.com:".insteadOf = [
      "https://github.com/"
      "gh:"
    ];
    url."https://github.com/rust-lang/crates.io-index".insteadOf = [
      "https://github.com/rust-lang/crates.io-index"
    ];
    gpg.format = "ssh";
    tag.gpgSign = true;
    commit.gpgSign = true;
    pull.rebase = true;
    push.autoSetupRemote = true;
    fetch.prune = true;
    init.defaultBranch = "main";
    status.short = true;
  };
  userConfig = {
    user = {
      name = "Charlie Syvertsen";
      email = "charliesyvertsen06@icloud.com";
    }
    # Sign with the YubiKey 5's ed25519-sk key (gpg.format = ssh above).
    // lib.optionalAttrs yubikey.enable {
      signingkey = secrets.ssh-yubikey-5.path;
    };
  };
in
mkMerge [
  {
    programs.git = {
      enable = true;
      package = pkgs.gitFull;
      config = systemConfig;
    };
  }
  { custom.user.configFile."git/config".text = toGitINI userConfig; }
]
