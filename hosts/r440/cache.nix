# r440's Nix binary cache: harmonia serving r440's /nix/store, and nginx
# in front of it with HTTP basic auth, published as https://cache.neuros.is
# through the cluster's Cloudflare tunnel. Every client uses that URL
# (custom.nixCache, modules/system/nix-cache.nix).
#
#   https://cache.neuros.is -> Cloudflare -> cloudflared (any node,
#     hostNetwork) -> its nginx sidecar -> http://10.0.0.239:5080
#     -> nginx here (basic auth) -> harmonia (unix socket, its only listener)
#
# c4130 too: it no longer substitutes over bond0 (builds still go there,
# over ssh), so harmonia has no TCP listener and bond0 no port 5000.
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
# Secrets: sops-nix, keys of secrets/r440.yaml (encrypted in git; never
# in plaintext in git, the store or a command line; docs/cluster.md):
#   harmonia-signing-key  signing key `r440-cache-1:<base64>` (root, 0600).
#                         Was /var/lib/secrets/harmonia.secret.
#   nix-cache-htpasswd    basic-auth users (root:nginx, 0640), one line per
#                         client (ci, famine, c4130, m2mini, ...):
#                         `<user>:<bcrypt hash>`. Missing file: every
#                         request gets 500. Was /var/lib/nix-cache/htpasswd.
# Shred both old files once the sops ones are live.
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

  # Same sources as the cluster ports (modules/cluster/firewall.nix).
  nodeSources = lib.unique (lib.mapAttrsToList (_: n: n.lanIP) cluster.nodes ++ [ cluster.vip ]);
in
{
  # --- secrets -------------------------------------------------------------
  sops.secrets = {
    # Read once at start (systemd LoadCredential), hence the restart.
    harmonia-signing-key = {
      owner = "root";
      group = "root";
      mode = "0600";
      restartUnits = [ "harmonia.service" ];
    };
    # nginx opens auth_basic_user_file on every request; the reload is
    # only belt and braces.
    nix-cache-htpasswd = {
      owner = "root";
      group = config.services.nginx.group;
      mode = "0640";
      reloadUnits = [ "nginx.service" ];
    };
  };

  # --- harmonia ----------------------------------------------------------
  # Signing key `r440-cache-1`; its public half is cluster.binaryCache.
  # publicKey (cluster/definition.nix).
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ config.sops.secrets.harmonia-signing-key.path ];
    # The default for clients that set none; ours set ?priority=
    # (modules/system/nix-cache.nix).
    settings.priority = 30;
    # The only listener (the module turns it into the socket unit's
    # ListenStream). No TCP: c4130 substitutes through the tunnel too.
    settings.bind = "unix:${socket}";
  };
  systemd.sockets.harmonia.socketConfig = {
    # nginx only.
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
        auth_basic_user_file ${config.sops.secrets.nix-cache-htpasswd.path};
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
  # --- firewall ------------------------------------------------------------
  networking.firewall.extraCommands = lib.concatMapStrings (src: ''
    iptables -A nixos-fw -p tcp -s ${src} --dport ${toString cache.port} -j nixos-fw-accept
  '') nodeSources;
}
