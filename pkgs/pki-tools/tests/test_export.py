import base64
import json
import os
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
import yaml

from conftest import make_pki
from pki import cli_export, sopsfile

HERE = os.path.dirname(__file__)
SOPS_YAML = os.environ.get("PKI_TEST_SOPS_YAML", os.path.join(HERE, "..", "..", "..", ".sops.yaml"))
EXPECTED = ["apiserver-r440", "etcd-peer-r440", "front-proxy-client-r440", "kubelet-m2mini"]
SPECS = {
    "apiserver-r440": ("r440", "k8s", "kube-apiserver"),
    "etcd-peer-r440": ("r440", "etcd", "r440"),
    "front-proxy-client-r440": ("r440", "front-proxy", "front-proxy-client"),
    "kubelet-m2mini": ("m2mini", "k8s", "system:node:m2mini"),
}


def recipients_for(node):
    rules = yaml.safe_load(open(SOPS_YAML))["creation_rules"]
    rule = next(r for r in rules if r["path_regex"].startswith(f"^secrets/pki/{node}"))
    return [k for g in rule["key_groups"] for k in g["age"]]


@pytest.fixture
def env(tmp_path, monkeypatch):
    pki = make_pki()
    repo = tmp_path / "repo"
    (repo / "cluster" / "pki").mkdir(parents=True)
    shutil.copy(SOPS_YAML, repo / ".sops.yaml")
    for name, c in [("root", pki.root), ("workload", pki.workload), *pki.intermediates.items()]:
        (repo / "cluster" / "pki" / f"{name}-ca.pem").write_bytes(pki.pem(c))
    monkeypatch.delenv("PKI_LEAVES_JSON", raising=False)
    monkeypatch.setenv("PKI_EXPORT_SECRETS", " ".join(EXPECTED))
    return pki, repo, tmp_path


def secrets(pki, d, overrides=None, drop=()):
    d.mkdir(exist_ok=True)
    for name, (node, ca, cn) in SPECS.items():
        if name in drop:
            continue
        o = (overrides or {}).get(name, {})
        crt, key = pki.leaf(name, node, o.get("ca", ca), o.get("cn", cn), days=o.get("days", 365))
        doc = {"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls",
               "metadata": {"name": name, "namespace": "cluster-pki",
                            "labels": {"pki.neurosis/node": node, "pki.neurosis/ca": ca}},
               "data": {"tls.crt": base64.b64encode(crt).decode(), "tls.key": base64.b64encode(key).decode()}}
        (d / f"{name}.yaml").write_text(yaml.safe_dump(doc))
    return d


def run(secret_dir, repo, out):
    return cli_export.main(["--from-dir", str(secret_dir), "--dry-run", "--repo-dir", str(repo), "--out", str(out)])


def written(out):
    d = out / "secrets" / "pki"
    return sorted(os.listdir(d)) if d.is_dir() else []


def test_happy_then_no_change(env, capsys):
    pki, repo, tmp = env
    s = secrets(pki, tmp / "s")
    assert run(s, repo, tmp / "o1") == 0
    assert written(tmp / "o1") == ["m2mini.yaml", "r440.yaml"]
    for node in ("r440", "m2mini"):
        text = (tmp / "o1" / "secrets" / "pki" / f"{node}.yaml").read_text()
        assert sopsfile.recipients(text) == recipients_for(node)
        data = yaml.safe_load(text)
        assert all(v.startswith("ENC[") for k, v in data.items() if k.endswith("-key.pem"))
        assert all(v.startswith("-----BEGIN CERTIFICATE") for k, v in data.items() if k.endswith("-r440.pem") or k == "kubelet-m2mini.pem")
    shutil.copytree(tmp / "o1" / "secrets", repo / "secrets")
    assert run(s, repo, tmp / "o2") == 0
    assert written(tmp / "o2") == []
    assert "no change: every certificate matches main" in capsys.readouterr().err


