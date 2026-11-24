# Tailscale Service for the Kubernetes API: every controlPlane node
# forwards svc:<cluster.apiserverTailscaleService> to its local apiserver,
# so the tailnet reaches the API by one name. The apiserver certs must list
# that name (cluster.apiserverExtraSANs; asserted below).
#
# A oneshot applies a Services config file (tailscale.com/kb/1589) with
# `tailscale serve set-config --all`. It follows kube-apiserver.service:
# on stop it runs `tailscale serve drain`; on start it advertises again.
# Admin-console setup:
# docs/cluster.md#tailscale-service-for-the-api-svckube-api
{
  config,
  lib,
  pkgs,
  cluster,
  ...
}:
let
  inherit (lib) mkOption types mkIf;
  cfg = config.clusterNode;
  ts = config.services.tailscale;
  # The fallback only keeps the (unused) names below evaluable.
  name = cluster.apiserverTailscaleService or "kube-api";
  svc = "svc:${name}";
  fqdn = "${name}.${cluster.domain}";
  port = toString cluster.apiserverPort;

  serviceConfig = pkgs.writeText "tailscale-service-${name}.json" (
    builtins.toJSON {
      version = "0.0.1";
      services.${svc}.endpoints."tcp:${port}" = "tcp://127.0.0.1:${port}";
    }
  );
in
{
  options.clusterNode.tailscaleService.enable = mkOption {
    type = types.bool;
    default = cluster ? apiserverTailscaleService && lib.elem "controlPlane" cfg.activeRoles;
    defaultText = "cluster.apiserverTailscaleService is set and the node runs the controlPlane role";
    description = ''
      Host the apiserver's Tailscale Service (svc:<cluster.apiserverTailscaleService>)
      on this node, forwarding TCP ${port} to the local kube-apiserver.
    '';
  };

  config = mkIf (cfg.enable && cfg.tailscaleService.enable) {
    assertions = [
      {
        assertion = ts.enable;
        message = "clusterNode.tailscaleService needs services.tailscale.enable.";
      }
      {
        assertion = config.services.kubernetes.apiserver.enable;
        message = "clusterNode.tailscaleService needs a local kube-apiserver.";
      }
      {
        assertion = lib.elem fqdn (cluster.apiserverExtraSANs or [ ]);
        message = ''
          clusterNode.tailscaleService: add "${fqdn}" to
          cluster.apiserverExtraSANs (and re-issue the apiserver leaves),
          or kubectl cannot verify the apiserver's certificate by that name.
        '';
      }
    ];

    systemd.services."tailscale-service-${name}" = {
      description = "Tailscale Service ${svc} (TCP ${port} -> local kube-apiserver)";
      after = [
        "tailscaled.service"
        "tailscaled-autoconnect.service"
        "tailscaled-set.service"
        "kube-apiserver.service"
      ];
      wants = [ "tailscaled.service" ];
      bindsTo = [ "kube-apiserver.service" ];
      upheldBy = [ "kube-apiserver.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        ts.package
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # set-config needs a netmap; at boot tailscaled may still be
        # connecting (the script waits up to 60 s, then systemd retries).
        Restart = "on-failure";
        RestartSec = "15s";
        # Best effort: fails harmlessly when tailscaled is already down.
        ExecStop = "-${lib.getExe ts.package} serve drain ${svc}";
      };
      startLimitIntervalSec = 0;
      script = ''
        for _ in $(seq 60); do
          state=$(tailscale status --json --peers=false | jq -r .BackendState) || state=
          [ "$state" = Running ] && break
          sleep 1
        done
        if [ "$state" != Running ]; then
          echo "tailscaled is not Running (state: ''${state:-unknown})" >&2
          exit 1
        fi
        tailscale serve set-config --all ${serviceConfig}
      '';
    };
  };
}
