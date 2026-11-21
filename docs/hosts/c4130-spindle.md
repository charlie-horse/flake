# c4130: Tangled spindle

The CI runner for repositories on the knot ([k8s/apps.md](../k8s/apps.md#tangled-knot)).
Config: `hosts/c4130/spindle.nix` and `tangledSpindle` in
`cluster/definition.nix`; settings reference: upstream's
`docs/src/content/docs/reference/spindle-config.md` at the `tangled`
input's tag.

Rules:

- Workflows run in microVMs only (`image:` names a directory in
  `/var/lib/spindle/images`); nixery (`engine: nixery`) workflows fail,
  because Docker is off.
- Admission stays `closed`: only the owner and the allow-list get CI.
  Allow only people whose code may run on a cluster node.
- Never change `tangledSpindle.host`: it is the spindle's DID
  (`did:web:<host>`), and repositories name it.

## The signing key

sops key `spindle-key` in `secrets/c4130.yaml`: an EC P-256 PEM. c4130
fails to build without it. To create it, on a machine with an admin sops
identity ([../secrets.md](../secrets.md)), on a branch:

```sh
nix shell nixpkgs#sops nixpkgs#openssl nixpkgs#jq
openssl ecparam -name prime256v1 -genkey -noout | jq -Rs . \
  | sops set --value-stdin secrets/c4130.yaml '["spindle-key"]'
```

Never replace it once the spindle has served: other services cache the
public key from its DID document and reject the new one for a while.

## Going live

1. `spindle-key` in `secrets/c4130.yaml` (above), PR, merge.
2. Deploy c4130 ([c4130.md](c4130.md#deploying-c4130)).
3. DNS route for `tangledSpindle.host`
   ([Cloudflare tunnel](../k8s/apps.md#cloudflare-tunnel)).
4. `curl https://spindle.neuros.is/_health`.
5. On tangled.org, signed in as the owner: a repository's Settings →
   Pipelines → select `spindle.neuros.is`. Push a
   `.tangled/workflows/*.yml` to start a run.

## Operating it

The `spindle` command on c4130 runs the admin subcommands with the
service's environment; run it with sudo.

- Let someone use it: `sudo spindle allowlist add <handle or DID>`.
- Usage and limits: `sudo spindle quota usage`.
- Logs: `journalctl -u spindle`; workflow logs in `/var/log/spindle`.
- Back up `/var/lib/spindle/spindle.db` (repository secrets, allow-list,
  quotas).
