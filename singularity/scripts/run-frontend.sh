#!/usr/bin/env bash
set -euo pipefail
mkdir -p /app/logs
cd /app/frontend
export NODE_ENV=development
export CI=true
export WATCHPACK_POLLING=true
# Avoid ENOSPC on NFS home: keep Corepack/pnpm caches on host /tmp (large disk).
export COREPACK_HOME="${COREPACK_HOME:-/tmp/deerflow-corepack}"
export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-/tmp/deerflow-npm-cache}"
mkdir -p "$COREPACK_HOME" "$NPM_CONFIG_CACHE"
export PATH="/opt/host-user-bin:/opt/host-nvm-node/bin:${PATH:-}"

if command -v pnpm >/dev/null 2>&1; then
	:
else
	TOOL_ROOT="/app/frontend/.deer-flow-tools"
	mkdir -p "$TOOL_ROOT"
	echo "Installing pnpm into $TOOL_ROOT (one-time) ..."
	env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
		npm install -g pnpm@10.26.2 --prefix "$TOOL_ROOT"
	export PATH="$TOOL_ROOT/bin:$PATH"
fi

if [ ! -d node_modules ]; then
	pnpm install --frozen-lockfile
fi
pnpm run dev >>/app/logs/frontend.log 2>&1
