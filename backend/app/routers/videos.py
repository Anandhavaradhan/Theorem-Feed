import uuid

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models import Video
from app.schemas import VideoOut

router = APIRouter(prefix="/videos", tags=["videos"])


@router.get("/{video_id}", response_model=VideoOut)
async def get_video(video_id: uuid.UUID, session: AsyncSession = Depends(get_session)) -> Video:
    video = await session.get(Video, video_id)
    if video is None or video.status != "active":
        raise HTTPException(status_code=404, detail="video_not_found")
    return video
