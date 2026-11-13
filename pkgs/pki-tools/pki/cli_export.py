import argparse
import hashlib
import os
import sys
import tempfile
from datetime import datetime, timezone

from . import certs, kube, leaves, sopsfile
from .github import Api, Git
from .validate import EXPIRY, expiring_on_main, fingerprints, leaf_errors, load_cas

NAMESPACE = "cluster-pki"


def log(msg: str) -> None:
    print(f"pki-export: {msg}", file=sys.stderr)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="pki-export")
    ap.add_argument("--from-dir", help="read Secrets from *.yaml files instead of the cluster")
    ap.add_argument("--dry-run", action="store_true", help="write files to --out; no git, no API")
    ap.add_argument("--repo-dir", default=".", help="dry run: checkout to read .sops.yaml and main from")
    ap.add_argument("--out", default="./pki-export-out")
    a = ap.parse_args(argv)
    now = datetime.now(timezone.utc)
    exp = leaves.expected()
    if not exp:
        raise SystemExit("pki-export: error: no expected leaves (PKI_LEAVES_JSON / PKI_EXPORT_SECRETS)")
    nodes = leaves.nodes(exp)
    objs = kube.from_dir(a.from_dir) if a.from_dir else kube.from_cluster(NAMESPACE, list(exp))
    found = kube.leaves(objs, NAMESPACE)
    if not found:
        raise SystemExit(f"pki-export: error: no Secrets labelled {kube.NODE_LABEL} in {NAMESPACE}")
    repo = os.environ.get("GITHUB_REPOSITORY", "charlie-horse/flake")
    work = tempfile.TemporaryDirectory(prefix="pki-export.")
    if a.dry_run:
        tree, token = a.repo_dir, ""
        log(f"dry run: reading {tree}, writing to {a.out} (no git, no API)")
    else:
        token = open(os.environ.get("PKI_EXPORT_TOKEN_FILE", "/var/run/secrets/pki-export-github/token")).read().strip()
        if not token:
            raise SystemExit("pki-export: error: the token file is empty")
        tree = os.path.join(work.name, "repo")
        Git(tree, token).clone(os.environ.get("PKI_EXPORT_REPO_URL", f"https://github.com/{repo}.git"), "main")
    expiring = expiring_on_main(tree, now)
    cas = load_cas(tree)
    bad = {n for n in {l.node for l in found} if n not in nodes}
    for n in sorted(bad):
        log(f"REJECT {n}: Secrets for a node with no expected leaves")
    staged, changed = {}, []
    for node in nodes:
        mine = [l for l in found if l.node == node]
        errs = [f"{n}: expected, not in the cluster"
                for n, e in exp.items() if e["node"] == node and n not in {l.name for l in mine}]
        errs += [f"{l.name}: {e}" for l in mine for e in leaf_errors(l, exp, cas, nodes, now)]
        base = fingerprints(sopsfile.certs(os.path.join(tree, "secrets", "pki", f"{node}.yaml")))
        files = {f"{l.name}{suffix}": data for l in mine for suffix, data in ((".pem", l.crt), ("-key.pem", l.key))}
        new = fingerprints(files) if not errs else {}
        errs += [f"{k}: on main but not in the cluster" for k in base if not errs and k not in new]
        if errs:
            for e in errs:
                log(f"REJECT {node}: {e}")
            log(f"SKIP {node}: failed the checks above; nothing proposed for it")
            bad.add(node)
        elif new == base:
            log(f"{node}: no change")
        else:
            staged[node] = (files, new, base)
            changed.append(node)

    def finish() -> int:
        for e in expiring:
            log(f"EXPIRING within {EXPIRY.days} days on main: {e}")
        return 1 if bad or expiring else 0

    if not changed:
        log("no change: every certificate matches main")
        return finish()
    lines = sorted(f"{n}/{k} {fp}" for n in changed for k, fp in staged[n][1].items())
    digest = hashlib.sha256("\n".join(lines).encode()).hexdigest()[:12]
    branch = f"pki-renew/{now:%Y-%m-%d}-{digest}"
    title = f"pki: renewed host certificates ({' '.join(changed)})"
    log(f"changed: {' '.join(changed)} (set {digest})")
    rows = []
    for n in changed:
        files, new, base = staged[n]
        for k, fp in sorted(new.items()):
            if base.get(k) != fp:
                c = certs.load_chain(files[k])[0]
                rows.append(f"| {n} | `{k}` | `{c.subject.rfc4514_string()}` | {c.not_valid_after_utc} | `{fp}` |")
    body = "\n".join([
        f"Certificates renewed by cert-manager in `{NAMESPACE}`, exported by pki-export.",
        "Only the `-key.pem` values are encrypted (recipients: admins + that host).", "",
        "| Node | File | Subject | Not after | SHA-256 |", "| --- | --- | --- | --- | --- |", *rows, "",
        "After merge, on each host listed: `cd /etc/nixos && git pull && "
        "sudo nixos-rebuild switch --flake /etc/nixos#<host>`.", "", f"<!-- pki-export set={digest} -->", ""])
    dest = os.path.join(a.out if a.dry_run else tree, "secrets", "pki")
    os.makedirs(dest, exist_ok=True)

    def write_files():
        for n in changed:
            with open(os.path.join(dest, f"{n}.yaml"), "w") as f:
                f.write(sopsfile.encrypt(tree, n, staged[n][0]))

    if a.dry_run:
        write_files()
        open(os.path.join(a.out, "pr-body.md"), "w").write(body)
        log(f"would push {branch} and open a PR (body: {a.out}/pr-body.md)")
        return finish()
    git, api = Git(tree, token), Api(repo, token)
    existing = git.remote_branches(f"pki-renew/*-{digest}")
    if existing:
        prs = api.pulls("all", existing[0])
        done = [p for p in prs if p["state"] == "open"] or [p for p in prs if p["state"] == "closed"]
        if done:
            log(f"this set is already proposed in {done[0]['html_url']} ({done[0]['state']}); nothing to do")
            return finish()
        branch = existing[0]
        log(f"branch {branch} exists without a PR; opening one")
    else:
        write_files()
        git.commit_push(branch, ["secrets/pki"], title,
                        f"Exported from cert-manager (namespace {NAMESPACE}) by pki-export; set {digest}.")
        log(f"pushed {branch}")
    others = [f"#{p['number']}" for p in api.pulls("open") if p["head"]["ref"].startswith("pki-renew/")]
    if others:
        body += f"\nSupersedes (close after merging this): {' '.join(others)}\n"
    log(f"opened {api.create_pull(title, branch, 'main', body)['html_url']}")
    return finish()


if __name__ == "__main__":
    sys.exit(main())
