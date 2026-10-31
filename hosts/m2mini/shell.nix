{ pkgs, ... }: {
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
        ls = "eza "
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
    users.users.charlie.shell = pkgs.fish;
}
