# Nix binary cache (a server other hosts download built store paths
# from). harmonia serves this host's /nix/store on a unix socket; nginx in
# front adds HTTP basic auth and passes only GET/HEAD. The cluster's
# Cloudflare tunnel publishes it (cluster.binaryCache in
# cluster/definition.nix). Clients: custom.nixCache
# (modules/system/nix-cache.nix).
# Secrets (sops, secrets/r440.yaml): harmonia-signing-key,
# nix-cache-htpasswd (one `<user>:<SHA-512 crypt>` line per client).
# Caching, setup and adding/revoking clients: docs/build-cache.md#binary-cache.
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
    # nginx re-reads auth_basic_user_file on every request; the reload is
    # a backstop.
    nix-cache-htpasswd = {
      owner = "root";
      group = config.services.nginx.group;
      mode = "0640";
      reloadUnits = [ "nginx.service" ];
    };
  };

  # --- harmonia ----------------------------------------------------------
  # The signing key's public half is cluster.binaryCache.publicKey
  # (cluster/definition.nix).
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ config.sops.secrets.harmonia-signing-key.path ];
    # The default for clients that set none; ours set ?priority=
    # (modules/system/nix-cache.nix).
    settings.priority = 30;
    # The only listener (the module turns it into the socket unit's
    # ListenStream). No TCP listener: every client goes through the tunnel.
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
        # Off: Nix asks for thousands of .narinfo files and the root disk
        # is slow.
        access_log off;
        auth_basic "nix cache";
        auth_basic_user_file ${config.sops.secrets.nix-cache-htpasswd.path};
        # Never in a shared cache (Cloudflare's edge included), even
        # though every response needs the password.
        add_header Cache-Control "private, no-store" always;
        # Compresses NARs (Nix archives), which harmonia sends
        # uncompressed. Nix decompresses transparently.
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
          # Drops harmonia's public Cache-Control; only the server's
          # `private, no-store` goes out.
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
