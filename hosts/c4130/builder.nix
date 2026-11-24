# Sends every build to r440 (a Nix remote builder) over the direct link
# (bond0, below). Substitutes come from the binary cache (custom.nixCache
# below), not over the link. docs/build-cache.md.
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
  # Lets r440 reach the vLLM API over the link; ssh is open globally.
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
      # sops key nixremote-ssh-key (secrets/c4130.yaml). Its public half is
      # c4130BuilderKey in hosts/r440/builder.nix.
      sshKey = config.sops.secrets.nixremote-ssh-key.path;
      # base64 of r440's /etc/ssh/ssh_host_ed25519_key.pub
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUtFQlc0WnFNNnN1VjJLSUxpcVVnUlNPaVhzMTRCdlVhWk5wM2ZrRTNBdUcgcm9vdEByNDQwCg==";
      systems = [ "x86_64-linux" ];
      # Must equal builderMaxJobs in hosts/r440/builder.nix (builds x cores
      # at most 16 nvcc on r440; more runs r440 out of RAM).
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
  # Substitutes from the binary cache (modules/system/nix-cache.nix; netrc:
  # sops key nix-cache-netrc). docs/build-cache.md#binary-cache.
  custom.nixCache.enable = true;
  # CUDA redist packages (nvcc, cuBLAS, ...) from nixpkgs' CUDA cache.
  custom.nixCache.cuda.enable = true;
  # Adds the link address to r440's known-hosts entry (from
  # modules/programs/ssh.nix), so root's own ssh over the link (e.g.
  # `nix store ping --store ssh-ng://nixremote@<link address>`) trusts it.
  # The daemon uses publicHostKey above instead.
  programs.ssh.knownHosts.r440.hostNames = [ r440 ];
}
