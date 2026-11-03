{ pkgs, lib, system, inputs, ...}: let
    inherit (builtins)
        baseNameOf;
    inherit (lib)
        mkForce
        nixosSystem
        removeSuffix;
    inherit (lib.strings)
        makeBinPath;
    inherit (lib.custom)
        flakePath;
    inherit (pkgs)
        writeScript;

    inherit (inputs.generators)
        nixosGenerate;
in {
    mkHost = path: let
        name = removeSuffix ".nix" (baseNameOf path);
    in {
        ${name} = nixosSystem {
            inherit system;
            specialArgs = { inherit lib name inputs system; };
            modules = [
                ../../modules
                { networking.hostName = name; }
                path
            ];
        };
    };

    mkHostIso = name: {
        ${system}.${name} = nixosGenerate {
            inherit system; format = "install-iso";
            modules = [{
                isoImage.isoName = mkForce "${name}.iso";
                isoImage.squashfsCompression = "lz4";
                nixpkgs.config.allowUnfree = true;
                environment.variables.NIXPKGS_ALLOW_UNFREE = "1";
                nix.settings.experimental-features = [ "flakes" "nix-command" ];
                environment.interactiveShellInit = "sudo ${writeScript "installer" ''
                    export PATH="${makeBinPath [pkgs.parted]}:$PATH"
                    set -eu

                    nixconfig="nix eval --raw ${flakePath}#nixosConfigurations.${name}.config"

                    bootmode=$($nixconfig.custom.bootMode)
                    swapsize=$($nixconfig.custom.swapSize)

                    repeat=true;
                    while [[ "$repeat" == true ]]; do
                        lsblk -ido KNAME,MODEL,SIZE;
                        read -p "Select a drive: " -r
                        drive=/dev/"$REPLY"

                        while test ! -e "$drive"; do
                            read -p "Please enter a valid drive: " -r
                            drive=/dev/"$REPLY"
                        done

                        loop=$(losetup -Pf "$drive" --show)
                        sleep 0.1

                        parted="parted -s $drive --"
                        case $bootmode in
                            legacy)
                                $parted mklabel msdos
                                if [[ "$swapsize" != "0" ]]; then
                                    $parted mkpart primary ext4 0% -$swapsize;
                                    $parted mkpart primary linux-swap -$swapsize 100%;
                                    $parted set 2 swap on

                                    mkswap -L swap "$loop"p2
                                else
                                    $parted mkpart primary ext4 0% 100%;
                                fi
                                mkfs.ext4 -F -L nixos "$loop"p1

                                losetup -d $loop

                                if [[ "$drive" == *"nvme"* ]];
                                    then mount "$drive"p1 /mnt;
                                    else mount "$drive"1 /mnt;
                                fi
                                ;;
                            uefi)
                                $parted mklabel gpt
                                $parted mkpart boot fat32 0% 512MB
                                $parted set 1 boot on
                                if [[ "$swapsize" != "0" ]]; then
                                    $parted mkpart nixos ext4 512MB -$swapsize;
                                    $parted mkpart swap linux-swap -$swapsize 100%;
                                    $parted set 3 swap on

                                    mkswap -L swap "$loop"p2
                                else
                                    $parted mkpart nixos ext4 512MB 100%;
                                fi

                                mkfs.fat -F32 -n BOOT "$loop"p1
                                mkfs.ext4 -F -L nixos "$loop"p2

                                losetup -d $loop

                                if [[ "$drive" == *"nvme"* ]];
                                    then mount "$drive"p2 /mnt;
                                    else mount "$drive"2 /mnt;
                                fi

                                mkdir -p /mnt/boot/efi

                                if [[ "$drive" == *"nvme"* ]];
                                    then mount "$drive"p1 /mnt/boot/efi;
                                    else mount "$drive"1 /mnt/boot/efi;
                                fi
                                ;;
                        esac
                        $parted print
                        read -p "Is this partition table correct? (y/n) " -n 1 -r
                        if [[ "$REPLY" == "y" ]]; then repeat=false; fi

                        while ! [[ "$REPLY" == "y" ]] || [[ "$REPLY" == "n" ]]; do
                            read -p "Please type y/n: " -n 1 -r
                            if [[ "$REPLY" == "y" ]]; then repeat=false; fi
                        done
                    done

                    mkdir /mnt/etc
                    cp -r ${flakePath} /mnt/etc/nixos
                    nixos-install \
                        --flake ${flakePath}#${name} \
                        --no-channel-copy \
                        --cores 0 \
                        --no-root-password

                    sleep 5
                    reboot
                ''}";
            }];
        };
    };
}
