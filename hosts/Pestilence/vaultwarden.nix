{ config, ... }:
let
  inherit (config.custom)
    ports
    ;
in
{
  services.vaultwarden = {
    enable = true;
    config = {
      DOMAIN = "https://vw.sortofasian.io";
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = builtins.toString ports.vaultwarden;
    };
  };
}
