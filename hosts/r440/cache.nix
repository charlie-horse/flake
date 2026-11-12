# r440's Nix binary cache: harmonia serving r440's /nix/store, and nginx
# in front of it with HTTP basic auth, published as https://cache.neuros.is
# through the cluster's Cloudflare tunnel. Every client uses that URL
# (custom.nixCache, modules/system/nix-cache.nix).
#
#   https://cache.neuros.is -> Cloudflare -> cloudflared (any node,
#     hostNetwork) -> its nginx sidecar -> http://10.0.0.239:5080
#     -> nginx here (basic auth) -> harmonia (unix socket)
#   c4130 -> bond0 -> harmonia 10.25.0.2:5000 (no auth; legacy direct path)
#
# The :5080 listener's only consumer is the tunnel. nginx listens on every
# address, port cluster.binaryCache.port; the firewall admits that port only
# from the cluster nodes' LAN IPs and the VIP (the tunnel connectors run on
# all three nodes and connect from those, or over lo on r440 itself).
# tailscale0 is trusted on r440, so tailnet clients reach it too; all of
# them need the password.
#
# Why nginx here and not in the tunnel's nginx sidecar: harmonia (3.1.0 in
# nixpkgs 26.05) has no client authentication at all (only TLS), so
# something in front has to do it. Doing it on r440 keeps the
# unauthenticated harmonia off the LAN (for the sidecar, harmonia would have
# to listen on r440's LAN IP for all three nodes, and every pod on them is
# masqueraded to those IPs), and keeps the htpasswd in one file on the one
# host that serves the store (no Kubernetes Secret).
#
# Secrets, never in git, the store or a command line (docs/cluster.md):
#   /var/lib/secrets/harmonia.secret  signing key (root, 0600; existing)
#   /var/lib/nix-cache/htpasswd       basic-auth users (root:nginx, 0640),
#                                     one line per client (ci, famine,
#                                     c4130, m2mini, ...): `<user>:<hash>`.
#                                     Missing file: every request gets 500.
#
# Read-only: harmonia only serves; nginx rejects everything but GET/HEAD.
{
  config,
  lib,
  cluster,
  ...
}:
let
  cache = cluster.binaryCache;

  # harmonia -> nginx. In /run itself: /run/harmonia is the service's
  # RuntimeDirectory and is removed when it stops.
  socket = "/run/harmonia-cache.sock";
  htpasswdDir = "/var/lib/nix-cache";

  # Same sources as the cluster ports (modules/cluster/firewall.nix).
  nodeSources = lib.unique (lib.mapAttrsToList (_: n: n.lanIP) cluster.nodes ++ [ cluster.vip ]);
in
{
  # --- harmonia ----------------------------------------------------------
  # Signing key generated on r440 (never leaves it): see the switch steps.
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ "/var/lib/secrets/harmonia.secret" ];
    # The default for clients that set none; ours set ?priority=
    # (modules/system/nix-cache.nix).
    settings.priority = 30;
    settings.bind = "10.25.0.2:5000";
  };
  systemd.sockets.harmonia.socketConfig = {
    # Every listener harmonia gets (it takes all inherited fds): c4130's
    # direct path and nginx's socket.
    ListenStream = lib.mkForce [
      config.services.harmonia.cache.settings.bind
      socket
    ];
    # Bind even before bond0 has its address.
    FreeBind = true;
    # The unix socket: nginx only.
    SocketUser = "root";
    SocketGroup = config.services.nginx.group;
    SocketMode = "0660";
  };

  # --- nginx: basic auth -------------------------------------------------
  services.nginx = {
    enable = true;
    virtualHosts.nix-cache = {
      serverName = cache.host;
      default = true;
      # Every address; the firewall below decides who gets to it.
      listen = [
        {
          addr = "0.0.0.0";
          port = cache.port;
        }
      ];
      extraConfig = ''
        # Nix asks for thousands of .narinfo files; r440's root is a slow HDD.
        access_log off;
        auth_basic "nix cache";
        auth_basic_user_file ${htpasswdDir}/htpasswd;
        # Never in a shared cache (Cloudflare's edge included), even
        # though every response needs the password.
        add_header Cache-Control "private, no-store" always;
        # harmonia sends NARs uncompressed; the uplink is the bottleneck.
        # Nix decompresses transparently.
        gzip on;
        gzip_comp_level 1;
        gzip_proxied any;
        gzip_types application/x-nix-archive text/x-nix-narinfo text/x-nix-cache-info;
      '';
      locations."/" = {
        proxyPass = "http://unix:${socket}:";
        extraConfig = ''
          limit_except GET HEAD { deny all; }
          proxy_http_version 1.1;
          proxy_set_header Connection "";
          # harmonia marks NARs `max-age=31536000` (public by default);
          # only the server's `private, no-store` may go out.
          proxy_hide_header Cache-Control;
          # Stream NARs (tens of GB for the CUDA/torch closures).
          proxy_buffering off;
          proxy_read_timeout 600s;
        '';
      };
    };
  };
  systemd.tmpfiles.rules = [
    "d ${htpasswdDir} 0750 root ${config.services.nginx.group} -"
  ];

  # --- firewall ------------------------------------------------------------
  networking.firewall.extraCommands = lib.concatMapStrings (src: ''
    iptables -A nixos-fw -p tcp -s ${src} --dport ${toString cache.port} -j nixos-fw-accept
  '') nodeSources;
}
