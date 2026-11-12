let
  Yubikey-5 = "age1yubikey1qdktg07nccs3yfn8zed07vj8sur36tjxztv66qrzvdzn9e7nlght5fuv28f";
  Yubikey-5c = "age1yubikey1qwkqxsgmxgsqjl2pkr5g6vlyeuj5vvnrxehfr9ucyqfsd2nlxryzx5w7ud9";
  Backup = "age189g2yhhp60e8z2x47shq6mv0reg4z9dvpggxtt0x04ufvaq0gajs3g2vr2";
  masterKeys = [
    Yubikey-5c
    Yubikey-5
    Backup
  ];

  Famine = [ "age1nm72rl5qvmxlame9szcv24urufnzcqyf952tcsjmzjxx2pc57eesdh3x3s" ] ++ masterKeys;
  War = [ "age152q033p8wej0v0833yv45hf85f4e69dd925zshgktccxndptpdvq75dpvf" ] ++ masterKeys;
  Pestilence = [ "age1c7l2afugswu44qxnxyp840avxul6dheljtu6rjx7xfpmkqwxud8skevzg2" ] ++ masterKeys;
  Death = [ "age1v3ag7vy63cm5cyc66ajmux8y4w3rudmc0gd3np0xtm4qv44feqvqwg48yh" ] ++ masterKeys;
  allSystems = Famine ++ War ++ Pestilence ++ Death;
in
{
  "login.age".publicKeys = allSystems;
  "pam-yubikeys.age".publicKeys = allSystems;
  "ssh-yubikey-5.age".publicKeys = allSystems;
  "ssh-yubikey-5c.age".publicKeys = allSystems;

  "key-pestilence.age".publicKeys = Pestilence;
  "vpn-privkey.age".publicKeys = Pestilence;
  "vpn-password.age".publicKeys = Pestilence;
  "acme-cloudflare.age".publicKeys = Pestilence;

  "key-famine.age".publicKeys = Famine;
  # netrc for https://cache.neuros.is (modules/system/nix-cache.nix).
  "nix-cache-netrc.age".publicKeys = Famine;
}
