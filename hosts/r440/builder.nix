# r440 as a Nix remote builder and binary cache for c4130, over the direct
# 2x25G link (bond0, 10.25.0.0/30). The cache binds to the link address
# only (and ./firewall.nix opens 5000 on bond0 only); sshd listens everywhere.
{ lib, ... }:
let
  # c4130 root's builder key: /root/.ssh/nixremote.pub on c4130 (see the
  # switch steps). Only `nix-daemon --stdio` may run with it.
  c4130BuilderKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDXr3aoLaBGm+3dzLd3GmtM3URqjiJLX6Wy7Ox6YC3k+ root@c4130";

  # Concurrent builds. One CUDA tree build peaks ~14 GiB at 16 cores.
  # 1 while Ken's SWE-bench podman run shares r440's 46 GiB (started
  # 2026-10-31, ~35 h). Raise to 2 once that run is over (and set
  # maxJobs = 2 in c4130's builder.nix to match).
  builderMaxJobs = 1;
in
{
  # --- Direct link -----------------------------------------------------
  # LACP across both cables: one address, survives a cable/port failure,
  # and parallel substitutions/builds hash onto both links (layer3+4).
  networking.bonds.bond0 = {
    interfaces = [ "ens3f0np0" "ens3f1np1" ];
    driverOptions = {
      mode = "802.3ad";
      miimon = "100";
      lacp_rate = "fast";
      xmit_hash_policy = "layer3+4";
    };
  };
  networking.interfaces.bond0 = {
    mtu = 9000;
    ipv4.addresses = [ { address = "10.25.0.2"; prefixLength = 30; } ];
  };
  # No dhcpcd (IPv4LL) on the link.
  networking.dhcpcd.denyInterfaces = [ "ens3f*" "bond0" ];

  # --- Remote builder ----------------------------------------------------
  users.users.nixremote = {
    isSystemUser = true;
    group = "nixremote";
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [
      ''command="nix-daemon --stdio",restrict ${c4130BuilderKey}''
    ];
  };
  users.groups.nixremote = { };

  nix.settings = {
    trusted-users = [ "nixremote" ];
    max-jobs = builderMaxJobs;
    cores = 16;
    system-features = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
  };
  # Builds yield to etcd / the apiserver.
  nix.daemonCPUSchedPolicy = "batch";
  nix.daemonIOSchedClass = "idle";

  # --- Binary cache --------------------------------------------------------
  # Signing key generated on r440 (never leaves it): see the switch steps.
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ "/var/lib/secrets/harmonia.secret" ];
    # Lower than cache.nixos.org (40), so c4130 asks r440 first.
    settings.priority = 30;
    settings.bind = "10.25.0.2:5000";
  };
  # Bind even before bond0 has its address.
  systemd.sockets.harmonia.socketConfig.FreeBind = true;
}
