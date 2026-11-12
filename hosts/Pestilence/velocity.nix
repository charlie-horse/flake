{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    types
    mkOption
    ;
  inherit (config.custom)
    mc
    ports
    ;

  velocityDir = "/mutable/minecraft/velocity";

  velocity =
    let
      version = "3.3.0-SNAPSHOT";
      build = "390";
    in
    pkgs.fetchurl {
      sha256 = "sha256-1Kb++n9olAzCIRrlDNwE1wFV3z2Nf9QbVplQDwsdNQw=";
      url =
        "https://api.papermc.io/v2/projects/velocity"
        + "/versions/${version}/builds/${build}"
        + "/downloads/velocity-${version}-${build}.jar";
    };

  velocityConfig = pkgs.writeText "velocity.toml" ''
    config-version = "2.7"

    bind = "0.0.0.0:25565"
    motd = "<#ffb8f0>sortofasian.io"
    show-max-players = 0

    online-mode = true
    froce-key-authentication = true
    prevent-client-proxy-connections = false
    kick-existing-players = false

    player-info-forwarding-mode = "modern"
    forwarding-secret-file = "/nix/store/af7lr7f2jpl3m04n8av1p0yq9l0fynz0-forwarding.secret"
    announce-forge = true
    ping-passthrough = "disabled"

    [servers]
    lobby = "127.0.0.1:42100"
    atm8  = "127.0.0.1:42101"
    bbb   = "127.0.0.1:42102"
    val   = "127.0.0.1:42103"
    blehmc = "127.0.0.1:42104"

    try = [ "lobby" ]

    [forced-hosts]
    "blehmc.sortofasian.io" = [ "blehmc" ]
    "atm8.sortofasian.io" = [ "atm8" ]
    "bbb.sortofasian.io" = [ "bbb" ]
    "val.sortofasian.io" = [ "val" ]

    [advanced]
    compression-threshold = 256
    compression-level = 6
    login-ratelimit = 3000
    connection-timeout = 5000
    read-timeout = 30000
    haproxy-protocol = false
    tcp-fast-open = true
    bungee-plugin-message-channel = true
    show-ping-requests = false
    failover-on-unexpected-server-disconnect = true
    announce-proxy-commands = true
    log-command-executions = true
    log-player-connections = true
    accepts-transfers = false

    [query]
    enabled = false
  '';
  ambassador = pkgs.fetchurl {
    url =
      "https://github.com/adde0109"
      + "/Ambassador/releases/download"
      + "/v1.4.4/Ambassador-Velocity-1.4.4-all.jar";
    sha256 = "sha256-q6F//UswFRAtBZ2dPpFJj+mnsAsPDjO86O5sShkQSlQ=";
  };
in
{
  config.users.groups.minecraft = {
    name = "minecraft";
  };
  config.users.users.velocity = {
    isSystemUser = true;
    group = "minecraft";
    home = velocityDir;
    createHome = true;
  };
  config.systemd = {
    sockets.velocity = {
      bindsTo = [ "velocity.service" ];
      socketConfig = {
        ListenFIFO = "${velocityDir}/velocity.stdin";
        RemoveOnStop = true;
        FlushPending = true;
      };
    };
    services.velocity = {
      description = "Velocity Minecraft Proxy";
      wantedBy = [ "multi-user.target" ];
      requires = [ "velocity.socket" ];
      after = [
        "network.target"
        "velocity.socket"
      ];

      script = ''
        mkdir -p ${velocityDir}/plugins
        ln -sf ${ambassador} ${velocityDir}/plugins/
        ln -sf ${velocityConfig} ${velocityDir}/velocity.toml

        ${pkgs.jre}/bin/java \
            -Xms512M -Xmx512M \
            -XX:+UseG1GC \
            -XX:G1HeapRegionSize=4M \
            -XX:+UnlockExperimentalVMOptions \
            -XX:+ParallelRefProcEnabled \
            -XX:+AlwaysPreTouch \
            -XX:MaxInlineLevel=15 \
            -jar ${velocity}
      '';

      serviceConfig = {
        User = "velocity";
        Group = "minecraft";
        Restart = "always";
        WorkingDirectory = "${velocityDir}";

        StandardInput = "socket";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };

  options.custom.mc.forwardingSecret = mkOption {
    type = types.str;
    default = "FDujQE5rlLki";
  };
}
