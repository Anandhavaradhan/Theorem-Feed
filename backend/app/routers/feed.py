from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.schemas import FeedResponse
from app.services import feed

router = APIRouter(prefix="/feed", tags=["feed"])


@router.get("/longform", response_model=FeedResponse)
async def longform(limit: int = Query(30, ge=1, le=100), session: AsyncSession = Depends(get_session)):
    return await feed.longform_feed(session, limit=limit)


@router.get("/shorts", response_model=FeedResponse)
async def shorts(limit: int = Query(30, ge=1, le=100), session: AsyncSession = Depends(get_session)):
    return await feed.shorts_feed(session, limit=limit)
