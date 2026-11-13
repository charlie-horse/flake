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
  # The ssh:admin FIDO2 key (admin's sk- authorized key,
  # modules/system/admin.nix): git signs through the ssh agent with it.
  signingKey =
    lib.findFirst (lib.hasPrefix "sk-") null
      config.users.users.admin.openssh.authorizedKeys.keys;

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
    # Sign with the ssh:admin key from the agent (gpg.format = ssh above;
    # `key::` = a literal public key, no key file needed).
    // lib.optionalAttrs (signingKey != null) {
      signingkey = "key::${signingKey}";
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