@pytest.mark.parametrize("case,overrides,drop,extra,reason,bad", [
    ("missing", {}, (), ["scheduler-m2mini"], "scheduler-m2mini: expected, not in the cluster", "m2mini"),
    ("wrong-ca", {"apiserver-r440": {"ca": "etcd"}}, (), [], "apiserver-r440", "r440"),
    ("other-node", {"kubelet-m2mini": {"cn": "system:node:r440"}}, (), [], "kubelet-m2mini", "m2mini"),
])
def test_rejected_node_skipped(env, capsys, monkeypatch, case, overrides, drop, extra, reason, bad):
    pki, repo, tmp = env
    monkeypatch.setenv("PKI_EXPORT_SECRETS", " ".join(EXPECTED + extra))
    assert run(secrets(pki, tmp / "s", overrides, drop), repo, tmp / "o") == 1
    err = capsys.readouterr().err
    assert f"REJECT {bad}: {reason}" in err and f"SKIP {bad}" in err
    assert f"{bad}.yaml" not in written(tmp / "o") and len(written(tmp / "o")) == 1


def test_workload_chained_rejected(env, capsys):
    pki, repo, tmp = env
    (repo / "cluster" / "pki" / "workload-ca.pem").write_bytes(pki.pem(pki.cross("k8s")))
    assert run(secrets(pki, tmp / "s"), repo, tmp / "o") == 1
    err = capsys.readouterr().err
    assert "workload-ca.pem" in err and "SKIP r440" in err and "SKIP m2mini" in err


def test_expiring_on_main(env, capsys):
    pki, repo, tmp = env
    s = secrets(pki, tmp / "s", {"apiserver-r440": {"days": 7}})
    assert run(s, repo, tmp / "o1") == 0
    shutil.copytree(tmp / "o1" / "secrets", repo / "secrets")
    assert run(s, repo, tmp / "o2") == 1
    assert "EXPIRING within 14 days on main: secrets/pki/r440.yaml apiserver-r440.pem" in capsys.readouterr().err


class _Mock(BaseHTTPRequestHandler):
    prs: list = []

    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        assert self.headers["Authorization"] == "Bearer dummy"
        q = self.path.split("?", 1)[1]
        self._send([p for p in self.prs if "state=all" in q or p["state"] == "open"
                    if "head=" not in q or f"head=charlie-horse%3A{p['head']['ref'].replace('/', '%2F')}" in q])

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        pr = {"number": len(self.prs) + 1, "state": "open", "head": {"ref": body["head"]},
              "html_url": f"mock/pull/{len(self.prs) + 1}"}
        self.prs.append(pr)
        self._send(pr, 201)

    def log_message(self, *a):
        pass


def test_e2e_pr_once(env, capsys, monkeypatch):
    pki, repo, tmp = env
    git = lambda *a: subprocess.run(["git", *a], check=True, capture_output=True)
    git("init", "-q", "-b", "main", str(repo))
    git("-C", str(repo), "add", ".")
    git("-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "seed")
    git("clone", "-q", "--bare", str(repo), str(tmp / "origin.git"))
    (tmp / "token").write_text("dummy\n")
    srv = HTTPServer(("127.0.0.1", 0), _Mock)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    monkeypatch.setenv("GITHUB_API_URL", f"http://127.0.0.1:{srv.server_port}")
    monkeypatch.setenv("PKI_EXPORT_REPO_URL", f"file://{tmp}/origin.git")
    monkeypatch.setenv("PKI_EXPORT_TOKEN_FILE", str(tmp / "token"))
    monkeypatch.setenv("NO_PROXY", "127.0.0.1")
    s = secrets(pki, tmp / "s")
    _Mock.prs = []
    assert cli_export.main(["--from-dir", str(s)]) == 0
    assert cli_export.main(["--from-dir", str(s)]) == 0
    srv.shutdown()
    assert len(_Mock.prs) == 1
    assert "already proposed in mock/pull/1" in capsys.readouterr().err
    heads = git("--git-dir", str(tmp / "origin.git"), "branch", "--list", "pki-renew/*").stdout.decode()
    assert heads.count("pki-renew/") == 1
