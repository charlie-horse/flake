{ pkgs, lib, config, ... }: let
    inherit (lib)
        mkMerge;
    inherit (config.custom)
        user;
in {
    config = mkMerge [
        {
            programs.nix-index.enable = true;
            programs.fish = {
                enable = true;
                useBabelfish = true;
                promptInit = ''
                    any-nix-shell fish | source
                    starship init fish | source
                '';
            };
            users.users.${user.name}.shell = pkgs.fish;
            environment.systemPackages = with pkgs; [
                bat
                eza
                btop
                ouch
                ripgrep
                starship
                tealdeer
                rm-improved
                any-nix-shell
            ];
            environment.shellAliases = {
                la = "ls -a";
                ta = "tr -a";
                tr = "ls --tree -L 3";
                ls = "eza "
                    + "--long "
                    + "--binary "
                    + "--icons "
                    + "--color=auto "
                    + "--group-directories-first "
                    + "--git "
                    + "--time modified";
            };
        }
        {
            programs.command-not-found.enable = false;
        }
    ];
}
