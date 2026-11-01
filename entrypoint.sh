#!/usr/bin/env bash
#
# Container entrypoint. Prepares the environment so Kiro can act autonomously
# on any project, then runs Kiro headless with the user's prompt.
#
# Environment variables (all optional except KIRO_API_KEY):
#   KIRO_API_KEY   Kiro API key (required)
#   KIRO_MODEL     Model id passed to `kiro-cli chat --model`
#   KIRO_RAW       If "1", send the prompt as-is, without the autonomy preamble
#
set -euo pipefail

if [ -z "${KIRO_API_KEY:-}" ]; then
  echo "Error: KIRO_API_KEY is not set inside the container." >&2
  exit 1
fi

USER_PROMPT="${*:-}"
if [ -z "$USER_PROMPT" ]; then
  echo "Error: no prompt provided to the container." >&2
  exit 2
fi

# Refresh apt metadata once (quietly) so that any `apt-get install` the agent
# decides to run at runtime succeeds without needing a manual update first.
# Non-fatal: if offline or it fails, the agent can still handle it.
apt-get update -qq >/dev/null 2>&1 || true

# Self-sufficiency preamble. This tells Kiro it is in a disposable root
# container with internet access and is expected to set up whatever the task
# needs on its own, rather than asking the user.
read -r -d '' PREAMBLE <<'EOF' || true
You are running fully autonomously inside a disposable Linux (Ubuntu) Docker
container as root, with sudo and internet access. The user cannot answer
follow-up questions - never ask for permission or confirmation; just proceed.

Operating rules:
- First inspect the mounted project in /workspace to understand what it is
  (language, framework, build system, package manager, test runner).
- Install ANYTHING you need yourself. You have apt-get, pip/pipx, npm, and
  curl/wget. Node.js and Python are preinstalled; install other runtimes
  (Go, Rust, Java, Ruby, etc.) via apt or official installers as required.
- Do not ask the user to install tools or grant permissions. If something is
  missing, install it and continue.
- Detect and run the project's own scripts/targets (npm/yarn/pnpm scripts,
  Makefile, pytest, go test, cargo, gradle/maven, etc.).
- If a step fails, diagnose the root cause and fix it, then retry. Persist
  until the task is genuinely complete or truly impossible.
- At the end, give a concise report: what you detected, what you installed,
  what you ran, and the resulting output/result.

The user's task follows.
EOF

if [ "${KIRO_RAW:-0}" = "1" ]; then
  FULL_PROMPT="$USER_PROMPT"
else
  FULL_PROMPT="${PREAMBLE}

=== TASK ===
${USER_PROMPT}"
fi

ARGS=(chat --no-interactive --trust-all-tools)
if [ -n "${KIRO_MODEL:-}" ]; then
  ARGS+=(--model "$KIRO_MODEL")
fi

exec kiro-cli "${ARGS[@]}" "$FULL_PROMPT"
