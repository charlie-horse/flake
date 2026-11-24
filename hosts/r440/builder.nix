# r440 as a Nix remote builder (a host that runs builds for another) for
# c4130, over the direct link (bond0, below). The binary cache is
# ./cache.nix. docs/build-cache.md#remote-builder.
{ lib, ... }:
let
  # Public half of c4130's builder key (private half: sops key
  # nixremote-ssh-key in secrets/c4130.yaml). Only `nix-daemon --stdio` may run with it.
  c4130BuilderKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDXr3aoLaBGm+3dzLd3GmtM3URqjiJLX6Wy7Ox6YC3k+ root@c4130";

  # Concurrent builds. Each CUDA build (flint, LMCache) runs up to `cores`
  # nvcc jobs at 1-2+ GiB each. Keep builderMaxJobs x cores at 16 or less,
  # or the builds run this host out of RAM, and keep maxJobs in
  # hosts/c4130/builder.nix equal to this. ./memory.nix caps nix-daemon's
  # memory as the backstop.
  builderMaxJobs = 2;
in
{
  # --- Direct link -----------------------------------------------------
  # LACP bond (two cables as one link with one address): it survives a
  # cable or port failure and spreads connections over both cables.
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
  # Adds c4130's link address to its pinned host key
  # (modules/programs/ssh.nix), so `ssh admin@<link address>` trusts it.
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

  # Builds for c4130 fetch their inputs here (builders-use-substitutes),
  # including CUDA packages from nixpkgs' CUDA cache.
  custom.nixCache.cuda.enable = true;

  # The binary cache (harmonia behind nginx with basic auth) is ./cache.nix.
}
