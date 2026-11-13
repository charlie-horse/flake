import shutil

import pytest
import yaml
from conftest import pem
from cryptography.hazmat.primitives.asymmetric import ec

from pki.cli_diff import main, run

CLIENT_STEMS = [
    "addon-manager", "admin", "apiserver-kubelet-client", "controller-manager", "etcd-client-apiserver",
    "flannel", "front-proxy-client", "kube-proxy", "scheduler",
]


def export(src, path, replace=None):
    """Write a secrets/pki/<node>.yaml-style file from a directory, with `replace` certs swapped in."""
    data = {"sops": {"version": "3.11.0"}}
    for p in sorted(src.glob("*.pem")):
        key = p.name.endswith("-key.pem")
        data[p.name] = "ENC[AES256_GCM,data:xx,type:str]" if key else p.read_text()
    for stem, text in (replace or {}).items():
        data[f"{stem}.pem"] = text
    path.write_text(yaml.safe_dump(data))
    return path


@pytest.fixture
def sets(pki, tmp_path):
    specs = pki.write_set(tmp_path / "A", "r440", "cluster-pki")
    pki.write_set(tmp_path / "B", "r440", "cert-manager")
    return tmp_path, specs


def problems(lines):
    return [l for l in lines if not l.startswith(("OK ", "INFO "))]


def test_identical(sets):
    tmp, _ = sets
    lines, status = run(tmp / "A", tmp / "A", "r440")
    assert status == 0 and len(lines) == 14 and all(l.startswith("OK ") for l in lines[:-1])
    assert lines[-1] == "summary (r440): 13 stems, 13 OK, 0 DIFF, 0 MISSING-IN-A, 0 MISSING-IN-B, 0 chain INFO"


def test_cert_manager_export_ok_with_chain_info(sets):
    tmp, _ = sets
    lines, status = run(tmp / "A", export(tmp / "B", tmp / "r440.yaml"), None)
    assert status == 0 and problems(lines) == [lines[-1]]
    assert [l for l in lines if l.startswith("INFO ")] == [
        f"INFO {c}-r440 chain: A=leaf B=leaf+intermediate" for c in CLIENT_STEMS
    ]
    assert lines[-1].endswith("13 stems, 13 OK, 0 DIFF, 0 MISSING-IN-A, 0 MISSING-IN-B, 9 chain INFO")


def test_node_dir_with_bundles(pki, sets):
    tmp, _ = sets
    node = tmp / "node"
    shutil.copytree(tmp / "A", node)
    (node / "ca.pem").write_bytes(pem(pki.cas["k8s"].cert))
    (node / "sa.pub").write_text("not a cert\n")
    pki.write_set(node, "c4130", "cluster-pki")
    lines, status = run(node, tmp / "B", "r440")
    assert status == 0 and lines[-1].startswith("summary (r440): 13 stems, 13 OK")


def test_missing(sets):
    tmp, _ = sets
    (tmp / "B" / "scheduler-r440.pem").unlink()
    (tmp / "A" / "admin-r440.pem").unlink()
    lines, status = run(tmp / "A", tmp / "B", "r440")
    assert status == 1
    assert problems(lines)[:-1] == ["MISSING-IN-A admin-r440", "MISSING-IN-B scheduler-r440"]


def test_three_mutations(pki, sets):
    tmp, specs = sets
    k8s = pki.cas["k8s"]
    api = specs["apiserver-r440"]
    dns = tuple(d + ".evil" if d == "kubernetes.default.svc" else d for d in api.dns)
    mutated = {
        "apiserver-r440": pki.leaf(k8s, api, dns=dns)[0],
        "kubelet-r440": pki.leaf(k8s, specs["kubelet-r440"], eku=("server",))[0],
        "admin-r440": pki.leaf(k8s, specs["admin-r440"], orgs=("system:masters", "extra-group"))[0],
    }
    replace = {s: pem(c, k8s.cert).decode() for s, c in mutated.items()}
    lines, status = run(tmp / "A", export(tmp / "B", tmp / "r440.yaml", replace), None)
    assert status == 1
    assert problems(lines)[:-1] == [
        "DIFF admin-r440 subject: A=- B=O=extra-group",
        "DIFF apiserver-r440 san: A=DNS:kubernetes.default.svc B=DNS:kubernetes.default.svc.evil",
        "DIFF kubelet-r440 eku: A=TLS Web Client Authentication B=-",
    ]
    assert ", 10 OK, 3 DIFF," in lines[-1]


def test_key_issuer_lifetime(pki, sets):
    tmp, specs = sets
    key = ec.generate_private_key(ec.SECP256R1())
    cert, _ = pki.leaf(pki.cas["front-proxy"], specs["scheduler-r440"], key=key, days=300)
    (tmp / "B" / "scheduler-r440.pem").write_bytes(pem(cert))
    lines, status = run(tmp / "A", tmp / "B", "r440")
    diffs = problems(lines)[:-1]
    assert status == 1 and len(diffs) == 3
    assert diffs[0] == "DIFF scheduler-r440 key: A=RSA-2048 B=EC-P256"
    assert diffs[1].startswith("DIFF scheduler-r440 issuer: A=CN=neurosis k8s CA,O=neurosis keyid=")
    assert "B=CN=neurosis front-proxy CA,O=neurosis keyid=" in diffs[1]
    assert diffs[2] == "DIFF scheduler-r440 lifetime: A=365.00d B=300.00d"
    assert "INFO scheduler-r440 chain" not in "\n".join(lines)


def test_input_errors(sets, capsys):
    tmp, _ = sets
    enc = tmp / "r440.yaml"
    enc.write_text(yaml.safe_dump({"admin-r440.pem": "ENC[AES256_GCM,data:xx]"}))
    assert main([str(tmp / "A"), str(enc)]) == 2
    assert "is encrypted" in capsys.readouterr().err
    assert main([str(tmp / "A")]) == 2
    assert main(["--node", "nope", str(tmp / "A"), str(tmp / "B")]) == 2
    assert main([str(tmp / "A"), str(tmp / "missing")]) == 2


def test_main_prints_and_exits(sets, capsys):
    tmp, _ = sets
    assert main(["--node", "r440", str(tmp / "A"), str(tmp / "B")]) == 0
    assert capsys.readouterr().out.splitlines()[-1].endswith("9 chain INFO")
