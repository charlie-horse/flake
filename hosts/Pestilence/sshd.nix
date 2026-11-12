{ config, ... }:
let
  inherit (config.custom)
    ports
    ;
in
{
  services.openssh.enable = true;
  services.openssh.settings = {
    LogLevel = "VERBOSE";
    PermitRootLogin = "no";
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };
}
