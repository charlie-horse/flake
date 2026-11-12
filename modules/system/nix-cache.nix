# r440's Nix binary cache (harmonia) as a substituter, on every machine
# that enables it: https://cache.neuros.is with HTTP basic auth, the same
# URL everywhere (servers, desktops, CI). Shared by the desktops (modules/
# is imported wholesale by mkHost) and the servers (modules/server/
# default.nix imports this file). Server side: hosts/r440/cache.nix.
#
#   https://cache.neuros.is -> Cloudflare -> cloudflared (any node)
#     -> nginx on r440 (basic auth) -> harmonia
#
# The credential is a netrc file (`netrc-file`, read by the nix-daemon as
# root), never in git, the store or a command line:
#   machine cache.neuros.is login <user> password <password>
# Desktops: agenix (Famine: modules/age/secrets.nix). Servers (no agenix):
# a root-only file made by hand, /var/lib/nix-cache/netrc by default
# (docs/cluster.md, "Binary cache").
#
# Read-only: harmonia serves r440's /nix/store; nothing can be pushed.
#
# A down cache or a missing netrc must not break anything:
#   - cache.nixos.org stays in `substituters` (the NixOS default, mkAfter)
#     and comes first (40 < 50), so r440 is asked only for what
#     cache.nixos.org lacks (unfree CUDA builds, our own packages);
#   - connect-timeout: an unreachable cache costs seconds, not minutes;
#   - fallback: after a failed query (unreachable, 5xx, or 401 from a
#     missing/wrong netrc) Nix disables the cache for 60 s and goes on with
#     cache.nixos.org (HttpBinaryCacheStore::maybeDisable only does so with
#     fallback on), and a NAR whose download fails is built instead.
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
      default = "/var/lib/nix-cache/netrc";
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
    nix.settings = {
      substituters = [ "https://${cache.host}?priority=${toString cfg.priority}" ];
      trusted-public-keys = [ cache.publicKey ];
      netrc-file = cfg.netrcFile;
      connect-timeout = mkDefault 5;
      fallback = mkDefault true;
    };
  };
}
