"""Sunshine demo app.

Endpoints
  /          who answered: version, task id, AZ (shows load balancing across tasks/AZs)
  /healthz   liveness - process is up. Used by the ALB. Never touches the DB, so a
             DB outage does not make the ALB kill every task (no cascading failure).
  /readyz    readiness - can we reach the DB? Used by the post-deploy smoke test.
  /db        Postgres version, server time and whether this connection uses TLS
  /visits    increments a counter row in Postgres
  /s3        writes an object to the app bucket with the task role, returns the count
  /me        who is signed in (ALB + Cognito), after verifying the ALB's signature
  /admin     only for the Cognito group "admin" - app-level authorisation
  /logout    ends the ALB session and the Cognito session

Config comes from environment variables. DB_USER / DB_PASSWORD are injected by
ECS from Secrets Manager at task start - they are never in the image or in Git.
"""

import functools
import json
import os
import socket
import time
import urllib.request

import jwt
import psycopg
from fastapi import FastAPI, Header, HTTPException, Response
from fastapi.responses import RedirectResponse

VERSION = os.getenv("APP_VERSION", "dev")

app = FastAPI(title="sunshine-app", version=VERSION)


def _task_metadata() -> dict:
    """Task id and AZ from the ECS task metadata endpoint (empty outside ECS)."""
    uri = os.getenv("ECS_CONTAINER_METADATA_URI_V4")
    if not uri:
        return {}
    try:
        with urllib.request.urlopen(f"{uri}/task", timeout=1) as resp:
            task = json.load(resp)
        return {
            "task": task["TaskARN"].rsplit("/", 1)[-1],
            "az": task.get("AvailabilityZone"),
        }
    except Exception:  # metadata is nice-to-have, never fatal
        return {}


TASK = _task_metadata()


def _db_configured() -> bool:
    return bool(os.getenv("DB_HOST") and os.getenv("DB_PASSWORD"))


def _connect() -> psycopg.Connection:
    # sslmode=verify-full: encrypt AND verify the server certificate against the
    # RDS CA bundle baked into the image, so a spoofed endpoint is rejected.
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=int(os.getenv("DB_PORT", "5432")),
        dbname=os.getenv("DB_NAME", "app"),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode=os.getenv("DB_SSLMODE", "verify-full"),
        sslrootcert=os.getenv("DB_SSLROOTCERT", "/app/rds-ca.pem"),
        connect_timeout=3,
        application_name="sunshine-app",
    )


@app.get("/")
def root() -> dict:
    return {
        "service": "sunshine-app",
        "version": VERSION,
        "host": socket.gethostname(),
        **TASK,
    }


@app.get("/healthz")
def healthz() -> dict:
    # version here too: "/" sits behind sign-in, /healthz is public, so the
    # post-deploy smoke test reads the deployed version from here.
    return {"status": "ok", "version": VERSION}


@app.get("/readyz")
def readyz(response: Response) -> dict:
    if not _db_configured():
        response.status_code = 503
        return {"status": "not-ready", "db": "not configured"}
    started = time.monotonic()
    try:
        with _connect() as conn:
            conn.execute("select 1")
    except Exception as exc:
        response.status_code = 503
        return {"status": "not-ready", "db": type(exc).__name__}
    return {"status": "ready", "db": "ok", "ms": round((time.monotonic() - started) * 1000)}


@app.get("/db")
def db(response: Response) -> dict:
    if not _db_configured():
        response.status_code = 503
        return {"error": "database not configured"}
    with _connect() as conn:
        version, now, tls = conn.execute(
            "select version(), now(),"
            " (select ssl from pg_stat_ssl where pid = pg_backend_pid())"
        ).fetchone()
    return {"postgres": version, "server_time": now.isoformat(), "tls": tls}


@app.get("/visits")
def visits(response: Response) -> dict:
    if not _db_configured():
        response.status_code = 503
        return {"error": "database not configured"}
    with _connect() as conn:
        conn.execute(
            "create table if not exists visits ("
            " id int primary key, count bigint not null default 0)"
        )
        (count,) = conn.execute(
            "insert into visits (id, count) values (1, 1)"
            " on conflict (id) do update set count = visits.count + 1"
            " returning count"
        ).fetchone()
    return {"visits": count, **TASK}


@app.get("/s3")
def s3(response: Response) -> dict:
    bucket = os.getenv("APP_BUCKET")
    if not bucket:
        response.status_code = 503
        return {"error": "bucket not configured"}
    import boto3  # imported lazily: only this endpoint needs it

    client = boto3.client("s3")
    key = f"visits/{int(time.time() * 1000)}-{socket.gethostname()}.txt"
    client.put_object(Bucket=bucket, Key=key, Body=f"hello from {VERSION}\n".encode())
    listed = client.list_objects_v2(Bucket=bucket, Prefix="visits/")
    return {"bucket": bucket, "wrote": key, "objects": listed.get("KeyCount", 0)}


