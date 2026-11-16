# The OpenSSH client on every host (desktops via modules/, servers via
# modules/server/default.nix).
#
#   /etc/ssh/ssh_config  Host block for the cluster nodes, by NAME only:
#                        User admin, ForwardAgent, IdentitiesOnly and one
#                        public-key IdentityFile per admin sk- key (ssh then
#                        offers that key from the agent). No IPs: c4130's
#                        nix-daemon reaches r440 as nixremote@10.25.0.2 with
#                        its own key (hosts/c4130/builder.nix).
#   ssh_known_hosts      every node's ed25519 host key (cluster/definition.nix)
#   desktops             a per-user ssh-agent; servers use the forwarded one
{
  pkgs,
  lib,
  config,
  options,
  inputs,
  ...
}:
let
  inherit (builtins)
    attrNames
    concatMap
    concatStringsSep
    filter
    ;
  inherit (lib)
    hasPrefix
    imap1
    mapAttrs
    mkAfter
    mkBefore
    mkDefault
    mkIf
    mkMerge
    optionalAttrs
    ;
  cfg = config.programs.ssh;
  # Through inputs.self, like modules/system/nix-cache.nix: on the desktops
  # modules/ is its own store path (modules/default.nix), so a relative
  # path out of it does not resolve.
  cluster = import "${inputs.self}/cluster/definition.nix";

  # The names ssh is called with: the bare node name (MagicDNS search
  # domain) and the FQDN.
  nodeNames = n: [
    n
    "${n}.${cluster.domain}"
  ];

  # admin's FIDO2 keys (`ssh:admin` resident key on the YubiKey), from the
  # same list sshd authorizes (modules/system/admin.nix). Public halves only.
  adminSkKeys = filter (hasPrefix "sk-") config.users.users.admin.openssh.authorizedKeys.keys;
  adminSkKeyFiles = imap1 (
    i: key: pkgs.writeText "admin-sk-${toString i}.pub" "${key}\n"
  ) adminSkKeys;

in
{
  config = {
    assertions = [
      {
        assertion = adminSkKeys != [ ];
        message = "modules/programs/ssh.nix: admin has no sk- authorized key (modules/system/admin.nix) for the cluster Host block's IdentityFile.";
      }
    ];

    programs.ssh.extraConfig = mkMerge [
      # Global options must come before the first Host line (ssh_config
      # applies the first value it finds; extraConfig precedes nixpkgs'
      # `Host *` block).
      (mkAfter ''
        # Cluster nodes (modules/programs/ssh.nix): admin, the YubiKey's
        # ssh:admin key from the agent, agent forwarded for sudo (docs/auth.md).
        Host ${concatStringsSep " " (concatMap nodeNames (attrNames cluster.nodes))}
          User admin
          ForwardAgent yes
          IdentitiesOnly yes
        ${concatStringsSep "\n" (map (f: "  IdentityFile ${f}") adminSkKeyFiles)}
      '')
    ];

    programs.ssh.knownHosts = mapAttrs (name: node: {
      hostNames = nodeNames name ++ [
        node.lanIP
        node.tailnetIP
      ];
      publicKey = node.sshHostKey;
    }) cluster.nodes;

    programs.ssh.startAgent = mkDefault true;
    # nixos-unstable's gnome-keyring (Famine) also enables gcr-ssh-agent by
    # default, and only one SSH agent may run: keep OpenSSH's ssh-agent.
    # The option does not exist in older nixpkgs, hence the check.
    services.gnome = optionalAttrs (options.services.gnome ? gcr-ssh-agent) {
      gcr-ssh-agent.enable = mkIf cfg.startAgent false;
    };
  };
}
