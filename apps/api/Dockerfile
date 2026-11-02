# syntax=docker/dockerfile:1

FROM python:3.12-slim AS builder
WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:0.10.6 /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    MODEL_CACHE_DIR=/app/models

COPY pyproject.toml uv.lock* ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev || uv sync --no-dev

COPY . .

# Pre-bake the fastembed models into the image so containers never download
# weights on first request. They live in /app/models, outside /app/data, so
# the data volume (and its backups) only holds uploads + the Chroma store.
RUN --mount=type=cache,target=/root/.cache/uv \
    PYTHONPATH=. .venv/bin/python scripts/prefetch_models.py

# ---- Runtime ----
FROM python:3.12-slim AS runtime
WORKDIR /app

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    tesseract-ocr

# Unprivileged runtime user; fixed uid so volume ownership is predictable.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home-dir /app --no-create-home app \
    && mkdir -p /app/data \
    && chown app:app /app/data

COPY --from=builder /app/.venv /app/.venv
COPY --from=builder --chown=app:app /app/models /app/models
COPY --from=builder /app/app /app/app

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONPATH=/app \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/app/data \
    MODEL_CACHE_DIR=/app/models

USER app

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).status == 200 else 1)"]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