# ---------- identity (ALB authenticates, the app verifies and authorises) ----------
# The ALB forwards two headers after a Cognito sign-in:
#   x-amzn-oidc-data         user claims (sub, email), signed by the ALB (ES256)
#   x-amzn-oidc-accesstoken  Cognito access token, signed by Cognito (RS256),
#                            carries "cognito:groups"
# Headers are just text: verify both signatures, never trust them blindly. The
# NetworkPolicy (only load balancer subnets reach the pod) is the outer layer.


@functools.lru_cache(maxsize=16)
def _alb_public_key(region: str, kid: str) -> str:
    """ALB signing keys are published per key id (PEM), not as a JWKS."""
    url = f"https://public-keys.auth.elb.{region}.amazonaws.com/{kid}"
    with urllib.request.urlopen(url, timeout=3) as resp:
        return resp.read().decode()


@functools.lru_cache(maxsize=4)
def _cognito_jwks(issuer: str) -> jwt.PyJWKClient:
    return jwt.PyJWKClient(f"{issuer}/.well-known/jwks.json", cache_keys=True)


def _cognito_signing_key(issuer: str, token: str):
    return _cognito_jwks(issuer).get_signing_key_from_jwt(token).key


def _unauthorised(reason: str) -> HTTPException:
    return HTTPException(status_code=401, detail=f"not authenticated: {reason}")


def _identity(oidc_data: str | None, access_token: str | None) -> dict:
    signer_prefix = os.getenv("OIDC_SIGNER_PREFIX")
    issuer = os.getenv("OIDC_ISSUER")
    client_id = os.getenv("OIDC_CLIENT_ID")
    if not (signer_prefix and issuer and client_id):
        raise _unauthorised("sign-in is not enabled for this deployment")
    if not (oidc_data and access_token):
        raise _unauthorised("no identity headers")

    # 1) user claims, signed by OUR ALB. ALB tokens keep base64 "=" padding,
    #    which JWT forbids - PyJWT then reports a bad SIGNATURE. Strip it first.
    oidc_data = ".".join(part.rstrip("=") for part in oidc_data.split("."))
    try:
        header = jwt.get_unverified_header(oidc_data)
        if not header.get("kid"):
            raise _unauthorised("ALB token has no key id")
        if not str(header.get("signer", "")).startswith(signer_prefix):
            raise _unauthorised("signed by an unknown load balancer")
        if header.get("client") != client_id:
            raise _unauthorised("issued for another client")
        region = header["signer"].split(":")[3]
        claims = jwt.decode(
            oidc_data, _alb_public_key(region, header["kid"]), algorithms=["ES256"]
        )
    except jwt.PyJWTError as exc:
        raise _unauthorised(f"bad ALB token ({type(exc).__name__})") from exc

    # 2) groups, from the access token signed by OUR Cognito pool for OUR client
    try:
        access = jwt.decode(
            access_token,
            _cognito_signing_key(issuer, access_token),
            algorithms=["RS256"],
            issuer=issuer,
            options={"require": ["exp", "iss", "sub"]},
        )
    except jwt.PyJWTError as exc:
        raise _unauthorised(f"bad access token ({type(exc).__name__})") from exc
    if access.get("token_use") != "access" or access.get("client_id") != client_id:
        raise _unauthorised("access token is not for this app")
    if access["sub"] != claims.get("sub"):
        raise _unauthorised("tokens belong to different users")

    return {
        "sub": claims["sub"],
        "email": claims.get("email"),
        "groups": sorted(access.get("cognito:groups", [])),
    }


@app.get("/me")
def me(
    x_amzn_oidc_data: str | None = Header(default=None),
    x_amzn_oidc_accesstoken: str | None = Header(default=None),
) -> dict:
    return _identity(x_amzn_oidc_data, x_amzn_oidc_accesstoken)


@app.get("/admin")
def admin(
    x_amzn_oidc_data: str | None = Header(default=None),
    x_amzn_oidc_accesstoken: str | None = Header(default=None),
) -> dict:
    user = _identity(x_amzn_oidc_data, x_amzn_oidc_accesstoken)
    if "admin" not in user["groups"]:
        # 403, not 401: we know who you are, you just may not do this.
        raise HTTPException(status_code=403, detail="admin group required")
    return {"admin": True, "user": user["email"], **TASK}


@app.get("/logout")
def logout() -> Response:
    """The ALB has no logout: expire its session cookie (split into up to 4
    shards), then let Cognito end its own session and send the browser back."""
    target = os.getenv("OIDC_LOGOUT_URL") or "/"
    response = RedirectResponse(target, status_code=302)
    for shard in range(4):
        response.delete_cookie(f"AWSELBAuthSessionCookie-{shard}", path="/", secure=True)
    return response

