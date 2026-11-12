{ lib, config, ... }:
let
  inherit (config.custom.theme)
    colors
    ;
in
{
  boot.initrd.preDeviceCommands =
    let
      color = number: color: ''printf "\e]P${number + color}"'';
    in
    ''
      ${color "0" colors.bg}
      ${color "1" colors.red}
      ${color "2" colors.green}
      ${color "3" colors.yellow}
      ${color "4" colors.blue}
      ${color "5" colors.magenta}
      ${color "6" colors.cyan}
      ${color "7" colors.white}
      ${color "8" colors.brightblack}
      ${color "9" colors.brightred}
      ${color "A" colors.brightgreen}
      ${color "B" colors.brightyellow}
      ${color "C" colors.brightblue}
      ${color "D" colors.brightmagenta}
      ${color "E" colors.brightcyan}
      ${color "F" colors.fg}
      clear
    '';
}
