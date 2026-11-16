# r440's Nix binary cache (harmonia) as a substituter: https://cache.neuros.is
# with HTTP basic auth, the same URL on every host and in CI. Imported by
# modules/server/default.nix and, for desktops, with modules/ wholesale.
# Server side: hosts/r440/cache.nix.
#
# Credential: a netrc line (`machine cache.neuros.is login <user> password
# <pw>`), sops key `nix-cache-netrc` in secrets/<hostname>.yaml ->
# /run/secrets/nix-cache-netrc; never in git, the store or a command line.
#
# A down cache or missing netrc must not break anything: cache.nixos.org
# (40) stays first, connect-timeout keeps an unreachable cache cheap, and
# fallback makes Nix skip a failing cache for 60 s and build what it can't
# fetch. Design, clients and setup: docs/build-cache.md#binary-cache.
{
  config,
  lib,
  inputs,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mkDefault
    types
    ;
  cfg = config.custom.nixCache;

  # Pure data, also read by hosts/r440/cache.nix and k8s/. Through
  # inputs.self, not a relative path: mkHost imports modules/ from its own
  # store copy, which has no ../cluster.
  cache = (import "${inputs.self}/cluster/definition.nix").binaryCache;
in
{
  options.custom.nixCache = {
    enable = mkEnableOption "r440's binary cache (https://${cache.host}) as a substituter";

    priority = mkOption {
      type = types.int;
      default = 50;
      description = ''
        Substituter priority (lower first). cache.nixos.org is 40: it is a
        CDN, while this cache comes through r440's uplink.
      '';
    };

    netrcFile = mkOption {
      type = types.str;
      default = config.sops.secrets.nix-cache-netrc.path;
      defaultText = lib.literalExpression "config.sops.secrets.nix-cache-netrc.path";
      description = ''
        Runtime path of the netrc file with the basic-auth credential (read
        by the nix-daemon as root; mode 0400/0600). A string, so the file is
        never copied into the store. If it is missing, every query gets 401
        and Nix uses cache.nixos.org alone.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !lib.hasPrefix builtins.storeDir cfg.netrcFile;
        message = "custom.nixCache.netrcFile must not be a Nix store path (it holds a password).";
      }
    ];
    # Key `nix-cache-netrc` of the host's sops file (sops.defaultSopsFile).
    # No restartUnits: Nix reads netrc-file on every download, so a new
    # value applies without restarting nix-daemon.
    sops.secrets.nix-cache-netrc = {
      owner = "root";
      group = "root";
      mode = "0600";
    };
    nix.settings = {
      substituters = [ "https://${cache.host}?priority=${toString cfg.priority}" ];
      trusted-public-keys = [ cache.publicKey ];
      netrc-file = cfg.netrcFile;
      connect-timeout = mkDefault 5;
      fallback = mkDefault true;
    };
  };
}
