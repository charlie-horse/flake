{ pkgs, config, ... }:
let
  inherit (config.age)
    secrets
    ;
in
{
  systemd.timers."lego" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      Persistent = true;
      OnCalendar = "Sunday 3:00";
      Unit = "lego.service";
    };
  };

  systemd.services =
    let
      lego = ''
        ${pkgs.lego}/bin/lego -a \
            -m charliesyvertsen06@icloud.com \
            -d sortofasian.io -d *.sortofasian.io -d *.arr.sortofasian.io \
            --dns cloudflare \
            --path /mutable/ssl \
            --filename sortofasian.io --pem \
      '';
      unitConfig.After = "network-online.target";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = secrets.acme-cloudflare.path;
        User = "haproxy";
        Group = "root";
      };
    in
    {
      "lego-register" = {
        script = "${lego} run";
        inherit serviceConfig;
        unitConfig = unitConfig // {
          ConditionPathExists = "!/mutable/ssl/accounts/*/charliesyvertsen06@icloud.com";
        };
      };
      "lego" = {
        script = "${lego} renew";
        requires = [ "lego-register.service" ];
        inherit serviceConfig unitConfig;
      };
    };
}
