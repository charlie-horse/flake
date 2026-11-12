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
  dataDir = "/mutable/minecraft/bbb";

  serverProperties = pkgs.writeText "server.properties" ''
    difficulty=hard
    enable-command-block=true
    online-mode=false
    server-port=${builtins.toString ports.bbb}
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
  config.users.users.bbb = {
    isSystemUser = true;
    group = "minecraft";
    home = dataDir;
    createHome = true;
  };
  config.systemd = {
    sockets.bbb = {
      bindsTo = [ "bbb.service" ];
      socketConfig = {
        ListenFIFO = "${dataDir}/bbb.stdin";
        RemoveOnStop = true;
        FlushPending = true;
      };
    };
    services.bbb = {
      description = "BBB Minecraft Server";
      wantedBy = [ "multi-user.target" ];
      requires = [ "bbb.socket" ];
      after = [
        "network.target"
        "bbb.socket"
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
        User = "bbb";
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
