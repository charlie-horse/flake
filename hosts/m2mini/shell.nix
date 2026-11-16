{
  config,
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages = with pkgs; [
    bat
    eza
    btop
    ouch
    ripgrep
    starship
    any-nix-shell
  ];
  environment.shellAliases = {
    flake = "cd /etc/nixos; nvim";
    cat = "bat";
    la = "ls -a";
    ta = "tr -a";
    tr = "ls --tree -L 3";
    ls =
      "eza "
      + "--long "
      + "--binary "
      + "--icons "
      + "--color=auto "
      + "--group-directories-first "
      + "--git "
      + "--time modified";
  };
  programs.nix-index.enable = true;
  programs.fish = {
    enable = true;
    useBabelfish = true;
    promptInit = ''
      any-nix-shell fish | source
      starship init fish | source
    '';
  };
  # Tailscale SSH runs remote commands through fish: use `ssh ... bash -s`
  # or `ssh -t ... bash` for sh syntax.
  users.users.admin.shell = pkgs.fish;
  users.users.charlie = lib.mkIf config.custom.server.legacyCharlie.enable {
    shell = pkgs.fish;
  };
}
