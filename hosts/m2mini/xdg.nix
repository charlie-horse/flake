# XDG base directories (and the dotfiles that follow them) for every login
# shell, relative to $HOME, so each user gets their own. tmpfiles creates
# the parents of HISTFILE/LESSHISTFILE, which bash and less don't.
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
