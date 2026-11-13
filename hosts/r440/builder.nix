# r440 as a Nix remote builder for c4130, over the direct 2x25G link
# (bond0, 10.25.0.0/30); sshd listens everywhere. The binary cache is
# ./cache.nix (https://cache.neuros.is for every host, c4130 included).
{ lib, ... }:
let
  # Public half of c4130's builder key (private half: sops key
  # nixremote-ssh-key in secrets/c4130.yaml; was /root/.ssh/nixremote on
  # c4130). Only `nix-daemon --stdio` may run with it.
  c4130BuilderKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDXr3aoLaBGm+3dzLd3GmtM3URqjiJLX6Wy7Ox6YC3k+ root@c4130";

  # Concurrent builds x cores. Each CUDA tree runs min(NIX_BUILD_CORES, 16)
  # nvcc jobs (flint and, since vLLM fork 23ea1b6, LMCache too), each ~1-2+
  # GiB on CUTLASS kernels. Two trees at 16 nvcc exhausted r440's 46 GiB on
  # 2026-11-04 and hung the box; 2 x 8 caps it at 16 nvcc in total, like
  # 1 x 16, while two builds can still overlap. ./memory.nix caps
  # nix-daemon at 36G as the backstop. Keep maxJobs in c4130's builder.nix
  # equal to this, and builderMaxJobs x cores at 16.
  builderMaxJobs = 2;
in
{
  # --- Direct link -----------------------------------------------------
  # LACP across both cables: one address, survives a cable/port failure,
  # and parallel substitutions/builds hash onto both links (layer3+4).
  networking.bonds.bond0 = {
    interfaces = [
      "ens3f0np0"
      "ens3f1np1"
    ];
    driverOptions = {
      mode = "802.3ad";
      miimon = "100";
      lacp_rate = "fast";
      xmit_hash_policy = "layer3+4";
    };
  };
  networking.interfaces.bond0 = {
    mtu = 9000;
    ipv4.addresses = [
      {
        address = "10.25.0.2";
        prefixLength = 30;
      }
    ];
  };
  # No dhcpcd (IPv4LL) on the link.
  networking.dhcpcd.denyInterfaces = [
    "ens3f*"
    "bond0"
  ];
  # c4130's end of the link as a name for its pinned host key
  # (modules/programs/ssh.nix), e.g. `ssh admin@10.25.0.1`.
  programs.ssh.knownHosts.c4130.hostNames = [ "10.25.0.1" ];

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
    # See builderMaxJobs: max-jobs x cores = 16 nvcc at most.
    cores = 8;
    system-features = [
      "nixos-test"
      "benchmark"
      "big-parallel"
      "kvm"
    ];
  };
  # Builds yield to etcd / the apiserver.
  nix.daemonCPUSchedPolicy = "batch";
  nix.daemonIOSchedClass = "idle";

  # The binary cache (harmonia behind nginx with basic auth) is ./cache.nix.
}
