{
  pkgs,
  lib,
  config,
  ...
}:
let
  inherit (lib)
    mkIf
    types
    mkOption
    ;
  inherit (config.custom)
    user
    star-citizen
    ;
in
{
  options.custom.star-citizen.enable = mkOption {
    type = types.bool;
    default = false;
  };

  config = mkIf star-citizen.enable {
    boot.kernel.sysctl = {
      "vm.max_map_count" = 16777216;
      "net.ipv4.neigh.default.gc_thresh1" = 32768;
      "net.ipv4.neigh.default.gc_thresh2" = 65536;
      "net.ipv4.neigh.default.gc_thresh3" = 131072;
    };

    users.users.${user.name}.packages = [
      pkgs.winePackages.stableFull
      pkgs.winetricks
      pkgs.protontricks
      (pkgs.stdenv.mkDerivation (
        let
          inherit (pkgs)
            makeWrapper
            makeDesktopItem
            fetchFromGitHub
            curl
            bash
            zenity
            gnused
            polkit
            gnugrep
            coreutils
            findutils
            ;
          inherit (lib)
            makeBinPath
            ;
        in
        rec {
          pname = "lug-helper";
          version = "v2.6.3";
          name = "${pname}-${version}";
          src = fetchFromGitHub {
            owner = "starcitizen-lug";
            repo = pname;
            rev = version;
            sha256 = "sha256-9joiAxK0wuklwzWX+A//8Rjw7FheuOQy92v3fJxz7Lk=";
          };

          desktopItem = makeDesktopItem {
            name = pname;
            exec = pname;
            icon = pname;
            categories = [ "Game" ];
            desktopName = "LUG Helper";
            startupNotify = true;
          };

          buildInputs = [ makeWrapper ];

          binPath = makeBinPath [
            bash
            coreutils
            curl
            polkit
            gnused
            zenity
            findutils
            gnugrep
          ];

          installPhase = ''
            runHook preBuild

            mkdir -p $out/bin
            makeWrapper "$src/lug-helper.sh" "$out/bin/$pname" \
            --prefix PATH : $binPath

            install -Dm755 "$src/lug-logo.png" \
                "$out/share/pixmaps/$pname.png"
            install -Dm755 "$src/lutris-sc-install.json" \
                "$out/share/$pname/lutris-sc-install.json"
            install -Dm755 "$desktopItem/share/applications/$pname.desktop" \
                "$out/share/applications/$pname.desktop"

            runHook postBuild
          '';
        }
      ))
    ];
  };
}
