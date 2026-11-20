# Stand-in for authentik's per-provider OIDC issuer: discovery, JWKS and a
# client_credentials token endpoint. The ID token has the claims authentik
# 2025.12 issues to a service account with scope "openid profile": no azp,
# jti, nonce or email; sub is a sha256 hex.
# Usage: mock_idp.py <port> <accounts.json>; accounts: name -> [password, [groups]].
import json
import sys
import time
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

PORT = int(sys.argv[1])
ACCOUNTS = json.load(open(sys.argv[2]))
CLIENT_ID = "ssh-ca"
BASE = f"http://127.0.0.1:{PORT}/application/o/"
ISS = BASE + CLIENT_ID + "/"
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
JWK = json.loads(RSAAlgorithm.to_jwk(KEY.public_key())) | {"kid": "k1", "alg": "RS256", "use": "sig"}


class Handler(BaseHTTPRequestHandler):
    def reply(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == f"/application/o/{CLIENT_ID}/.well-known/openid-configuration":
            self.reply({
                "issuer": ISS,
                "jwks_uri": ISS + "jwks/",
                "token_endpoint": BASE + "token/",
                "authorization_endpoint": BASE + "authorize/",
                "userinfo_endpoint": BASE + "userinfo/",
                "response_types_supported": ["code"],
                "subject_types_supported": ["public"],
                "id_token_signing_alg_values_supported": ["RS256"],
            })
        elif self.path == f"/application/o/{CLIENT_ID}/jwks/":
            self.reply({"keys": [JWK]})
        else:
            self.reply({}, 404)

    def do_POST(self):
        form = parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        get = lambda k: form.get(k, [""])[0]
        account = ACCOUNTS.get(get("username"))
        if (get("grant_type") != "client_credentials" or get("client_id") != CLIENT_ID
                or not account or account[0] != get("password")):
            return self.reply({"error": "invalid_grant"}, 400)
        now = int(time.time())
        claims = {
            "iss": ISS, "aud": CLIENT_ID,
            "sub": hashlib.sha256(get("username").encode()).hexdigest(),
            "iat": now, "auth_time": now, "exp": now + 300, "acr": "goauthentik.io/providers/oauth2/default",
            "preferred_username": get("username"), "name": get("username"), "groups": account[1],
        }
        token = jwt.encode(claims, KEY, algorithm="RS256", headers={"kid": "k1"})
        self.reply({"access_token": token, "id_token": token, "token_type": "Bearer", "expires_in": 300})

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
