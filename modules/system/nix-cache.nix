# The flake's Nix binary cache as a substituter (a place Nix downloads
# built packages from), behind HTTP basic auth.
#
# Credential: a netrc line (`machine <cache host> login <user> password
# <pw>`), sops key `nix-cache-netrc` in secrets/<hostname>.yaml ->
# /run/secrets/nix-cache-netrc; never in git, the store or a command line.
#
# Substituters are tried by priority, lower first: cache.nixos.org, the
# CUDA cache (custom.nixCache.cuda), then this cache. A down cache or a
# missing netrc must not break a build: connect-timeout keeps an
# unreachable cache cheap, and fallback builds what Nix can't fetch.
# Setup: docs/build-cache.md#binary-cache.
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

  # Through inputs.self, not a relative path: mkHost imports modules/ from
  # its own store copy, which has no ../cluster.
  cache = (import "${inputs.self}/cluster/definition.nix").binaryCache;

  # nixpkgs' CUDA team cache. Its priority must stay below this cache's
  # (asserted below).
  cudaCache = {
    url = "https://cache.nixos-cuda.org";
    publicKey = "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=";
  };
in
{
  options.custom.nixCache = {
    enable = mkEnableOption "the flake's binary cache (https://${cache.host}) as a substituter";

    priority = mkOption {
      type = types.int;
      default = 50;
      description = ''
        Substituter priority (lower first). Must stay above
        cache.nixos.org's, so this cache serves only what that one lacks.
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

    cuda = {
      enable = mkEnableOption "the nixpkgs CUDA cache (${cudaCache.url}) as a substituter";
      priority = mkOption {
        type = types.int;
        default = 45;
        description = "Substituter priority: after cache.nixos.org, before the flake's cache.";
      };
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.cuda.enable {
      assertions = [
        {
          assertion = !cfg.enable || cfg.cuda.priority < cfg.priority;
          message = "custom.nixCache.cuda.priority must be lower than custom.nixCache.priority: the flake's cache comes last.";
        }
      ];
      nix.settings = {
        substituters = [ "${cudaCache.url}?priority=${toString cfg.cuda.priority}" ];
        trusted-public-keys = [ cudaCache.publicKey ];
        connect-timeout = mkDefault 5;
        fallback = mkDefault true;
      };
    })
    (mkIf cfg.enable {
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
    })
  ];
}
