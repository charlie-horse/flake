{ lib, ... }:
let
  inherit (lib)
    types
    mkOption
    ;
  mkPort =
    port:
    mkOption {
      type = types.port;
      default = port;
    };
in
{
  options.custom.ports = rec {
    basePort = mkPort 42000;
    nginx = mkPort (basePort.default + 1);
    vaultwarden = mkPort (basePort.default + 2);
    grafana = mkPort (basePort.default + 3);

    velocity = mkPort 25565;
    shadowsocks = mkPort 994;

    lobby = mkPort (basePort.default + 100);
    atm8 = mkPort (basePort.default + 101);
    bbb = mkPort (basePort.default + 102);
    valhelsia = mkPort (basePort.default + 103);
    blehmc = mkPort (basePort.default + 104);

    tr = mkPort 9091;
    fin = mkPort 8096;
    flood = mkPort 5096;
    arr = {
      idx = mkPort 9696;
      tv = mkPort 8989;
      mv = mkPort 7878;
      sub = mkPort 6767;
      see = mkPort 5055;
    };
  };
  config.networking.firewall.allowedTCPPorts = [
    22
    994
    25565
  ];
  config.networking.firewall.allowedUDPPorts = [
    994
    25565
  ];
}
