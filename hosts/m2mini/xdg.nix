# XDG base directories (and the dotfiles that can follow them) for every
# login shell on m2mini. Relative to "$HOME", which /etc/set-environment
# expands per user (bash and, through babelfish, fish), so admin and
# `sudo -i` root each get their own. Until 2026-11 these were charlie's
# absolute paths, forced on every user. XDG_RUNTIME_DIR is left to
# pam_systemd (/run/user/<uid> of whoever logs in); it used to be pinned to
# charlie's uid.
#
# bash and less do not create the parent directories of HISTFILE and
# LESSHISTFILE (history is then silently lost), so tmpfiles creates them for
# every account that logs in here: admin, root (`sudo -i`) and, while
# custom.server.legacyCharlie.enable is on, charlie. Each level is listed:
# tmpfiles would otherwise create missing parents as root. INPUTRC and
# WGETRC are only read; a missing file is fine.
{ config, lib, ... }:
let
  cache = "$HOME/.cache";
  configDir = "$HOME/.config";
  local = "$HOME/.local";
  data = "${local}/share";
  state = "${local}/state";
  bin = "${local}/bin";

  # Directories (relative to $HOME) that must exist for the files below.
  stateDirs = [
    ".local"
    ".local/share"
    ".local/share/bash"
    ".local/state"
  ];
  users = [
    "admin"
    "root"
  ]
  ++ lib.optional config.custom.server.legacyCharlie.enable "charlie";
  dirRules =
    name:
    let
      u = config.users.users.${name};
    in
    map (d: "d ${u.home}/${d} 0700 ${name} ${u.group} - -") stateDirs;
in
{
  systemd.tmpfiles.rules = lib.concatMap dirRules users;

  environment.variables = {
    XDG_CACHE_HOME = cache;
    XDG_CONFIG_HOME = configDir;
    XDG_DATA_HOME = data;
    XDG_STATE_HOME = state;
    XDG_BIN_HOME = bin;

    HISTFILE = "${data}/bash/history";
    INPUTRC = "${configDir}/readline/inputrc";
    LESSHISTFILE = "${state}/lesshst";
    WGETRC = "${configDir}/wgetrc";
  };
}
