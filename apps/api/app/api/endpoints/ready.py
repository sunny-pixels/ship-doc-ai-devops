"""Readiness check endpoint."""

import tempfile
from pathlib import Path

from fastapi import APIRouter
from fastapi.responses import JSONResponse

from app.config.settings import get_settings
from app.rag import chroma_store

router = APIRouter(tags=["health"])


def _check_data_dir(data_dir: Path) -> str | None:
    """Return an error string if DATA_DIR is missing or not writable, else None."""
    if not data_dir.is_dir():
        return f"{data_dir} does not exist"
    try:
        with tempfile.NamedTemporaryFile(dir=data_dir):
            pass
    except OSError as exc:
        return f"{data_dir} is not writable: {exc.strerror or exc}"
    return None


@router.get("/ready")
async def ready() -> JSONResponse:
    """Readiness probe: the data dir is writable and the vector store opens.

    Unlike ``/health`` (process is up), a failure here means the container
    can't serve uploads or questions yet, so load balancers and deploy
    scripts should hold traffic.
    """
    checks: dict[str, str] = {}

    data_error = _check_data_dir(Path(get_settings().DATA_DIR))
    checks["data_dir"] = data_error or "ok"

    if data_error:
        checks["chroma"] = "skipped"
    else:
        try:
            await chroma_store.ping()
            checks["chroma"] = "ok"
        except Exception as exc:
            checks["chroma"] = f"unavailable: {exc}"

    is_ready = all(value == "ok" for value in checks.values())
    return JSONResponse(
        status_code=200 if is_ready else 503,
        content={"status": "ready" if is_ready else "not_ready", "checks": checks},
    )
