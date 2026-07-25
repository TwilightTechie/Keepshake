from fastapi import APIRouter

from app.api.v1 import ask, conversations, data, days, review, tasks, wal

router = APIRouter()
router.include_router(conversations.router)
router.include_router(wal.router)
router.include_router(review.router)
router.include_router(tasks.router)
router.include_router(ask.router)
router.include_router(days.router)
router.include_router(data.router)


@router.get("/me", tags=["ops"])
async def me() -> dict[str, str]:
    """Smoke endpoint proving auth works."""
    return {"user": "self-hosted"}
