"""Root API router — aggregates every endpoint module.

Routes are spec-exact and root-level (no /api/v1 prefix): POST /upload,
POST /ask, POST /extract, plus GET /documents, GET /health and GET /ready.
"""

from fastapi import APIRouter

from app.api.endpoints.ask import router as ask_router
from app.api.endpoints.documents import router as documents_router
from app.api.endpoints.extract import router as extract_router
from app.api.endpoints.health import router as health_router
from app.api.endpoints.ready import router as ready_router
from app.api.endpoints.upload import router as upload_router

router = APIRouter()
router.include_router(health_router)
router.include_router(ready_router)
router.include_router(upload_router)
router.include_router(ask_router)
router.include_router(extract_router)
router.include_router(documents_router)
