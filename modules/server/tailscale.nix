# Tailscale on every server (c4130, r440, m2mini), declaratively.
#
# Until 2026-11 only `services.tailscale.enable` was in Nix; everything else
# had been set by hand with `tailscale up`/`set`. The flags below reproduce
# the live prefs read on 2026-11-12 (`tailscale debug prefs`, 1.104.4):
#
#   RunSSH true              --ssh=true            (Tailscale SSH: the ONLY
#                                                   way into these hosts)
#   CorpDNS true             --accept-dns=true     (MagicDNS: the cluster
#                                                   names resolve through it)
#   RouteAll false           --accept-routes=false
#   AdvertiseRoutes 0/0 ::/0 --advertise-exit-node=true
#     + per host             --advertise-routes=<server.tailscale.advertiseRoutes>
#   NetfilterMode 2 (on)     --netfilter-mode=on
#   NoSNAT false             --snat-subnet-routes=true
#   NoStatefulFiltering true --stateful-filtering=false
#   ShieldsUp false          --shields-up=false
#   RunWebClient false       --webclient=false
#   AdvertiseTags            --advertise-tags (up only; `set` has no such flag)
#
# How the NixOS module applies them:
#   - tailscaled-set (oneshot, every start of the unit, i.e. boot and any
#     switch that changes the flags): `tailscale set <setFlags>`. `set` only
#     touches the prefs it names, so this must stay EXACTLY the live state,
#     or a switch silently changes routing/SSH on the node.
#   - tailscaled-autoconnect: `tailscale up --auth-key ... <upFlags>`, but
#     only when the node is logged out/stopped, and only when the auth key
#     file exists (ConditionPathExists below). A running node is untouched.
#
# Auth key (reinstall only): never in git, the store or a command line.
# Generate a pre-approved, non-ephemeral auth key tagged tag:node in the
# admin console, then on the new host
#   sudo install -d -m 0700 /var/lib/tailscale
#   sudo sh -c 'umask 077; cat > /var/lib/tailscale/authkey'   # paste, ^D
# and switch. Delete the file once the node shows up (it is single-use
# anyway); without it tailscaled-autoconnect is skipped.
#
# Tags: all three nodes are tag:node on the control plane. c4130 advertises
# it (AdvertiseTags = [ "tag:node" ]); r440 and m2mini got it from the admin
# console and advertise none (AdvertiseTags = null). advertiseTags mirrors
# that per host so `up` never sees a pref change; on a reinstall the tag
# comes from the tagged auth key.
{
  config,
  lib,
  ...
}:
let
  inherit (lib) mkOption types concatStringsSep;
  cfg = config.server.tailscale;

  b = v: if v then "true" else "false";
  setFlags = [
    "--ssh=${b cfg.ssh}"
    "--accept-dns=${b cfg.acceptDns}"
    "--accept-routes=${b cfg.acceptRoutes}"
    "--advertise-exit-node=${b cfg.advertiseExitNode}"
    "--advertise-routes=${concatStringsSep "," cfg.advertiseRoutes}"
    "--netfilter-mode=${cfg.netfilterMode}"
    "--snat-subnet-routes=true"
    "--stateful-filtering=false"
    "--shields-up=false"
    "--webclient=false"
  ];
  upFlags =
    setFlags
    ++ lib.optional (
      cfg.advertiseTags != [ ]
    ) "--advertise-tags=${concatStringsSep "," cfg.advertiseTags}";
in
{
  options.server.tailscale = {
    ssh = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Tailscale SSH (RunSSH). It is the only way into the servers: turning
        it off from a session that came in over it locks everyone out.
      '';
    };
    acceptDns = mkOption {
      type = types.bool;
      default = true;
      description = "Use MagicDNS (CorpDNS); the cluster's node names resolve through it.";
    };
    acceptRoutes = mkOption {
      type = types.bool;
      default = false;
      description = "Accept other nodes' subnet routes (RouteAll).";
    };
    advertiseExitNode = mkOption {
      type = types.bool;
      default = true;
      description = "Offer this node as an exit node (advertises 0.0.0.0/0 and ::/0).";
    };
    advertiseRoutes = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "10.0.1.0/24" ];
      description = ''
        Subnet routes to advertise, without the exit-node routes. Must match
        the live AdvertiseRoutes (minus 0.0.0.0/0 and ::/0) exactly.
      '';
    };
    advertiseTags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "tag:node" ];
      description = ''
        ACL tags to request at login (`tailscale up` only). Must match the
        live AdvertiseTags (empty when the tag was set in the admin console).
      '';
    };
    netfilterMode = mkOption {
      type = types.enum [
        "on"
        "nodivert"
        "off"
      ];
      default = "on";
      description = "Tailscale's netfilter mode (NetfilterMode).";
    };
    authKeyFile = mkOption {
      # A string on purpose: a Nix path would copy the key into the store.
      type = types.str;
      default = "/var/lib/tailscale/authkey";
      description = ''
        Root-only file with an auth key, used only to log a logged-out node
        in (reinstall). Made by hand, never in git or the store; when it is
        missing, tailscaled-autoconnect is skipped.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.authKeyFile && !(lib.hasPrefix builtins.storeDir cfg.authKeyFile);
        message = "server.tailscale.authKeyFile must be an absolute path outside the Nix store.";
      }
    ];

    services.tailscale = {
      enable = true;
      # IP forwarding for the subnet routes and the exit node (the kubelet
      # module sets net.ipv4.ip_forward too).
      useRoutingFeatures = "server";
      inherit (cfg) authKeyFile;
      extraUpFlags = upFlags;
      extraSetFlags = setFlags;
    };

    systemd.services.tailscaled.serviceConfig.Environment = [
      "TS_DEBUG_FIREWALL_MODE=nftables"
    ];

    systemd.services.tailscaled-autoconnect.unitConfig.ConditionPathExists = cfg.authKeyFile;
  };
}
