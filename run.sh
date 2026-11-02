#!/usr/bin/env bash
#
# run.sh - run a self-sufficient Kiro task in an isolated container against
# any project directory.
#
# Kiro runs fully autonomously: it inspects the project, installs whatever
# toolchains/dependencies it needs, runs the task, and reports the output.
# No interaction, no permission prompts.
#
# Usage:
#   ./run.sh "Run the tests and tell me if they pass"
#   ./run.sh -d /path/to/project "Build the project and fix any errors"
#   ./run.sh -f task.md
#   ./run.sh -m claude-sonnet-4.5 "Refactor src/ for readability"
#
# Auth: reads KIRO_API_KEY from the environment, or from a .env file in the
# current directory or next to this script.

set -euo pipefail

IMAGE="${KIRO_IMAGE:-kiro-docker:latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_DIR="$PWD"
MODEL="${KIRO_MODEL:-}"
EFFORT="${KIRO_EFFORT:-}"
PROMPT_FILE=""
READ_ONLY=0
NETWORK=""
RAW=0

usage() {
  cat <<'EOF'
Usage: ./run.sh [options] "<prompt>"
       ./run.sh [options] -f PROMPT_FILE

Options:
  -d DIR     Project directory to mount at /workspace (default: current dir)
  -f FILE    Read the prompt from FILE instead of the command line
  -m MODEL   Model id to use (default: Kiro's default)
  -e EFFORT  Reasoning effort: low, medium, high, xhigh, max (default: Kiro's
             default). "max" is Claude-only; not all models support effort.
  -r         Mount the project read-only (agent cannot modify your files)
  -n NET     Docker network mode, e.g. "none" to disable networking
             (note: Kiro itself needs network access to reach its API)
  -R         Raw mode: send the prompt without the autonomy preamble
  -h         Show this help

Environment:
  KIRO_API_KEY   Kiro API key (or put it in a .env file)
  KIRO_IMAGE     Image to run (default: kiro-docker:latest, auto-built if missing)
  KIRO_MODEL     Default model id
  KIRO_EFFORT    Default reasoning effort (same as -e)

Kiro runs autonomously inside the container: it detects the stack, installs
what it needs, runs the task, and reports results. No prompts, no interaction.
EOF
}

while getopts ":d:f:m:e:n:rRh" opt; do
  case "$opt" in
    d) PROJECT_DIR="$OPTARG" ;;
    f) PROMPT_FILE="$OPTARG" ;;
    m) MODEL="$OPTARG" ;;
    e) EFFORT="$OPTARG" ;;
    n) NETWORK="$OPTARG" ;;
    r) READ_ONLY=1 ;;
    R) RAW=1 ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 2 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || { echo "Error: prompt file not found: $PROMPT_FILE" >&2; exit 2; }
  PROMPT="$(cat "$PROMPT_FILE")"
elif [ "$#" -ge 1 ]; then
  PROMPT="$*"
else
  PROMPT=""
fi

if [ -z "$PROMPT" ]; then
  echo "Error: no prompt provided." >&2
  usage
  exit 2
fi

if [ -n "$EFFORT" ]; then
  case "$EFFORT" in
    low|medium|high|xhigh|max) ;;
    *)
      echo "Error: invalid effort '$EFFORT' (expected: low, medium, high, xhigh, max)." >&2
      exit 2
      ;;
  esac
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is not installed or not on PATH." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Error: the Docker daemon is not running." >&2
  exit 1
fi

# Read KIRO_API_KEY from a .env file without executing it.
read_key_from_env_file() {
  local file="$1" line
  [ -f "$file" ] || return 1
  line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?KIRO_API_KEY=' "$file" | tail -n1 || true)"
  [ -n "$line" ] || return 1
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

if [ -z "${KIRO_API_KEY:-}" ]; then
  KIRO_API_KEY="$(read_key_from_env_file "$PWD/.env" || read_key_from_env_file "$SCRIPT_DIR/.env" || true)"
  export KIRO_API_KEY
fi

if [ -z "${KIRO_API_KEY:-}" ]; then
  echo "Error: KIRO_API_KEY is not set (export it or add it to a .env file)." >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: project directory not found: $PROJECT_DIR" >&2
  exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Build the image on first use.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Image '$IMAGE' not found - building it from $SCRIPT_DIR ..." >&2
  docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

MOUNT="$PROJECT_DIR:/workspace"
[ "$READ_ONLY" = "1" ] && MOUNT="$MOUNT:ro"

DOCKER_ARGS=(run --rm -e KIRO_API_KEY)
[ -n "$MODEL" ] && DOCKER_ARGS+=(-e "KIRO_MODEL=$MODEL")
[ -n "$EFFORT" ] && DOCKER_ARGS+=(-e "KIRO_EFFORT=$EFFORT")
[ "$RAW" = "1" ] && DOCKER_ARGS+=(-e KIRO_RAW=1)
[ -n "$NETWORK" ] && DOCKER_ARGS+=(--network "$NETWORK")

# Persistent caches (named Docker volumes) so repeated runs don't re-download
# toolchains/deps. They are independent of the project directory.
exec docker "${DOCKER_ARGS[@]}" \
  -v "$MOUNT" \
  -v kiro-cache-apt:/var/cache/apt \
  -v kiro-cache-npm:/root/.npm \
  -v kiro-cache-pip:/root/.cache/pip \
  -w /workspace \
  "$IMAGE" \
  "$PROMPT"
