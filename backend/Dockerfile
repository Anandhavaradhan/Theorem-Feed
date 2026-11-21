FROM python:3.11-slim

# ffmpeg/ffprobe: resolver test (§15.2) and future yt-dlp post-processing.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && apt-get clean

WORKDIR /app
COPY pyproject.toml ./
COPY app ./app
COPY alembic ./alembic
COPY alembic.ini docker-entrypoint.sh ./
RUN pip install --no-cache-dir . && chmod +x docker-entrypoint.sh

ENV TF_DATABASE_URL=postgresql+asyncpg://theoremfeed:theoremfeed@db:5432/theoremfeed \
    TF_DATABASE_URL_SYNC=postgresql+psycopg2://theoremfeed:theoremfeed@db:5432/theoremfeed

EXPOSE 8000
ENTRYPOINT ["./docker-entrypoint.sh"]
