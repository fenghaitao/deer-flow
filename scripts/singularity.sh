#!/usr/bin/env bash
set -e

# DeerFlow + singularity-compose (same workflow pattern as potpie/singularity).
# Optional: reuse an existing singularity-compose venv from potpie:
#   export DEER_FLOW_SINGULARITY_COMPOSE="$HOME/coder/potpie/singularity/singularity-compose/.venv/bin/singularity-compose"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SING_DIR="$PROJECT_ROOT/singularity"
COMPOSE_FILE="$SING_DIR/singularity-compose.yml"
DEFAULT_SBOX_IMAGE="enterprise-public-cn-beijing.cr.volces.com/vefaas-public/all-in-one-sandbox:latest"

resolve_compose_bin() {
	if [ -n "${DEER_FLOW_SINGULARITY_COMPOSE:-}" ] && [ -x "${DEER_FLOW_SINGULARITY_COMPOSE}" ]; then
		echo "${DEER_FLOW_SINGULARITY_COMPOSE}"
		return
	fi
	local local_bin="$SING_DIR/.venv/bin/singularity-compose"
	if [ -x "$local_bin" ]; then
		echo "$local_bin"
		return
	fi
	local potpie_bin="$PROJECT_ROOT/../potpie/singularity/singularity-compose/.venv/bin/singularity-compose"
	if [ -x "$potpie_bin" ]; then
		echo "$potpie_bin"
		return
	fi
	echo ""
}

ensure_compose_bin() {
	local bin
	bin="$(resolve_compose_bin)"
	if [ -n "$bin" ]; then
		echo "$bin"
		return
	fi
	if ! command -v uv >/dev/null 2>&1; then
		echo -e "${YELLOW}uv not found. Install from https://docs.astral.sh/uv/${NC}" >&2
		exit 1
	fi
	echo "Bootstrapping singularity-compose in singularity/.venv ..." >&2
	uv venv "$SING_DIR/.venv"
	uv pip install --python "$SING_DIR/.venv/bin/python" singularity-compose
	echo "$SING_DIR/.venv/bin/singularity-compose"
}

