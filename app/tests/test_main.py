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
    assert resp.json() == {"status": "ok"}


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
