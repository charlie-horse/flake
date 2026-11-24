# sops-nix on every host (desktops via modules/, servers via
# modules/server/default.nix). Operating it: docs/auth.md, "sops-nix on the
# hosts".
#
# Every sops file goes through builtins.path (defaultSopsFile below too), so
# a host's closure holds only its own sops files, not the flake source.
# Decryption key: the host's SSH ed25519 key only (no GnuPG, no RSA keys).
# The pre-switch check sopsDecrypt refuses a switch the host could not
# decrypt for; the sopsHostKey activation script makes a missing host key
# (fallback for activations that skip the check); custom.sopsPasswords
# derives login password hashes from plaintext sops keys.
# Assumes the classic perl `users` activation script (asserted).
{
  config,
  options,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  inherit (lib)
    types
    mkOption
    ;
  hostKey = "/etc/ssh/ssh_host_ed25519_key";
  # Derived password hashes (custom.sopsPasswords), root 0700, on /run.
  hashDir = "/run/sops-password-hashes";
  cfg = config.custom.sopsPasswords;
  defaultSopsFile = toString config.sops.defaultSopsFile;

  # Every sops file this configuration decrypts at activation: the default
  # file (if it exists) and each secret's sopsFile, deduplicated.
  sopsFiles = lib.unique (
    lib.optional (builtins.pathExists config.sops.defaultSopsFile) "${config.sops.defaultSopsFile}"
    ++ lib.mapAttrsToList (_: s: "${s.sopsFile}") config.sops.secrets
  );

  mkpasswd = "${pkgs.mkpasswd}/bin/mkpasswd";

  # The nixpkgs sops-nix follows, for the sops tools the pre-switch check
  # runs. The check needs sops 3.10+ (SOPS_AGE_KEY_CMD).
  sopsNixPkgs = inputs.sops-nix.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  options.custom.sopsPasswords = mkOption {
    default = { };
    description = ''
      Users whose login password comes from a plaintext sops key. Each
      entry declares sops.secrets.<key> (neededForUsers), derives its
      yescrypt hash at activation and sets
      users.users.<name>.hashedPasswordFile to it.
    '';
    type = types.attrsOf (
      types.submodule (
        { name, config, ... }:
        {
          options = {
            key = mkOption {
              type = types.str;
              default = "${name}-password";
              description = "sops key holding the plaintext password.";
            };
            sopsFile = mkOption {
              type = types.str;
              default = defaultSopsFile;
              defaultText = lib.literalExpression "config.sops.defaultSopsFile";
              description = "sops file holding the key.";
            };
            hashFile = mkOption {
              type = types.str;
              readOnly = true;
              default = "${hashDir}/${name}";
              description = "Where the derived yescrypt hash is written.";
            };
          };
        }
      )
    );
  };

  config = {
    system.activationScripts = {
      sopsHostKey = lib.stringAfter [ "specialfs" ] ''
        if [ ! -s ${hostKey} ]; then
          echo "generating ${hostKey} (sops-nix decryption identity)..."
          mkdir -p -m 0755 ${dirOf hostKey}
          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "" -f ${hostKey}
        fi
      '';
      setupSecretsForUsers.deps = [ "sopsHostKey" ];
    }
    // lib.optionalAttrs (cfg != { }) {
      sopsPasswordHashes = {
        deps = [ "setupSecretsForUsers" ];
        # Not run on dry-activate (sops-nix installs nothing then either).
        supportsDryActivation = false;
        text = ''
          # Ours alone (not /run/secrets-for-users, which sops-install-secrets
          # creates only after a successful decryption): exists whatever it did.
          install -d -m 0700 -o root -g root ${hashDir}
          case $(stat -f -c %T ${hashDir}) in
            tmpfs | ramfs) ;;
            *) echo "warning: ${hashDir} is not on tmpfs/ramfs: password hashes persist on disk" >&2 ;;
          esac
          # _sopsWriteHash HASH FILE: atomically, root 0600.
          _sopsWriteHash() {
            ( umask 077 && printf '%s\n' "$1" > "$2.tmp" && mv -f "$2.tmp" "$2" )
          }
          # _sopsPasswordHash USER PLAINTEXT_FILE HASH_FILE
          _sopsPasswordHash() {
            local user=$1 plain=$2 out=$3 old new=""
            old=$(getent shadow "$user" | cut -d: -f2) || old=""
            if [ -r "$plain" ] && grep -q '[^[:space:]]' "$plain"; then
              if [[ $old == '$y$'* ]] \
                && [ "$(${mkpasswd} -m yescrypt --stdin -S "''${old%\$*}" < "$plain")" = "$old" ]; then
                new=$old
              else
                new=$(${mkpasswd} -m yescrypt --stdin < "$plain") || new=""
              fi
            fi
            if [[ $new != '$y$'* ]]; then
              echo "ERROR: no password for $user: $plain is missing or empty" >&2
              echo "  (sops decryption failed? see setupSecretsForUsers above), or mkpasswd failed." >&2
              if [[ $old == '$'* ]]; then
                echo "  Keeping $user's previous password hash from /etc/shadow." >&2
                _sopsWriteHash "$old" "$out"
              else
                echo "  $user has no previous password hash: the account is LOCKED." >&2
                rm -f "$out"
              fi
              return 1
            fi
            _sopsWriteHash "$new" "$out"
          }
        ''
        + lib.concatStrings (
          lib.mapAttrsToList (user: c: ''
            _sopsPasswordHash ${
              lib.escapeShellArgs [
                user
                config.sops.secrets.${c.key}.path
                c.hashFile
              ]
            }
          '') cfg
        );
      };
      # nixpkgs' users script reads hashedPasswordFile: after the hashes.
      users.deps = [ "sopsPasswordHashes" ];
    };

    sops = {
      # sops-install-secrets from sops-nix's own flake packages, built with
      # the nixpkgs sops-nix follows, not with the host's pkgs (it needs a
      # newer Go than nixpkgs-unstable may have). validationPackage (the
      # build-time manifest check) defaults to this package when not
      # cross-compiling.
      package = inputs.sops-nix.packages.${pkgs.stdenv.hostPlatform.system}.sops-install-secrets;
      # This one file in the store, not the flake source (see the header).
      defaultSopsFile =
        let
          name = "${lib.toLower config.networking.hostName}.yaml";
          path = "${inputs.self}/secrets/${name}";
        in
        if builtins.pathExists path then builtins.path { inherit path name; } else path;
      age = {
        sshKeyPaths = [ hostKey ];
        keyFile = null;
        generateKey = false;
      };
      gnupg.sshKeyPaths = [ ];

      secrets = lib.mapAttrs' (
        _: c:
        lib.nameValuePair c.key {
          inherit (c) sopsFile;
          # /run/secrets-for-users/<key>, root 0400, before users exist.
          neededForUsers = true;
        }
      ) cfg;
    };

    users.users = lib.mapAttrs (_: c: { hashedPasswordFile = c.hashFile; }) cfg;

    assertions = [
      {
        assertion =
          cfg == { }
          || (
            !config.systemd.sysusers.enable && !(options.services ? userborn && config.services.userborn.enable)
          );
        message = "modules/system/sops.nix: custom.sopsPasswords needs the perl `users` activation script (no systemd.sysusers, no userborn).";
      }
    ];

    # Refuse to switch when the host cannot decrypt a sops file it uses
    # (see the header). Runs as root from the NEW generation's
    # switch-to-configuration, for every action, before activation.
    system.preSwitchChecks.sopsDecrypt = ''
      PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.gnused
        ]
      }:$PATH
      key=${hostKey}
      if [ ! -s "$key" ]; then
        echo "sops: $key does not exist, so this host cannot decrypt its secrets"
        echo "  (admin would have no password). Create it and enroll it first:"
        echo "  docs/hosts/famine.md, steps 1-2 (sudo ssh-keygen -A; add its"
        echo "  ssh-to-age recipient to .sops.yaml; sops updatekeys; merge)."
        exit 1
      fi
      home=$(mktemp -d)
      trap 'rm -rf "$home"' EXIT
      failed=0
      for f in ${lib.escapeShellArgs sopsFiles}; do
        # Only the host key: no ~/.config/sops, ~/.ssh or SOPS_AGE_* from
        # the caller's environment. The key goes through SOPS_AGE_KEY_CMD +
        # ssh-to-age (SOPS_AGE_SSH_PRIVATE_KEY_FILE does not work).
        if (cd / && env -i HOME="$home" \
          SOPS_AGE_KEY_CMD="${sopsNixPkgs.ssh-to-age}/bin/ssh-to-age -private-key -i $key" \
          ${sopsNixPkgs.sops}/bin/sops -d "$f" >/dev/null 2>"$home/err"); then
          echo "sops: decrypts ''${f#/nix/store/*-}"
        else
          echo "sops: CANNOT decrypt ''${f#/nix/store/*-} with $key:"
          sed 's/^/    /' "$home/err"
          failed=1
        fi
      done
      if [ "$failed" -ne 0 ]; then
        echo "sops: refusing to switch: this host is not a recipient of the file(s)"
        echo "  above (or they were not re-encrypted). Add its ssh-to-age recipient"
        echo "  to .sops.yaml and run sops updatekeys (docs/hosts/famine.md, step 2)."
        exit 1
      fi
    '';
  };
}
