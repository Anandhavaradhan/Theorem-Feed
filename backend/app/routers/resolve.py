import logging
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_session
from app.models import Video
from app.schemas import ResolveFailure
from app.services.resolver import ResolveError, resolve_video

log = logging.getLogger(__name__)
router = APIRouter(tags=["resolve"])


@router.get("/resolve")
async def resolve(
    video_id: uuid.UUID = Query(..., description="TheoremFeed video UUID (not a YouTube id)"),
    session: AsyncSession = Depends(get_session),
):
    # Only videos that passed scoped ingestion are playable. Not a general YouTube proxy.
    video = await session.get(Video, video_id)
    if video is None or video.status != "active":
        raise HTTPException(status_code=404, detail="video_not_found")
    try:
        return await resolve_video(session, video)
    except ResolveError as e:
        log.warning("resolve failed for %s: %s", video_id, e)
        retry = get_settings().resolve_retry_after_sec
        return JSONResponse(
            status_code=503,
            content=ResolveFailure(retry_after=retry).model_dump(),
            headers={"Retry-After": str(retry)},
        )
