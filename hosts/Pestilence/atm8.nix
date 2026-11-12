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
  dataDir = "/mutable/minecraft/atm8";

  atm8 = fetchFromCurseforge {
    filename = "Server-Files-1.0.15.zip";
    id = "4461196";
    sha256 = "sha256-jiQq3imoLCtZbv95usIlpFVezfUPKKgDhuHFbpH+Bxs=";
  };

  pcf = pkgs.fetchurl {
    url =
      "https://github.com/adde0109"
      + "/Proxy-Compatible-Forge"
      + "/releases/download/1.1.0"
      + "/proxy-compatible-forge-1.19.2-1.1.0.jar";
    sha256 = "sha256-D3IqAFBoQ3NWZJTRF8NLNryFX/WWIjNEJosfWrFjfS4=";
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
    server-port=${builtins.toString ports.atm8}
    sync-chunk-writes=true
    use-native-transport=true
  '';

  forwarding = pkgs.writeText "pcf-common.toml" ''
    [modernForwarding]
        forwardingSecret = "${mc.forwardingSecret}"
  '';

  fetchFromCurseforge =
    {
      filename,
      id,
      sha256,
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
        inherit sha256;
      };
    in
    (if lib.hasSuffix ".zip" filename then pkgs.fetchzip args else pkgs.fetchurl args);
in
{
  config.users.users.atm8 = {
    isSystemUser = true;
    group = "minecraft";
    home = dataDir;
    createHome = true;
  };
  config.systemd = {
    sockets.atm8 = {
      bindsTo = [ "atm8.service" ];
      socketConfig = {
        ListenFIFO = "${dataDir}/atm8.stdin";
        RemoveOnStop = true;
        FlushPending = true;
      };
    };
    services.atm8 = {
      description = "ATM8 Minecraft Server";
      wantedBy = [ "multi-user.target" ];
      requires = [ "atm8.socket" ];
      after = [
        "network.target"
        "atm8.socket"
      ];

      path = with pkgs; [
        jdk17
        curl
        gawk
      ];

      script = ''
            mkdir -p ${dataDir}/config
            mkdir -p ${dataDir}/mods

            cp -nR ${atm8}/* ${dataDir}/
            find ${dataDir}/ -type f -exec chmod 644 {} \;
            find ${dataDir}/ -type d -exec chmod 755 {} \;
            chmod +x ${dataDir}/startserver.sh

            cp -f ${pcf} ${dataDir}/mods/

            echo "eula=true" > ${dataDir}/eula.txt
            cp -f ${forwarding} ${dataDir}/config/pcf-common.toml
            ln -sf ${serverProperties} ${dataDir}/server.properties

        ${dataDir}/startserver.sh
      '';

      serviceConfig = {
        User = "atm8";
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
