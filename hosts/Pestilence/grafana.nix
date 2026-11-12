{ config, ... }: {
  services.grafana = {
    enable = false;
    settings = {
      server = {
        http_port = config.custom.ports.grafana;
        root_url = "https://graph.sortofasian.io";
      };
    };
  };
}
