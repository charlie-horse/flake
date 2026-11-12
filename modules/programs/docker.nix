{ config, ... }: {
  config = {
    virtualisation.docker = {
      enable = true;
      rootless.enable = true;
      rootless.setSocketVariable = true;
    };
  };
}
