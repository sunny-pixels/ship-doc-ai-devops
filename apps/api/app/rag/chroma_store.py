"""Embedded ChromaDB vector store — a single ``documents`` collection, cosine
space. ``PersistentClient`` is sync, so every call goes through
``asyncio.to_thread`` (a sync client wrapped for use in an async app).
No Docker/server required — the whole store lives under ``DATA_DIR/chroma``.
"""

import asyncio
import threading
from dataclasses import dataclass
from typing import Any

import chromadb
from chromadb.api.models.Collection import Collection

from app.config.settings import get_settings

_COLLECTION_NAME = "documents"

_client: chromadb.ClientAPI | None = None
_client_lock = threading.Lock()


@dataclass
class ChunkHit:
    """A retrieved chunk with its similarity score and metadata."""

    chunk_index: int
    document_id: str
    filename: str
    page: int
    text: str
    cosine_similarity: float


def _get_client() -> chromadb.ClientAPI:
    global _client
    if _client is None:
        with _client_lock:
            if _client is None:
                settings = get_settings()
                path = f"{settings.DATA_DIR}/chroma"
                _client = chromadb.PersistentClient(path=path)
    return _client


def _get_collection_sync() -> Collection:
    return _get_client().get_or_create_collection(
        name=_COLLECTION_NAME,
        metadata={"hnsw:space": "cosine"},
    )


def _upsert_sync(
    *,
    ids: list[str],
    embeddings: list[list[float]],
    documents: list[str],
    metadatas: list[dict[str, Any]],
) -> None:
    collection = _get_collection_sync()
    collection.upsert(
        ids=ids,
        embeddings=embeddings,  # type: ignore[arg-type]
        documents=documents,
        metadatas=metadatas,  # type: ignore[arg-type]
    )


def _build_where(document_ids: list[str] | None) -> dict[str, Any] | None:
    """None -> no filter (search everything). One id -> exact match. Several
    ids -> Chroma's ``$in`` operator."""
    if not document_ids:
        return None
    if len(document_ids) == 1:
        return {"document_id": document_ids[0]}
    return {"document_id": {"$in": document_ids}}


def _query_sync(
    *, query_embedding: list[float], top_k: int, document_ids: list[str] | None
) -> list[ChunkHit]:
    collection = _get_collection_sync()
    where = _build_where(document_ids)
    result = collection.query(
        query_embeddings=[query_embedding],  # type: ignore[arg-type]
        n_results=top_k,
        where=where,
        include=["documents", "metadatas", "distances"],
    )
    hits: list[ChunkHit] = []
    documents = (result.get("documents") or [[]])[0]
    metadatas = (result.get("metadatas") or [[]])[0]
    distances = (result.get("distances") or [[]])[0]
    for text, metadata, distance in zip(documents, metadatas, distances, strict=True):
        # Chroma's cosine space stores distance = 1 - cosine_similarity.
        hits.append(
            ChunkHit(
                chunk_index=int(metadata["chunk_index"]),  # type: ignore[arg-type]
                document_id=str(metadata["document_id"]),
                filename=str(metadata["filename"]),
                page=int(metadata["page"]),  # type: ignore[arg-type]
                text=text,
                cosine_similarity=1.0 - distance,
            )
        )
    return hits


def _ping_sync() -> None:
    _get_client().heartbeat()
    _get_collection_sync()


async def ping() -> None:
    """Raise if the vector store can't be opened — used by the readiness probe."""
    await asyncio.to_thread(_ping_sync)


def _delete_sync(document_id: str) -> None:
    collection = _get_collection_sync()
    collection.delete(where={"document_id": document_id})


async def upsert_chunks(
    *,
    document_id: str,
    filename: str,
    chunk_ids: list[str],
    chunk_texts: list[str],
    chunk_pages: list[int],
    embeddings: list[list[float]],
) -> None:
    """Upsert one document's chunks. IDs are ``{document_id}:{chunk_index}`` so
    re-ingesting the same document overwrites its own chunks cleanly."""
    metadatas = [
        {
            "document_id": document_id,
            "filename": filename,
            "page": page,
            "chunk_index": index,
        }
        for index, page in enumerate(chunk_pages)
    ]
    await asyncio.to_thread(
        _upsert_sync,
        ids=chunk_ids,
        embeddings=embeddings,
        documents=chunk_texts,
        metadatas=metadatas,
    )


async def query_similar(
    query_embedding: list[float], top_k: int, *, document_ids: list[str] | None = None
) -> list[ChunkHit]:
    """Top-``top_k`` chunks by cosine similarity, optionally filtered to one or
    more documents. ``document_ids=None`` (or empty) searches everything."""
    return await asyncio.to_thread(
        _query_sync, query_embedding=query_embedding, top_k=top_k, document_ids=document_ids
    )


async def delete_document_chunks(document_id: str) -> None:
    """Remove every chunk belonging to a document (used when re-uploading a
    changed file under the same content hash never happens, but kept for the
    documents API's replace path)."""
    await asyncio.to_thread(_delete_sync, document_id)
