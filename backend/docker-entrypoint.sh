#!/bin/sh
set -e
# YouTube changes often; a stale yt-dlp is the #1 cause of resolve failures.
# Refresh on every container start.
if [ "${TF_YTDLP_AUTOUPDATE:-1}" = "1" ]; then
  pip install --no-cache-dir -q -U yt-dlp || echo "yt-dlp update failed; continuing with installed version"
fi
alembic upgrade head
exec uvicorn app.main:app --host 0.0.0.0 --port 8000
