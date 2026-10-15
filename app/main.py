"""Sunshine demo app.

Endpoints
  /          who answered: version, task id, AZ (shows load balancing across tasks/AZs)
  /healthz   liveness - process is up. Used by the ALB. Never touches the DB, so a
             DB outage does not make the ALB kill every task (no cascading failure).
  /readyz    readiness - can we reach the DB? Used by the post-deploy smoke test.
  /db        Postgres version, server time and whether this connection uses TLS
  /visits    increments a counter row in Postgres
  /s3        writes an object to the app bucket with the task role, returns the count

Config comes from environment variables. DB_USER / DB_PASSWORD are injected by
ECS from Secrets Manager at task start - they are never in the image or in Git.
"""

import json
import os
import socket
import time
import urllib.request

import psycopg
from fastapi import FastAPI, Response

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
    return {"status": "ok"}


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
