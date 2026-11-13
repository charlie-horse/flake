# sops-nix on every host: the desktops get it with the rest of modules/
# (lib/system/mkHost.nix), the servers through modules/server/default.nix.
#
# Encrypted files (recipients: /.sops.yaml at the repo root):
#   secrets/<hostname>.yaml  this host only, e.g. secrets/c4130.yaml,
#                            secrets/famine.yaml (lowercase hostname); the
#                            default for every sops.secrets.<name>
#   secrets/common.yaml      every host; select it per secret with
#                            sopsFile = builtins.path {
#                              path = "${inputs.self}/secrets/common.yaml";
#                              name = "common.yaml";
#                            };
#
# Always through builtins.path as above (defaultSopsFile below too): it
# copies that one file to the store, so a host's closure references only
# its own sops files. A bare "${inputs.self}/secrets/..." or a path inside
# the flake source would make every system depend on the whole flake
# source (and a relative ../../secrets breaks on the desktops, whose
# modules/ mkHost imports from a store copy of its own).
#
# Decryption key: the host's own SSH ed25519 host key, converted to an age
# identity at activation (its age recipient is `ssh-to-age` of the public
# key, which is what .sops.yaml lists). No GnuPG and no RSA host keys: both
# lists below are set explicitly so sops-nix's defaults (every RSA/ed25519
# key in services.openssh.hostKeys) never add one.
#
# Edit a file with `sops secrets/<file>.yaml` from the dev shell (devenv.nix:
# sops, age, age-plugin-yubikey, ssh-to-age). Secrets land in /run/secrets/
# (neededForUsers: /run/secrets-for-users/, before users are created).
#
# Can this host decrypt? Checked twice, automatically:
#   - CI (.github/workflows/checks.yml, secrets-guard): every sops file's
#     age recipients equal its .sops.yaml creation rule, i.e. no file was
#     left un-re-encrypted after a recipient change. No keys needed.
#   - On the host, before every switch/boot/test (system.preSwitchChecks.
#     sopsDecrypt below): each sops file this configuration uses is
#     decrypted with the host key (to /dev/null). Any failure, or a missing
#     host key, aborts switch-to-configuration before the bootloader or
#     activation is touched, so a host that would come up with no admin
#     password refuses to switch instead. `NIXOS_NO_CHECK=1` skips all
#     pre-switch checks (don't, unless you know why it failed).
#
# The host key must exist before the first activation decrypts anything. On
# the servers sshd made it long ago; Famine runs no sshd at all
# (services.openssh.enable = false). The pre-switch check refuses a switch
# while the key is missing (make it with `sudo ssh-keygen -A` and enroll
# it, docs/famine-sops.md); the activation script below remains as a
# fallback for activations that skip the check (NIXOS_NO_CHECK=1, a fresh
# nixos-install with the check overridden): it makes the key when it is
# missing, without enabling or exposing sshd. It runs before sops-nix's
# setupSecretsForUsers (every host has one: admin's password), which runs
# before `users` and so before setupSecrets. An existing key is never
# touched; sshd, where enabled, uses the same file.
#
# Login passwords (custom.sopsPasswords below): the sops file holds the
# PLAINTEXT password only (one source of truth, readable with
# `sops -d --extract '["<key>"]' <file>`). It is decrypted with
# neededForUsers to /run/secrets-for-users/<key> (ramfs, root 0400), and
# the activation script `sopsPasswordHashes` derives the yescrypt hash from
# it at every activation (`mkpasswd -m yescrypt --stdin`) into
# /run/sops-password-hashes/<user> (root 0600 in a root 0700 directory on
# /run, tmpfs), which is users.users.<user>.hashedPasswordFile. Ordering:
# setupSecretsForUsers -> sopsPasswordHashes -> users (nixpkgs'
# update-users-groups.pl reads hashedPasswordFile there).
# The current /etc/shadow hash is reused when it still matches the
# plaintext, so an unchanged password does not get a new salt every switch.
# If the plaintext is missing or empty (decryption failed), the snippet
# fails the activation loudly and writes the user's PREVIOUS hash from
# /etc/shadow instead, rather than letting `users` lock the account ("!":
# with mutableUsers = false a missing hashedPasswordFile locks it).
# The hashes live in a directory of this module's own, not under
# /run/secrets-for-users: when decryption fails, sops-install-secrets exits
# before it creates the new generation and the /run/secrets-for-users
# symlink (pkgs/sops-install-secrets/main.go, installSecrets:
# decryptSecrets returns before prepareSecretsDir/atomicSymlink), so on a
# fresh boot that path does not exist and nothing could be written there.
# A failing setupSecretsForUsers does not stop the activation (snippets run
# under an ERR trap that only records the status), so this snippet still
# runs after it. With users.mutableUsers = true, nixpkgs applies
# hashedPasswordFile only when it creates the user; an existing user keeps
# its /etc/shadow hash (the file is still written, and a failure is still
# reported).
# Assumes the classic perl `users` activation script: no systemd-sysusers
# and no userborn (asserted; sops-nix would then decrypt in a systemd unit
# instead of setupSecretsForUsers).
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
      # sops-install-secrets from sops-nix's own flake packages, i.e. built
      # with the nixpkgs sops-nix follows (`nixpkgs`, 26.05), not with the
      # host's pkgs: Famine's nixpkgs-unstable is too old for it (its go
      # 1.23 < the go 1.26 sops-nix's go.mod needs). On the servers this is
      # the very same derivation as the default. validationPackage (the
      # manifest check at build time) defaults to this package when not
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
        echo "  docs/famine-sops.md, steps 1-2 (sudo ssh-keygen -A; add its"
        echo "  ssh-to-age recipient to .sops.yaml; sops updatekeys; merge)."
        exit 1
      fi
      home=$(mktemp -d)
      trap 'rm -rf "$home"' EXIT
      failed=0
      for f in ${lib.escapeShellArgs sopsFiles}; do
        # Only the host key: no ~/.config/sops, ~/.ssh or SOPS_AGE_* from
        # the caller's environment. (SOPS_AGE_SSH_PRIVATE_KEY_FILE did not
        # work with sops 3.13; SOPS_AGE_KEY_CMD + ssh-to-age does.)
        if (cd / && env -i HOME="$home" \
          SOPS_AGE_KEY_CMD="${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i $key" \
          ${pkgs.sops}/bin/sops -d "$f" >/dev/null 2>"$home/err"); then
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
        echo "  to .sops.yaml and run sops updatekeys (docs/famine-sops.md, step 2)."
        exit 1
      fi
    '';
  };
}
