{ config, ... }:
let
  inherit (config.custom.theme)
    colors
    ;
in
{
  # The theme's 16-colour palette on the Linux virtual consoles, from the
  # first line the kernel prints (vt.default_{red,grn,blu} kernel params).
  # Not boot.initrd.preDeviceCommands: the systemd initrd does not run it.
  console.colors = with colors; [
    bg
    red
    green
    yellow
    blue
    magenta
    cyan
    white
    brightblack
    brightred
    brightgreen
    brightyellow
    brightblue
    brightmagenta
    brightcyan
    fg
  ];
}
