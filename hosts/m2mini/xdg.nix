# XDG base directories (and the dotfiles that can follow them) for every
# login shell on m2mini. Relative to "$HOME", which /etc/set-environment
# expands per user (bash and, through babelfish, fish), so admin and
# `sudo -i` root each get their own. Until 2026-11 these were charlie's
# absolute paths, forced on every user. XDG_RUNTIME_DIR is left to
# pam_systemd (/run/user/<uid> of whoever logs in); it used to be pinned to
# charlie's uid.
{ ... }:
let
  cache = "$HOME/.cache";
  config = "$HOME/.config";
  local = "$HOME/.local";
  data = "${local}/share";
  state = "${local}/state";
  bin = "${local}/bin";
in
{
  environment.variables = {
    XDG_CACHE_HOME = cache;
    XDG_CONFIG_HOME = config;
    XDG_DATA_HOME = data;
    XDG_STATE_HOME = state;
    XDG_BIN_HOME = bin;

    HISTFILE = "${data}/bash/history";
    INPUTRC = "${config}/readline/inputrc";
    LESSHISTFILE = "${state}/lesshst";
    WGETRC = "${config}/wgetrc";
  };
}
