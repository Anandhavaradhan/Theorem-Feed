"""TheoremFeed backend. Personal use: no auth, no analytics, no telemetry, no ads."""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routers import feed, health, resolve, videos

app = FastAPI(title="TheoremFeed", version="0.1.0")

# The Flutter app runs on the user's own device on the LAN; allow it.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET", "POST", "PATCH"], allow_headers=["*"])

app.include_router(health.router)
app.include_router(videos.router)
app.include_router(resolve.router)
app.include_router(feed.router)
