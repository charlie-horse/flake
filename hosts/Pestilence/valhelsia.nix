{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (config.custom)
    mc
    ports
    ;
  dataDir = "/mutable/minecraft/valhelsia";

  valhelsia = fetchFromCurseforge {
    filename = "Valhelsia+3-3.5.1-SERVER.zip";
    id = "3707304";
    sha256 = "sha256-ia2BcMBpF0jW74U0s9YbYYZN4vR3UTXaiPwZQsuOjQQ=";
  };

  pcf = pkgs.fetchurl {
    url =
      "https://github.com/adde0109"
      + "/Proxy-Compatible-Forge"
      + "/releases/download/1.1.3"
      + "/proxy-compatible-forge-1.16.5-1.1.3.jar";
    sha256 = "sha256-KGSQqrJF/0YdWK2MJQ3P4JqITixrRJfYrhdQrc8yqAs=";
  };

  serverProperties = pkgs.writeText "server.properties" ''
    allow-flight=true
    allow-nether=true
    difficulty=hard
    enable-command-block=true
    enable-status=true
    max-chained-neighbor-updates=1000000
    max-tick-time=180000
    max-world-size=29999984
    online-mode=false
    op-permission-level=4
    server-port=${builtins.toString ports.valhelsia}
    sync-chunk-writes=true
    use-native-transport=true

    level-name=world
    level-type=biomesoplenty
    motd="Valhelsia 3 bitch"
    network-compression-threshold=256
    snooper-enabled=true
    spawn-animals=true
    spawn-monsters=true
    spawn-npcs=true
    spawn-protection=0
  '';

  forwarding = pkgs.writeScript "pcf-common.toml" ''
    [modernForwarding]
        forwardingSecret = "${mc.forwardingSecret}"
  '';

  fetchFromCurseforge =
    {
      filename,
      id,
      sha256,
      stripRoot ? false,
    }:
    let
      args = {
        url =
          "https://media.forgecdn.net/files"
          + "/"
          + (lib.concatStrings (
            lib.flatten (
              lib.imap1 (
                i: c:
                if i == 4 then
                  [
                    c
                    "/"
                  ]
                else
                  c
              ) (lib.stringToCharacters id)
            )
          ))
          + "/${filename}";
        inherit sha256 stripRoot;
      };
    in
    (if lib.hasSuffix ".zip" filename then pkgs.fetchzip args else pkgs.fetchurl args);
in
{
  config.users.users.valhelsia = {
    isSystemUser = true;
    group = "minecraft";
    home = dataDir;
    createHome = true;
  };
  config.systemd = {
    sockets.valhelsia = {
      bindsTo = [ "valhelsia.service" ];
      socketConfig = {
        ListenFIFO = "${dataDir}/valhelsia.stdin";
        RemoveOnStop = true;
        FlushPending = true;
      };
    };
    services.valhelsia = {
      description = "Valhelsia Minecraft Server";
      wantedBy = [ "multi-user.target" ];
      requires = [ "valhelsia.socket" ];
      after = [
        "network.target"
        "valhelsia.socket"
      ];

      path = with pkgs; [
        jdk11
        curl
        gawk
      ];

      script = ''
            mkdir -p ${dataDir}/config
            mkdir -p ${dataDir}/mods

            cp -R --update ${valhelsia}/* ${dataDir}/
            find ${dataDir}/ -type f -exec chmod 644 {} \;
            find ${dataDir}/ -type d -exec chmod 755 {} \;
            chmod +x ${dataDir}/ServerStart.sh

            cp -f ${pcf} ${dataDir}/mods/

            echo "eula=true" > ${dataDir}/eula.txt
            cp -f ${forwarding} ${dataDir}/config/pcf-common.toml
            chmod +w ${dataDir}/config/pcf-common.toml
            ln -sf ${serverProperties} ${dataDir}/server.properties

        ${dataDir}/ServerStart.sh
      '';

      serviceConfig = {
        User = "valhelsia";
        Group = "minecraft";

        Restart = "always";
        WorkingDirectory = "${dataDir}";

        StandardInput = "socket";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };
}
