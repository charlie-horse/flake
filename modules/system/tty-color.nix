{ config, ... }:
let
  inherit (config.custom.theme)
    colors
    ;
in
{
  # The theme's 16-colour palette on the Linux virtual consoles, from the
  # first line the kernel prints (vt.default_{red,grn,blu} kernel params).
  # This used to be printf'd from boot.initrd.preDeviceCommands, which the
  # systemd stage 1 (the nixos-unstable default) does not support.
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
