# GurbaniLens server image.
#
# Multi-stage:
#   1. node-build — `npm install --omit=dev`. No native modules to
#      compile (sql.js is pure WASM), so no build-essential needed.
#   2. python-build — uv venv with faster-whisper installed.
#   3. runtime — slim image, copies the built node_modules and venv,
#      installs only ffmpeg + libgomp1 + ca-certificates.
#
# Final image size target: < 1.5 GB. Whisper model weights are NOT
# baked in (they'd add 3 GB for large-v3) — mount or download at run.

# ---------- 1) Node build stage ----------
FROM node:22-slim AS node-build

WORKDIR /app
COPY package.json ./
# No native compile step — sql.js is pure WASM, no glibc binding.
RUN npm install --omit=dev --no-audit --no-fund

# ---------- 2) Python (faster-whisper) build stage ----------
FROM python:3.12-slim AS python-build

WORKDIR /app
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Install uv (single static binary).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && cp /root/.local/bin/uv /usr/local/bin/uv

RUN uv venv /opt/asr-venv \
 && uv pip install --python /opt/asr-venv/bin/python faster-whisper

# ---------- 3) Runtime ----------
FROM node:22-slim AS runtime

# System runtime deps:
#   ffmpeg + ffprobe  — duration probe + audio decode for whisper
#   python3-minimal   — required to invoke .venv-asr/bin/python
#   libgomp1          — onnxruntime CPU dependency
#   ca-certificates   — for any outbound HTTPS (e.g. first-run model download)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ffmpeg python3-minimal libgomp1 ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Non-root runtime user
RUN groupadd -r app && useradd -r -g app -d /app -s /usr/sbin/nologin app

WORKDIR /app

# Copy Node app + node_modules from node-build
COPY --from=node-build /app/node_modules ./node_modules
COPY --from=node-build /app/package.json ./package.json
COPY src ./src

# Copy Python venv from python-build
# Path matches the default WHISPER_PYTHON env var.
COPY --from=python-build /opt/asr-venv ./.venv-asr

# Pre-create writable dirs the app needs
RUN mkdir -p /app/data /tmp/gurbanilens-asr \
 && chown -R app:app /app /tmp/gurbanilens-asr

USER app

ENV NODE_ENV=production \
    PORT=4040 \
    HOST=0.0.0.0 \
    WHISPER_PYTHON=/app/.venv-asr/bin/python \
    WHISPER_WORKER=/app/src/asr/whisper_worker.py \
    WHISPER_MODEL=large-v3 \
    FEEDBACK_DB_PATH=/app/data/feedback.db

EXPOSE 4040

# Healthcheck hits /healthz — `/readyz` is the deeper probe but
# we want the container marked healthy even if the venv is still
# being warmed; orchestrator uses /readyz separately.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||4040)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/index.js"]
