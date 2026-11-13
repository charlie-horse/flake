# The OpenSSH client on every host: desktops get it with modules/
# wholesale (lib/system/mkHost.nix), the servers through
# modules/server/default.nix. Client how-to: docs/cluster.md, "SSH between
# the hosts".
#
#   /etc/ssh/ssh_config  a Host block for the cluster nodes, by name only
#                        (c4130, r440, m2mini and their MagicDNS FQDNs):
#                        User admin, ForwardAgent yes, IdentitiesOnly yes and
#                        one IdentityFile per sk- key admin is authorized
#                        with (modules/system/admin.nix). Those files hold
#                        the PUBLIC key only: with IdentitiesOnly, ssh offers
#                        exactly that key from the agent (local or forwarded;
#                        ssh_config(5), IdentityFile: "You can also specify a
#                        public key file to use the corresponding private key
#                        that is loaded in ssh-agent(1) when the private key
#                        file is not present locally"). No key-handle stub
#                        (an OPENSSH PRIVATE KEY file) is deployed: the
#                        agent makes it unnecessary, and CI's secrets guard
#                        rejects one. On a machine with the YubiKey plugged
#                        in, `ssh-add -K` (or `ssh-keygen -K` + `ssh-add`)
#                        loads the resident key into the agent.
#                        IP addresses are left out on purpose: c4130's
#                        nix-daemon reaches r440 as nixremote@10.25.0.2 with
#                        its own key (hosts/c4130/builder.nix), and this
#                        block must not add identities or agent forwarding
#                        there.
#   ssh_known_hosts      every node's ed25519 host key
#                        (cluster/definition.nix, nodes.<n>.sshHostKey) for
#                        its name, FQDN, LAN and tailnet address; host
#                        configs add more names (the bond0 link,
#                        hosts/*/builder.nix).
#   desktops             a per-user ssh-agent (programs.ssh.startAgent; the
#                        servers turn it off in modules/server/default.nix,
#                        they use the forwarded agent).
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