detect_sandbox_mode() {
	local config_file="$PROJECT_ROOT/config.yaml"
	local sandbox_use=""
	local provisioner_url=""

	if [ ! -f "$config_file" ]; then
		echo "local"
		return
	fi

	sandbox_use=$(awk '
        /^[[:space:]]*sandbox:[[:space:]]*$/ { in_sandbox=1; next }
        in_sandbox && /^[^[:space:]#]/ { in_sandbox=0 }
        in_sandbox && /^[[:space:]]*use:[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*use:[[:space:]]*/, "", line)
            print line
            exit
        }
    ' "$config_file")

	provisioner_url=$(awk '
        /^[[:space:]]*sandbox:[[:space:]]*$/ { in_sandbox=1; next }
        in_sandbox && /^[^[:space:]#]/ { in_sandbox=0 }
        in_sandbox && /^[[:space:]]*provisioner_url:[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*provisioner_url:[[:space:]]*/, "", line)
            print line
            exit
        }
    ' "$config_file")

	if [[ "$sandbox_use" == *"deerflow.sandbox.local:LocalSandboxProvider"* ]]; then
		echo "local"
	elif [[ "$sandbox_use" == *"deerflow.community.aio_sandbox:AioSandboxProvider"* ]]; then
		if [ -n "$provisioner_url" ]; then
			echo "provisioner"
		else
			echo "aio"
		fi
	else
		echo "local"
	fi
}

write_runtime_env() {
	mkdir -p "$SING_DIR"
	cat >"$SING_DIR/.runtime-env.sh" <<EOF
export DEER_FLOW_ROOT="$PROJECT_ROOT"
export DEER_FLOW_HOST_BASE_DIR="$PROJECT_ROOT/backend/.deer-flow"
export DEER_FLOW_HOST_SKILLS_PATH="$PROJECT_ROOT/skills"
export DEER_FLOW_SANDBOX_HOST=127.0.0.1
export DEER_FLOW_CHANNELS_LANGGRAPH_URL=http://127.0.0.1:2024
export DEER_FLOW_CHANNELS_GATEWAY_URL=http://127.0.0.1:8001
export CI=true
EOF
}

cmd_init() {
	echo "=========================================="
	echo "  DeerFlow Singularity — init"
	echo "=========================================="
	echo ""

	if [ -z "$SINGULARITY_TMPDIR" ] || [ ! -d "$SINGULARITY_TMPDIR" ]; then
		export SINGULARITY_TMPDIR=/tmp
	fi
	unset TMPDIR

	SINGULARITY_COMPOSE_BIN="$(ensure_compose_bin)"
	export PATH="$(dirname "$SINGULARITY_COMPOSE_BIN"):$PATH"

	mkdir -p "$PROJECT_ROOT/logs" "${HOME}/.cache/uv" "$SING_DIR/cache" "$SING_DIR/cache/backend-runtime" \
		"$SING_DIR/cache/nginx-cache" "$SING_DIR/cache/nginx-log" /tmp/deerflow-uv-cache \
		/tmp/deerflow-corepack /tmp/deerflow-npm-cache
	chmod -R a+rwx "$SING_DIR/cache/nginx-cache" "$SING_DIR/cache/nginx-log" 2>/dev/null || true
	chmod +x "$SING_DIR/scripts/run-backend.sh" "$SING_DIR/scripts/run-frontend.sh" 2>/dev/null || true

	local mode
	mode="$(detect_sandbox_mode)"
	if [ "$mode" = "local" ]; then
		echo -e "${GREEN}Sandbox mode: local — no AIO sandbox image pull.${NC}"
	elif [ "$mode" = "provisioner" ]; then
		echo -e "${YELLOW}Provisioner (Kubernetes) mode is not supported by singularity-compose dev yet.${NC}"
		echo "Use Docker or run the provisioner stack separately."
	else
		local image="$DEFAULT_SBOX_IMAGE"
		local out="$SING_DIR/cache/aio-sandbox.sif"
		echo -e "${BLUE}AIO sandbox mode: pulling OCI image to ${out}${NC}"
		echo "(Singularity/Apptainer must be able to reach the registry.)"
		if command -v singularity >/dev/null 2>&1; then
			singularity pull "$out" "docker://${image}" || echo -e "${YELLOW}Pull failed — continue anyway if you use local sandbox.${NC}"
		elif command -v apptainer >/dev/null 2>&1; then
			apptainer pull "$out" "docker://${image}" || echo -e "${YELLOW}Pull failed — continue anyway if you use local sandbox.${NC}"
		else
			echo -e "${YELLOW}Neither singularity nor apptainer found in PATH; skipped sandbox image pull.${NC}"
		fi
	fi

	echo ""
	echo "Building SIF images (if missing) ..."
	cd "$SING_DIR" && "$SINGULARITY_COMPOSE_BIN" -f "$COMPOSE_FILE" build

	echo ""
	echo -e "${GREEN}✓ singularity-init complete.${NC}"
	echo -e "${YELLOW}Next: make singularity-start${NC}"
}

ensure_config_files() {
	if [ ! -f "$PROJECT_ROOT/config.yaml" ]; then
		if [ -f "$PROJECT_ROOT/config.example.yaml" ]; then
			cp "$PROJECT_ROOT/config.example.yaml" "$PROJECT_ROOT/config.yaml"
			echo -e "${YELLOW}Created config.yaml from config.example.yaml — edit before use.${NC}"
		else
			echo -e "${YELLOW}Missing config.yaml${NC}"
			exit 1
		fi
	fi
	if [ ! -f "$PROJECT_ROOT/extensions_config.json" ]; then
		if [ -f "$PROJECT_ROOT/extensions_config.example.json" ]; then
			cp "$PROJECT_ROOT/extensions_config.example.json" "$PROJECT_ROOT/extensions_config.json"
		else
			echo "{}" >"$PROJECT_ROOT/extensions_config.json"
		fi
	fi
	if [ ! -f "$PROJECT_ROOT/.env" ]; then
		if [ -f "$PROJECT_ROOT/.env.example" ]; then
			cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
		else
			touch "$PROJECT_ROOT/.env"
		fi
	fi
	if [ ! -f "$PROJECT_ROOT/frontend/.env" ]; then
		if [ -f "$PROJECT_ROOT/frontend/.env.example" ]; then
			cp "$PROJECT_ROOT/frontend/.env.example" "$PROJECT_ROOT/frontend/.env"
		fi
	fi
}

cmd_start() {
	local mode
	mode="$(detect_sandbox_mode)"
	if [ "$mode" = "provisioner" ]; then
		echo -e "${YELLOW}Provisioner mode is not supported by make singularity-start.${NC}"
		exit 1
	fi

	write_runtime_env
	ensure_config_files

	if [ -z "$SINGULARITY_TMPDIR" ] || [ ! -d "$SINGULARITY_TMPDIR" ]; then
		export SINGULARITY_TMPDIR=/tmp
	fi
	unset TMPDIR

	SINGULARITY_COMPOSE_BIN="$(ensure_compose_bin)"

	echo "=========================================="
	echo "  DeerFlow Singularity — start"
	echo "=========================================="
	echo ""
	echo -e "${BLUE}Sandbox mode: ${mode}${NC}"
	echo ""

	mkdir -p "$PROJECT_ROOT/logs" "${HOME}/.cache/uv" "$SING_DIR/cache/backend-runtime" \
		"$SING_DIR/cache/nginx-cache" "$SING_DIR/cache/nginx-log" /tmp/deerflow-uv-cache \
		/tmp/deerflow-corepack /tmp/deerflow-npm-cache
	chmod -R a+rwx "$SING_DIR/cache/nginx-cache" "$SING_DIR/cache/nginx-log" 2>/dev/null || true
	chmod +x "$SING_DIR/scripts/run-backend.sh" "$SING_DIR/scripts/run-frontend.sh" 2>/dev/null || true

	# shellcheck source=/dev/null
	source "$SING_DIR/.runtime-env.sh"
	export SINGULARITYENV_DEER_FLOW_RUNTIME_ROOT=/opt/deer-flow/runtime
	export SINGULARITYENV_UV_CACHE_DIR=/tmp/deerflow-uv-cache
	export SINGULARITYENV_UV_LINK_MODE=copy
	export SINGULARITYENV_DEER_FLOW_ROOT="$DEER_FLOW_ROOT"
	export SINGULARITYENV_DEER_FLOW_HOST_BASE_DIR="$DEER_FLOW_HOST_BASE_DIR"
	export SINGULARITYENV_DEER_FLOW_HOST_SKILLS_PATH="$DEER_FLOW_HOST_SKILLS_PATH"
	export SINGULARITYENV_DEER_FLOW_SANDBOX_HOST="$DEER_FLOW_SANDBOX_HOST"
	export SINGULARITYENV_DEER_FLOW_CHANNELS_LANGGRAPH_URL="$DEER_FLOW_CHANNELS_LANGGRAPH_URL"
	export SINGULARITYENV_DEER_FLOW_CHANNELS_GATEWAY_URL="$DEER_FLOW_CHANNELS_GATEWAY_URL"
	export SINGULARITYENV_CI="$CI"

	# Use host DNS (/etc/resolv.conf) — bundled Google resolv breaks many corporate networks.
	cd "$SING_DIR" && "$SINGULARITY_COMPOSE_BIN" -f "$COMPOSE_FILE" up --no-resolv "$@"

	echo ""
	echo -e "${GREEN}DeerFlow (Singularity) is up.${NC}"
	echo "  http://localhost:2026"
	echo "  Logs: $PROJECT_ROOT/logs/"
	echo "  Stop: make singularity-stop"
}

cmd_stop() {
	SINGULARITY_COMPOSE_BIN="$(resolve_compose_bin)"
	if [ -z "$SINGULARITY_COMPOSE_BIN" ]; then
		SINGULARITY_COMPOSE_BIN="$(ensure_compose_bin)"
	fi
	cd "$SING_DIR" && "$SINGULARITY_COMPOSE_BIN" -f "$COMPOSE_FILE" down "$@"
	echo -e "${GREEN}✓ singularity instances stopped.${NC}"
}

cmd_logs() {
	SINGULARITY_COMPOSE_BIN="$(resolve_compose_bin)"
	if [ -z "$SINGULARITY_COMPOSE_BIN" ]; then
		SINGULARITY_COMPOSE_BIN="$(ensure_compose_bin)"
	fi
	cd "$SING_DIR" && "$SINGULARITY_COMPOSE_BIN" -f "$COMPOSE_FILE" logs "$@"
}

usage() {
	echo "Usage: $0 {init|start|stop|logs}"
	echo ""
	echo "  init   — bootstrap singularity-compose venv, optional AIO sandbox SIF, build SIFs"
	echo "  start  — singularity-compose up (deerflow-backend, frontend, nginx)"
	echo "  stop   — singularity-compose down"
	echo "  logs   — singularity-compose logs [args]"
	echo ""
	echo "Override compose binary: DEER_FLOW_SINGULARITY_COMPOSE=/path/to/singularity-compose"
}

main() {
	case "${1:-}" in
	init) cmd_init ;;
	start)
		shift
		cmd_start "$@"
		;;
	stop)
		shift
		cmd_stop "$@"
		;;
	logs)
		shift
		cmd_logs "$@"
		;;
	*) usage ;;
	esac
}

main "$@"
