{
  # TODO: Finish fail2ban setup
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    jails = {
      shadowsocks = ''
        enabled = false
        filter = shadowsocks
        port = 994
        backend = auto
      '';
    };
  };
  environment.etc = {
    "fail2ban/filter.d/shadowsocks.conf".text = ''
      [INCLUDES]
      before = common.conf
      [Definition]
      _daemon = ssserver
      failregex = ^\w+\s+\d+ \d+:\d+:\d+\s+%(__prefix_line)sERROR:\s+failed to handshake with <HOST>: authentication error$
      ignoreregex =
      datepattern = %%Y-%%m-%%d %%H:%%M:%%S
    '';
  };
}
