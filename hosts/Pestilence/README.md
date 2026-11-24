# Pestilence (archived)

Config of an archived host. It is not a flake output: nothing builds or
checks it. Before restoring it, move the plaintext Transmission
`rpc-password` in `servarr.nix` out of git into sops
([docs/secrets.md](../../docs/secrets.md)).
