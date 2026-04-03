#!/usr/bin/env bash
set -euo pipefail
# Avoid inheriting another project's venv (confuses uv / subprocesses).
unset VIRTUAL_ENV 2>/dev/null || true
# Prefer bind-mounted host tools (~/.local/bin, optional node bin) so corporate
# proxy/DNS inside the instance does not block curl installs.
# Always drop host UV_CACHE_DIR (often points at NFS .uv-cache with no free space).
unset UV_CACHE_DIR 2>/dev/null || true
export UV_CACHE_DIR="/tmp/deerflow-uv-cache"
mkdir -p "$UV_CACHE_DIR"
RUNTIME_ROOT="${DEER_FLOW_RUNTIME_ROOT:-/opt/deer-flow/runtime}"
mkdir -p "$RUNTIME_ROOT" /app/logs
export UV_LINK_MODE="${UV_LINK_MODE:-copy}"
export PATH="/opt/host-user-bin:/opt/host-nvm-node/bin:${PATH:-}"

cd /app/backend
export PYTHONPATH=.

if ! command -v uv >/dev/null 2>&1; then
	mkdir -p "$RUNTIME_ROOT/uv"
	export UV_INSTALL_DIR="$RUNTIME_ROOT/uv"
	env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
		curl -fsSL https://astral.sh/uv/install.sh | sh || {
		echo "ERROR: uv not found on PATH and bootstrap install failed."
		echo "Bind-mount your host uv, e.g. ~/.local/bin -> /opt/host-user-bin (see singularity-compose.yml)."
		exit 1
	}
	export PATH="$RUNTIME_ROOT/uv:$PATH"
fi

if ! command -v node >/dev/null 2>&1; then
	echo "WARNING: node not on PATH (MCP npx may be unavailable). Mount host Node tree to /opt/host-nvm-node."
fi

CONTAINER_PY="$(command -v python3 || true)"
if [ -z "$CONTAINER_PY" ]; then
	echo "ERROR: python3 not found in PATH (Singularity image should provide it)."
	exit 1
fi

# If .venv points at a host-only interpreter or console_scripts use host shebangs, fix the env.
if ! .venv/bin/python -c "pass" >/dev/null 2>&1; then
	echo "Venv interpreter not runnable in this environment; syncing with: $CONTAINER_PY"
	uv sync --python "$CONTAINER_PY"
elif [ ! -x .venv/bin/uvicorn ]; then
	uv sync --python "$CONTAINER_PY"
fi

# Use `python -m` / `python path/to/script` so we never rely on #! paths (often absolute
# host NFS paths) inside console_scripts — those break in Singularity where code is under /app.
# No --reload: inotify limits in Singularity instances are too low for site-packages.
.venv/bin/python -m uvicorn app.gateway.app:app \
	--host 0.0.0.0 --port 8001 \
	>>/app/logs/gateway.log 2>&1 &
.venv/bin/python .venv/bin/langgraph dev --no-browser --no-reload --allow-blocking --host 0.0.0.0 --port 2024 \
	>>/app/logs/langgraph.log 2>&1 &
wait
