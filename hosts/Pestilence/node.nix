{ pkgs, ... }: {
  systemd.services.sortofasian-io = {
    description = "Personal website";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.nodejs ];
    script = ''
      exec node ${./sortofasian.io}
    '';
  };
}
