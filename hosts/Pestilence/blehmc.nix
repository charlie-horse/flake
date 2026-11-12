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
  dataDir = "/mutable/minecraft/blehmc";

  serverProperties = pkgs.writeText "server.properties" ''
    difficulty=hard
    enable-command-block=true
    online-mode=false
    server-port=${builtins.toString ports.blehmc}
    spawn-protection=0
  '';

  paperGlobal = pkgs.writeText "paper-global.yml" (
    lib.generators.toYAML { } {
      proxies.velocity = {
        enabled = true;
        online-mode = true;
        secret = mc.forwardingSecret;
      };
    }
  );
in
{
  config.users.users.blehmc = {
    isSystemUser = true;
    group = "minecraft";
    home = dataDir;
    createHome = true;
  };
  config.systemd = {
    sockets.blehmc = {
      bindsTo = [ "blehmc.service" ];
      socketConfig = {
        ListenFIFO = "${dataDir}/blehmc.stdin";
        RemoveOnStop = true;
        FlushPending = true;
      };
    };
    services.blehmc = {
      description = "BLEH Minecraft Server";
      wantedBy = [ "multi-user.target" ];
      requires = [ "blehmc.socket" ];
      after = [
        "network.target"
        "blehmc.socket"
      ];

      path = [ pkgs.jdk17 ];

      script = ''
                        echo $USER
                        mkdir -p ${dataDir}/config

                        echo "eula=true" > ${dataDir}/eula.txt
                        cp -f ${paperGlobal} ${dataDir}/config/paper-global.yml
                        ln -sf ${serverProperties} ${dataDir}/server.properties

        	        ${pkgs.papermc}/bin/minecraft-server
        	    '';

      serviceConfig = {
        User = "blehmc";
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
