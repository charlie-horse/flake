# Builds go to r440 over the direct 2x25G link (bond0, 10.25.0.0/30), and
# r440's harmonia cache is the first substituter. Keeps compiles (nvcc,
# nodejs) off this box's RAM, which vLLM + LMCache hold.
{ config, ... }:
let
  r440 = "10.25.0.2";
  # `nix key convert-secret-to-public` output on r440 (see the switch steps).
  r440CacheKey = "r440-cache-1:REPLACE_WITH_R440_CACHE_PUBLIC_KEY=";
in
{
  # --- Direct link -----------------------------------------------------
  networking.bonds.bond0 = {
    interfaces = [ "enp8s0f0np0" "enp8s0f1np1" ];
    driverOptions = {
      mode = "802.3ad";
      miimon = "100";
      lacp_rate = "fast";
      xmit_hash_policy = "layer3+4";
    };
  };
  networking.interfaces.bond0 = {
    mtu = 9000;
    ipv4.addresses = [ { address = "10.25.0.1"; prefixLength = 30; } ];
  };
  networking.dhcpcd.denyInterfaces = [ "enp8s0f*" "bond0" ];
  # r440 may reach the vLLM API over the link (source 10.25.0.2 only);
  # ssh is already open globally.
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -i bond0 -s ${r440} -p tcp \
      --dport ${toString config.services.vllm-sm70.port} -j nixos-fw-accept
  '';

  # --- Remote builder ----------------------------------------------------
  nix.distributedBuilds = true;
  nix.buildMachines = [
    {
      hostName = r440;
      protocol = "ssh-ng";
      sshUser = "nixremote";
      # Generated on c4130 by the user (switch steps); readable by root only.
      sshKey = "/root/.ssh/nixremote";
      # base64 of r440's /etc/ssh/ssh_host_ed25519_key.pub
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUtFQlc0WnFNNnN1VjJLSUxpcVVnUlNPaVhzMTRCdlVhWk5wM2ZrRTNBdUcgcm9vdEByNDQwCg==";
      systems = [ "x86_64-linux" ];
      # Matches r440's builderMaxJobs (its builder.nix).
      maxJobs = 1;
      speedFactor = 4;
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    }
  ];
  nix.settings = {
    # Everything builds on r440; c4130 builds nothing itself. If r440 is
    # down, build with `--option max-jobs 4` (and expect the RAM use).
    max-jobs = 0;
    builders-use-substitutes = true;
    substituters = [ "http://${r440}:5000?priority=30" ];
    trusted-public-keys = [ r440CacheKey ];
  };
}
