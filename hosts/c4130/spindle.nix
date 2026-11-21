# Tangled spindle (CI runner for the knot, cluster.tangledSpindle) from
# upstream's nixosModules.spindle (flake input `tangled`). Workflows run in
# QEMU microVMs (KVM, vhost-vsock, slirp4netns with private ranges
# blocked); the nixery engine (Docker) is off.
#
#   https://spindle.neuros.is -> Cloudflare -> cloudflared (any node)
#     -> its nginx sidecar -> http://<c4130 lanIP>:6555 -> spindle
#
# State: /var/lib/spindle (db, repos, images, overlays), logs
# /var/log/spindle. Signing key: sops key spindle-key (secrets/c4130.yaml).
# Operation: docs/hosts/c4130-spindle.md
{
  config,
  lib,
  inputs,
  cluster,
  ...
}:
let
  spindle = cluster.tangledSpindle;
  stateDir = "/var/lib/spindle";

  # Same sources as the cluster ports (modules/cluster/firewall.nix): the
  # cloudflared pods are hostNetwork on every node.
  nodeSources = lib.unique (lib.mapAttrsToList (_: n: n.lanIP) cluster.nodes ++ [ cluster.vip ]);
in
{
  imports = [ inputs.tangled.nixosModules.spindle ];

  # EC P-256 PEM, published in the spindle's did:web document. Read at
  # start.
  sops.secrets.spindle-key = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "spindle.service" ];
  };

  services.tangled.spindle = {
    enable = true;
    server = {
      hostname = spindle.host;
      listenAddr = "0.0.0.0:${toString spindle.port}";
      owner = cluster.tranquilPds.adminDid;
      # Only the owner and the allow-list (`spindle allowlist add`).
      admission = "closed";
      maxJobCount = 2;
    };
    keyPath = config.sops.secrets.spindle-key.path;
    contact.email = spindle.contactEmail;
    # Logs and artifacts on disk, not S3.
    artifactStores.s3.bucket = "";
    pipelines = {
      workflowTimeout = "30m";
      microvm = {
        overlayDir = "${stateDir}/overlays";
        # vLLM and LMCache hold most of this host's RAM.
        limits.total = {
          memoryMiB = 8192;
          vcpus = 8;
          diskMiB = 65536;
        };
        cgroup.enable = true;
      };
    };
  };

  # Upstream's module turns Docker on for the nixery engine. Not here: no
  # second container runtime or its iptables rules on a cluster node.
  virtualisation.docker.enable = lib.mkForce false;

  systemd.tmpfiles.rules = [
    "d ${stateDir}/images 0755 root root - -"
    "d ${stateDir}/overlays 0700 root root - -"
    # Workflows without `image:` get the module's default image `nixos`.
    "L+ ${stateDir}/images/nixos - - - - ${inputs.tangled.packages.x86_64-linux.spindle-nixos-image}"
  ];

  networking.firewall.extraCommands = lib.concatMapStrings (src: ''
    iptables -A nixos-fw -p tcp -s ${src} --dport ${toString spindle.port} -j nixos-fw-accept
  '') nodeSources;
}
