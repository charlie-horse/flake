# Builds go to r440 over the direct 2x25G link (bond0, 10.25.0.0/30).
# Keeps compiles (nvcc, nodejs) off this box's RAM, which vLLM + LMCache
# hold. Substitution from r440's cache goes through https://cache.neuros.is
# (custom.nixCache below), not the link.
{ config, ... }:
let
  r440 = "10.25.0.2";
in
{
  # --- Direct link -----------------------------------------------------
  networking.bonds.bond0 = {
    interfaces = [
      "enp8s0f0np0"
      "enp8s0f1np1"
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
        address = "10.25.0.1";
        prefixLength = 30;
      }
    ];
  };
  networking.dhcpcd.denyInterfaces = [
    "enp8s0f*"
    "bond0"
  ];
  # r440 may reach the vLLM API over the link (source 10.25.0.2 only);
  # ssh is already open globally.
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -i bond0 -s ${r440} -p tcp \
      --dport ${toString config.services.vllm-sm70.port} -j nixos-fw-accept
  '';

  # --- Remote builder ----------------------------------------------------
  # OpenSSH private key (ed25519, the whole `-----BEGIN OPENSSH PRIVATE
  # KEY-----` file, with its trailing newline). The nix-daemon's ssh reads
  # it on every connection: no restart needed.
  sops.secrets.nixremote-ssh-key = {
    owner = "root";
    group = "root";
    mode = "0600";
  };
  nix.distributedBuilds = true;
  nix.buildMachines = [
    {
      hostName = r440;
      protocol = "ssh-ng";
      sshUser = "nixremote";
      # sops key nixremote-ssh-key (secrets/c4130.yaml), root 0600; was
      # /root/.ssh/nixremote (generated on c4130). Its public half is
      # c4130BuilderKey in hosts/r440/builder.nix.
      sshKey = config.sops.secrets.nixremote-ssh-key.path;
      # base64 of r440's /etc/ssh/ssh_host_ed25519_key.pub
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUtFQlc0WnFNNnN1VjJLSUxpcVVnUlNPaVhzMTRCdlVhWk5wM2ZrRTNBdUcgcm9vdEByNDQwCg==";
      systems = [ "x86_64-linux" ];
      # Matches r440's builderMaxJobs (its builder.nix): 2 builds x 8
      # cores, so at most 16 nvcc on r440 (2 x 16 ran it out of RAM).
      maxJobs = 2;
      speedFactor = 4;
      supportedFeatures = [
        "nixos-test"
        "benchmark"
        "big-parallel"
        "kvm"
      ];
    }
  ];
  nix.settings = {
    # Everything builds on r440; c4130 builds nothing itself. If r440 is
    # down, build with `--option max-jobs 4` (and expect the RAM use).
    max-jobs = 0;
    builders-use-substitutes = true;
  };
  # Substitutes from r440 through https://cache.neuros.is like every other
  # host (modules/system/nix-cache.nix; netrc: sops key nix-cache-netrc,
  # formerly /var/lib/nix-cache/netrc), no longer over the link. To go
  # back to the direct path, revert commit 6e02db6 (it also restores
  # harmonia's 10.25.0.2:5000).
  custom.nixCache.enable = true;
  # Root's own ssh (e.g. `nix store ping --store ssh-ng://nixremote@10.25.0.2`)
  # needs r440's host key too; the daemon uses publicHostKey above.
  programs.ssh.knownHosts.r440-builder = {
    hostNames = [ r440 ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKEBW4ZqM6suV2KILiqUgRSOiXs14BvUaZNp3fkE3AuG";
  };
}
