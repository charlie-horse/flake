{ lib, config, ... }:
let
  inherit (lib)
    mkDefault
    ;
in
{
  time.timeZone = mkDefault "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
}
