"""Fast unit tests - no AWS, no database. Run in CI before the image is built."""

from fastapi.testclient import TestClient

import main

client = TestClient(main.app)


def test_root_reports_version():
    body = client.get("/").json()
    assert body["service"] == "sunshine-app"
    assert "version" in body


def test_healthz_does_not_need_the_database(monkeypatch):
    monkeypatch.delenv("DB_HOST", raising=False)
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
    assert "version" in resp.json()  # public endpoint the smoke test reads


def test_readyz_is_503_without_database(monkeypatch):
    monkeypatch.delenv("DB_HOST", raising=False)
    resp = client.get("/readyz")
    assert resp.status_code == 503


def test_readyz_is_503_when_database_unreachable(monkeypatch):
    monkeypatch.setenv("DB_HOST", "127.0.0.1")
    monkeypatch.setenv("DB_PORT", "1")  # nothing listens here
    monkeypatch.setenv("DB_USER", "x")
    monkeypatch.setenv("DB_PASSWORD", "x")
    monkeypatch.setenv("DB_SSLMODE", "disable")
    resp = client.get("/readyz")
    assert resp.status_code == 503
    assert resp.json()["status"] == "not-ready"


def test_s3_is_503_without_bucket(monkeypatch):
    monkeypatch.delenv("APP_BUCKET", raising=False)
    assert client.get("/s3").status_code == 503


# ---------- identity: forge ALB + Cognito tokens with throw-away keys ----------

import time as _time  # noqa: E402

import jwt  # noqa: E402
import pytest  # noqa: E402
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec, rsa  # noqa: E402

SIGNER_PREFIX = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:loadbalancer/app/k8s-sunshine-"
OUR_ALB = SIGNER_PREFIX + "abc123/50dc6c495c0c9188"
ISSUER = "https://cognito-idp.eu-west-1.amazonaws.com/eu-west-1_Test"
CLIENT = "testclient"

ALB_KEY = ec.generate_private_key(ec.SECP256R1())
COGNITO_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _pem(private_key) -> str:
    return private_key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode()


def _alb_style(token: str) -> str:
    """Re-add base64 padding, like the real ALB does."""
    def pad(part):
        return part + "=" * (-len(part) % 4)
    return ".".join(pad(p) for p in token.split("."))


def _headers(groups=(), signer=OUR_ALB, client=CLIENT, alb_key=ALB_KEY, sub="user-1"):
    now = int(_time.time())
    data = jwt.encode(
        {"sub": sub, "email": "dev@example.com", "exp": now + 60, "iss": ISSUER},
        alb_key,
        algorithm="ES256",
        headers={"kid": "alb-key-1", "signer": signer, "client": client},
    )
    access = jwt.encode(
        {"sub": "user-1", "iss": ISSUER, "exp": now + 60, "token_use": "access",
         "client_id": CLIENT, "cognito:groups": list(groups)},
        COGNITO_KEY,
        algorithm="RS256",
    )
    return {"x-amzn-oidc-data": _alb_style(data), "x-amzn-oidc-accesstoken": access}


@pytest.fixture
def auth_env(monkeypatch):
    monkeypatch.setenv("OIDC_SIGNER_PREFIX", SIGNER_PREFIX)
    monkeypatch.setenv("OIDC_ISSUER", ISSUER)
    monkeypatch.setenv("OIDC_CLIENT_ID", CLIENT)
    monkeypatch.setenv("OIDC_LOGOUT_URL", "https://auth.example.com/logout?client_id=x")
    # No network in unit tests: serve our throw-away public keys instead.
    monkeypatch.setattr(main, "_alb_public_key", lambda region, kid: _pem(ALB_KEY))
    monkeypatch.setattr(main, "_cognito_signing_key", lambda issuer, token: COGNITO_KEY.public_key())


def test_me_returns_verified_identity_and_groups(auth_env):
    body = client.get("/me", headers=_headers(groups=["developer", "viewer"])).json()
    assert body == {"sub": "user-1", "email": "dev@example.com", "groups": ["developer", "viewer"]}


def test_me_without_headers_is_401(auth_env):
    assert client.get("/me").status_code == 401


def test_me_rejects_another_load_balancer(auth_env):
    other = "arn:aws:elasticloadbalancing:eu-west-1:999999999999:loadbalancer/app/evil/1"
    assert client.get("/me", headers=_headers(signer=other)).status_code == 401


def test_me_rejects_a_forged_signature(auth_env):
    forged = _headers(alb_key=ec.generate_private_key(ec.SECP256R1()))
    assert client.get("/me", headers=forged).status_code == 401


def test_me_rejects_mismatched_users(auth_env):
    assert client.get("/me", headers=_headers(sub="someone-else")).status_code == 401


def test_admin_needs_the_admin_group(auth_env):
    assert client.get("/admin", headers=_headers(groups=["developer"])).status_code == 403
    assert client.get("/admin", headers=_headers(groups=["admin"])).status_code == 200


def test_me_is_401_when_sign_in_disabled(monkeypatch):
    monkeypatch.delenv("OIDC_SIGNER_PREFIX", raising=False)
    assert client.get("/me", headers=_headers()).status_code == 401


def test_logout_expires_alb_cookie_and_redirects_to_cognito(auth_env):
    resp = client.get("/logout", follow_redirects=False)
    assert resp.status_code == 302
    assert resp.headers["location"].startswith("https://auth.example.com/logout")
    cookies = resp.headers.get_list("set-cookie")
    assert any(c.startswith("AWSELBAuthSessionCookie-0=") for c in cookies)
