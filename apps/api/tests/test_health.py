"""Tests for the liveness (/health) and readiness (/ready) probes."""

from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config.settings import get_settings
from app.main import app
from app.rag import chroma_store


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Iterator[TestClient]:
    """App client with DATA_DIR pointed at a fresh temp dir and no cached
    settings or Chroma client leaking between tests."""
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    get_settings.cache_clear()
    monkeypatch.setattr(chroma_store, "_client", None)
    with TestClient(app) as test_client:
        yield test_client
    get_settings.cache_clear()


def test_health_ok(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_ready_ok(client: TestClient) -> None:
    response = client.get("/ready")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ready"
    assert body["checks"] == {"data_dir": "ok", "chroma": "ok"}


def test_ready_fails_when_data_dir_missing(
    client: TestClient, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "missing"))
    get_settings.cache_clear()

    response = client.get("/ready")
    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "not_ready"
    assert "does not exist" in body["checks"]["data_dir"]
    assert body["checks"]["chroma"] == "skipped"


def test_ready_fails_when_chroma_unavailable(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def broken_ping() -> None:
        raise RuntimeError("store is corrupt")

    monkeypatch.setattr(chroma_store, "ping", broken_ping)

    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json()["checks"]["chroma"] == "unavailable: store is corrupt"
