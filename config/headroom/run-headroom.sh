#!/usr/bin/env bash
# Headroom launcher for the persistent launchd service.
#
# Install to: ~/.headroom/deploy/default/run-headroom.sh
# Copy the same content to: ~/.headroom/deploy/default/ensure-headroom.sh
#
# IMPORTANT: the deployment manifest base_env overrides these variables.
# Edit ~/.headroom/deploy/default/manifest.json to match, or the upstream
# URL here will be ignored.
#
# Chain: client -> Headroom (compress) -> rtk-proxy (normalize) -> provider
set -euo pipefail

export HEADROOM_PORT=8787
export HEADROOM_HOST=127.0.0.1
export HEADROOM_MODE=cache
export HEADROOM_BACKEND=anthropic
export HEADROOM_EMBEDDER_RUNTIME=cpu
export HEADROOM_KOMPRESS_BACKEND=onnx
export HEADROOM_TELEMETRY=off

# Tool-result interception is opt-in and gated behind this rollout channel.
export HEADROOM_ROLLOUT_CHANNEL=canary

# ONNX Runtime tuning: use all cores for the model's internal work.
# HEADROOM_KOMPRESS_MAX_CONCURRENT stays at its default of 1, so only one
# model invocation runs at a time and 8 intra-op threads cannot oversubscribe.
export HEADROOM_KOMPRESS_ONNX_INTRA_THREADS=8
export HEADROOM_KOMPRESS_ONNX_INTER_THREADS=2
# Start the background warm-up immediately instead of after a 2s delay.
export HEADROOM_KOMPRESS_WARMUP_DELAY_SECONDS=0

export ANTHROPIC_TARGET_API_URL=http://127.0.0.1:8080
export OPENAI_TARGET_API_URL=http://127.0.0.1:8080/v1

exec "$HOME/.local/bin/headroom" install agent run --profile default
