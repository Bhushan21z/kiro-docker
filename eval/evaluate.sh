#!/usr/bin/env bash
#
# Evaluator pod lifecycle (KIRO_MODE=evaluate). One run, one candidate attempt:
#
#   fetch input.zip -> verify sha256 -> safe-extract -> neutralise -> kiro-cli
#   -> validate (one repair turn) -> upload outputs -> exit with a contract code
#
# The exit code is half of the contract with codinferno
# (utils/evaluation/constants.js EXIT_CODE_FAILURE). The other half is the
# JSON written to /dev/termination-log, which Kubernetes surfaces on the pod
# status so the worker learns *why* without reading logs.
#
#   0  success              21 kiro timed out        40 output upload failed
#   2  bad configuration    24 evaluator agent missing
#   10 input fetch failed   30 outputs invalid
#   11 input integrity      31 outputs contain credentials
#   20 kiro failed
#
# Required env: KIRO_API_KEY RUN_ID INPUT_URL INPUT_SHA256 RESULT_PUT_URL
#               REPORT_PUT_URL TRANSCRIPT_PUT_URL META_PUT_URL
# Optional env: KIRO_MODEL EVAL_IMAGE EVAL_ROOT KIRO_CLI_BIN
#               KIRO_EVAL_TIMEOUT_SECONDS KIRO_EVAL_REPAIR_TIMEOUT_SECONDS
#               KIRO_EVAL_TRUST_TOOLS EVAL_MIN_EVIDENCE_RATIO
set -uo pipefail

EVAL_HOME="${EVAL_HOME:-/opt/kiro-eval}"
EVAL_ROOT="${EVAL_ROOT:-/eval}"
KIRO_CLI_BIN="${KIRO_CLI_BIN:-kiro-cli}"
KIRO_EVAL_AGENT="${KIRO_EVAL_AGENT:-evaluator}"
KIRO_EVAL_ENGINE="${KIRO_EVAL_ENGINE:-v3}"
KIRO_EVAL_TIMEOUT_SECONDS="${KIRO_EVAL_TIMEOUT_SECONDS:-900}"
KIRO_EVAL_REPAIR_TIMEOUT_SECONDS="${KIRO_EVAL_REPAIR_TIMEOUT_SECONDS:-240}"
# Exact V3 tool ids the evaluator may use without approval. Must match the
# agent's `tools` list (eval/agent/evaluator.md); anything else is denied in
# a headless run because nobody can approve it.
KIRO_EVAL_TRUST_TOOLS="${KIRO_EVAL_TRUST_TOOLS:-read_file,list_directory,file_search,grep_search,fs_write}"
TERMINATION_LOG="${TERMINATION_LOG:-/dev/termination-log}"

INPUT_DIR="$EVAL_ROOT/input"
OUT_DIR="$EVAL_ROOT/out"
WORK_DIR="$EVAL_ROOT/work"
SCHEMA="$EVAL_HOME/schema/result.schema.v1.json"
AGENT_SRC="$EVAL_HOME/agent/${KIRO_EVAL_AGENT}.md"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
KIRO_EXITS=()
REPAIR_ATTEMPTED=false
TRANSCRIPT_REDACTIONS=0
FAILURE_CODE=""

# Presigned URLs are bearer credentials until they expire. They are held in
# unexported variables from here on and removed from every child's
# environment, so the agent never inherits them.
URL_INPUT="${INPUT_URL:-}"
URL_RESULT="${RESULT_PUT_URL:-}"
URL_REPORT="${REPORT_PUT_URL:-}"
URL_TRANSCRIPT="${TRANSCRIPT_PUT_URL:-}"
URL_META="${META_PUT_URL:-}"
unset INPUT_URL RESULT_PUT_URL REPORT_PUT_URL TRANSCRIPT_PUT_URL META_PUT_URL

log() { printf '[evaluate] %s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Writes the pod's verdict for Kubernetes and exits. The detail is generated
# here, never copied from tool output, so it cannot carry a URL or key.
finish() {
  local code="$1" failure="${2:-}" detail="${3:-}"
  { jq -cn --argjson exit "$code" --arg code "$failure" --arg detail "${detail:0:1500}" \
      '{exit:$exit, code:$code, detail:$detail}' > "$TERMINATION_LOG"; } 2>/dev/null || true
  log "exit $code ${failure:+($failure) }$detail"
  exit "$code"
}

require_env() {
  local missing=()
  [ -n "${KIRO_API_KEY:-}" ] || missing+=(KIRO_API_KEY)
  [ -n "${RUN_ID:-}" ] || missing+=(RUN_ID)
  [ -n "$URL_INPUT" ] || missing+=(INPUT_URL)
  [ -n "${INPUT_SHA256:-}" ] || missing+=(INPUT_SHA256)
  [ -n "$URL_RESULT" ] || missing+=(RESULT_PUT_URL)
  [ -n "$URL_REPORT" ] || missing+=(REPORT_PUT_URL)
  [ -n "$URL_TRANSCRIPT" ] || missing+=(TRANSCRIPT_PUT_URL)
  [ -n "$URL_META" ] || missing+=(META_PUT_URL)
  if [ "${#missing[@]}" -gt 0 ]; then
    finish 2 "" "missing configuration: ${missing[*]}"
  fi
  [ -f "$SCHEMA" ] || finish 2 "" "schema not found in image"
  [ -f "$AGENT_SRC" ] || finish 24 KIRO_AGENT_MISSING "agent file not found in image"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

fetch_input() {
  log "fetching input"
  if ! curl --fail --silent --show-error --retry 3 --retry-delay 2 --max-time 600 \
      -o "$WORK_DIR/input.zip" "$URL_INPUT" 2>"$WORK_DIR/fetch.err"; then
    finish 10 INPUT_FETCH_FAILED "input download failed: $(tail -c 300 "$WORK_DIR/fetch.err" | tr -d '\n' | sed 's#https\?://[^ ]*#[url]#g')"
  fi
  local got
  got="$(sha256_of "$WORK_DIR/input.zip")"
  [ "$got" = "$INPUT_SHA256" ] || finish 11 INPUT_INTEGRITY "input.zip sha256 mismatch"
}

extract_input() {
  local raw="$WORK_DIR/raw"
  mkdir -p "$raw" "$INPUT_DIR/rubric" "$INPUT_DIR/bundle"
  python3 "$EVAL_HOME/safe_extract.py" "$WORK_DIR/input.zip" "$raw" \
    || finish 11 INPUT_INTEGRITY "input.zip rejected by safe_extract"

  local manifest="$raw/eval-manifest.json"
  [ -f "$manifest" ] || finish 11 INPUT_INTEGRITY "eval-manifest.json missing"
  jq -e --arg run "$RUN_ID" '.run_id == $run' "$manifest" >/dev/null \
    || finish 11 INPUT_INTEGRITY "eval-manifest run_id does not match RUN_ID"

  # Every part is checked against the manifest before anything is opened, so a
  # part swapped after sealing is caught here rather than graded.
  local part want
  for part in challenge.json challenge-artifacts.zip candidate-bundle.zip; do
    [ -f "$raw/$part" ] || finish 11 INPUT_INTEGRITY "$part missing from input"
    want="$(jq -r --arg p "$part" '.parts[$p].sha256 // ""' "$manifest")"
    [ "$(sha256_of "$raw/$part")" = "$want" ] || finish 11 INPUT_INTEGRITY "$part sha256 mismatch"
  done

  python3 "$EVAL_HOME/safe_extract.py" "$raw/challenge-artifacts.zip" "$INPUT_DIR/rubric" \
    || finish 11 INPUT_INTEGRITY "challenge-artifacts.zip rejected by safe_extract"
  python3 "$EVAL_HOME/safe_extract.py" "$raw/candidate-bundle.zip" "$INPUT_DIR/bundle" \
    || finish 11 INPUT_INTEGRITY "candidate-bundle.zip rejected by safe_extract"
  cp "$manifest" "$INPUT_DIR/eval-manifest.json"
  cp "$raw/challenge.json" "$INPUT_DIR/challenge.json"
  rm -rf "$raw"
}

# A `.kiro/` directory in candidate or rubric content is agent configuration
# Kiro would load ahead of the evaluator's own (workspace agents override
# global ones). Kiro's cwd is $EVAL_ROOT, outside the input, so none of it
# should load anyway; renaming is the second lock on the same door, and keeps
# the files visible as evidence of an attempt.
neutralise_input() {
  local found=0 d
  while IFS= read -r -d '' d; do
    mv "$d" "$(dirname "$d")/.kiro.candidate" 2>/dev/null || mv "$d" "$d.candidate.$RANDOM"
    found=$((found + 1))
  done < <(find "$INPUT_DIR" -depth -type d -name .kiro -print0)
  NEUTRALISED_KIRO_DIRS="$found"
  # Read-only from here: the agent's write tool must not be able to edit the
  # evidence it is judging. Effective because the pod does not run as root.
  chmod -R a-w "$INPUT_DIR"
}

install_agent() {
  mkdir -p "$HOME/.kiro/agents" "$HOME/.kiro/settings" "$EVAL_ROOT/schema"
  cp "$AGENT_SRC" "$HOME/.kiro/agents/${KIRO_EVAL_AGENT}.md"
  cp "$EVAL_HOME/agent/permissions.yaml" "$HOME/.kiro/settings/permissions.yaml"
  # The agent may only read under /eval, so the schema it must satisfy is
  # copied in beside the evidence.
  cp "$SCHEMA" "$EVAL_ROOT/schema/result.schema.v1.json"
  chmod -R a-w "$EVAL_ROOT/schema"
  # Custom agents inherit default steering, skills and AGENTS.md unless told
  # not to; the evaluator's context must be its prompt and nothing else.
  # Knowledge and code-intelligence are off because neither is in the agent's
  # tool list and both index whatever they are pointed at.
  local s
  for s in "chat.disableInheritingDefaultResources true" "chat.enableKnowledge false" "chat.enableCodeIntelligence false"; do
    # shellcheck disable=SC2086
    "$KIRO_CLI_BIN" settings $s >/dev/null 2>&1 || log "could not apply setting: $s"
  done
  PROMPT_SHA256="$(sha256_of "$AGENT_SRC")"
  PROMPT_VERSION="$(cat "$EVAL_HOME/agent/VERSION" 2>/dev/null || echo unknown)"
  KIRO_VERSION="$("$KIRO_CLI_BIN" --version 2>/dev/null | head -n1 || echo unknown)"
}

# Runs one agent turn. Output goes to the transcript; the exit code is
# recorded, and only "agent missing" and "timed out" are fatal here — any other
# non-zero exit is judged by whether usable outputs exist.
run_kiro() {
  local message="$1" timeout_s="$2" rc
  # Pinned: kiro-cli 2.x defaults to the V2 engine, which ignores the agent's
  # V3 `permissions` and names tools differently, so the evaluator's write
  # and read restrictions would silently not apply.
  local args=(chat --no-interactive --agent-engine "$KIRO_EVAL_ENGINE" --agent "$KIRO_EVAL_AGENT" --output-format stream-json)
  [ -n "$KIRO_EVAL_TRUST_TOOLS" ] && args+=("--trust-tools=$KIRO_EVAL_TRUST_TOOLS")
  [ -n "${KIRO_MODEL:-}" ] && args+=(--model "$KIRO_MODEL")
  log "kiro turn (timeout ${timeout_s}s)"
  (cd "$EVAL_ROOT" && timeout --kill-after=15 "$timeout_s" \
    env -u EVAL_IMAGE -u INPUT_SHA256 "$KIRO_CLI_BIN" "${args[@]}" "$message") \
    >>"$WORK_DIR/transcript.raw.jsonl" 2>>"$WORK_DIR/kiro.stderr"
  rc=$?
  KIRO_EXITS+=("$rc")
  case "$rc" in
    4) finish_with_outputs 24 KIRO_AGENT_MISSING "kiro-cli could not load agent '$KIRO_EVAL_AGENT'" ;;
    124|137) finish_with_outputs 21 TIMEOUT "kiro-cli exceeded ${timeout_s}s" ;;
  esac
  return 0
}

run_validate() {
  python3 "$EVAL_HOME/validate.py" --out "$OUT_DIR" --input "$INPUT_DIR" --schema "$SCHEMA" \
    --report "$WORK_DIR/validation.json" --run-id "$RUN_ID" --user-event-id "$USER_EVENT_ID"
}

put() {
  local file="$1" url="$2" ctype="$3"
  curl --fail --silent --show-error --retry 3 --retry-delay 2 --retry-all-errors --max-time 300 \
    -X PUT -H "Content-Type: $ctype" --upload-file "$file" "$url" >/dev/null 2>>"$WORK_DIR/upload.err"
}

write_meta() {
  local exit_code="$1"
  local validation='null'
  [ -f "$WORK_DIR/validation.json" ] && validation="$(cat "$WORK_DIR/validation.json")"
  jq -n \
    --arg run_id "$RUN_ID" --argjson user_event_id "${USER_EVENT_ID:-0}" \
    --arg prompt_version "${PROMPT_VERSION:-unknown}" --arg prompt_sha256 "${PROMPT_SHA256:-}" \
    --arg kiro_cli_version "${KIRO_VERSION:-unknown}" --arg model "${KIRO_MODEL:-}" \
    --arg image "${EVAL_IMAGE:-}" --arg input_sha256 "${INPUT_SHA256:-}" \
    --arg started_at "$STARTED_AT" --arg finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson kiro_exits "$(printf '%s\n' "${KIRO_EXITS[@]:-}" | jq -R 'select(length>0)|tonumber' | jq -s .)" \
    --argjson repair_attempted "$REPAIR_ATTEMPTED" \
    --argjson neutralised_kiro_dirs "${NEUTRALISED_KIRO_DIRS:-0}" \
    --argjson transcript_redactions "${TRANSCRIPT_REDACTIONS:-0}" \
    --argjson exit_code "$exit_code" --arg failure_code "$FAILURE_CODE" \
    --argjson validation "$validation" \
    '{meta_version: 1, run_id: $run_id, user_event_id: $user_event_id,
      prompt: {version: $prompt_version, sha256: $prompt_sha256},
      kiro_cli_version: $kiro_cli_version, model: $model, image: $image, input_sha256: $input_sha256,
      timings: {started_at: $started_at, finished_at: $finished_at},
      kiro_exit_codes: $kiro_exits, repair_attempted: $repair_attempted,
      neutralised_kiro_dirs: $neutralised_kiro_dirs, transcript_redactions: $transcript_redactions,
      exit_code: $exit_code, failure_code: $failure_code,
      validation: $validation}' > "$WORK_DIR/meta.json"
}

redact_transcript() {
  local raw="$WORK_DIR/transcript.raw.jsonl"
  [ -f "$raw" ] || : > "$raw"
  TRANSCRIPT_REDACTIONS="$(python3 "$EVAL_HOME/redact_stream.py" < "$raw" 2>&1 >"$WORK_DIR/transcript.jsonl" | tail -n1)"
  [[ "$TRANSCRIPT_REDACTIONS" =~ ^[0-9]+$ ]] || TRANSCRIPT_REDACTIONS=0
  rm -f "$raw"
}

# Uploads what this outcome is allowed to ship, then exits. Result and report
# leave the pod only on success: an invalid or credential-bearing output must
# never reach the bucket. Transcript and meta always go (best effort) because
# they are what explains a failed run.
finish_with_outputs() {
  local code="$1" failure="${2:-}" detail="${3:-}"
  FAILURE_CODE="$failure"
  redact_transcript
  if [ "$code" -eq 0 ]; then
    if ! put "$OUT_DIR/result.json" "$URL_RESULT" "application/json" \
        || ! put "$OUT_DIR/report.html" "$URL_REPORT" "text/html"; then
      code=40; failure=OUTPUT_UPLOAD_FAILED; FAILURE_CODE="$failure"; detail="output upload failed"
    fi
  fi
  put "$WORK_DIR/transcript.jsonl" "$URL_TRANSCRIPT" "application/x-ndjson" || log "transcript upload failed"
  write_meta "$code"
  if ! put "$WORK_DIR/meta.json" "$URL_META" "application/json" && [ "$code" -eq 0 ]; then
    code=40; failure=OUTPUT_UPLOAD_FAILED; detail="meta upload failed"
  fi
  finish "$code" "$failure" "$detail"
}

repair_message() {
  local errors
  errors="$(jq -r '.errors[:30][] | "- " + (.[0:300])' "$WORK_DIR/validation.json" 2>/dev/null)"
  printf '%s\n\n%s\n\n%s\n' \
    "Your outputs in /eval/out failed validation. Fix every problem below by rewriting /eval/out/result.json and/or /eval/out/report.html, then stop." \
    "$errors" \
    "Do not change your assessment to make an error go away; correct the format, the citations, or the arithmetic. Every evidence ref must point at something that exists under /eval/input."
}

main() {
  require_env
  mkdir -p "$INPUT_DIR" "$OUT_DIR" "$WORK_DIR" "$HOME" || finish 2 "" "cannot create working directories"
  fetch_input
  extract_input
  USER_EVENT_ID="$(jq -r '.user_event_id' "$INPUT_DIR/eval-manifest.json")"
  [[ "$USER_EVENT_ID" =~ ^[0-9]+$ ]] || finish 11 INPUT_INTEGRITY "eval-manifest user_event_id is not an integer"
  neutralise_input
  install_agent

  run_kiro "Evaluate the candidate attempt under /eval/input exactly as your instructions describe, then write /eval/out/result.json and /eval/out/report.html." \
    "$KIRO_EVAL_TIMEOUT_SECONDS"

  run_validate; local v=$?
  if [ "$v" -eq 1 ] && [ -f "$OUT_DIR/result.json" ]; then
    REPAIR_ATTEMPTED=true
    run_kiro "$(repair_message)" "$KIRO_EVAL_REPAIR_TIMEOUT_SECONDS"
    run_validate; v=$?
  fi

  case "$v" in
    0) finish_with_outputs 0 "" "" ;;
    4) finish_with_outputs 31 OUTPUT_SECRET_LEAK "outputs contain credential material" ;;
    *)
      if [ ! -f "$OUT_DIR/result.json" ] && [ "${KIRO_EXITS[0]:-0}" -ne 0 ]; then
        finish_with_outputs 20 KIRO_FAILED "kiro-cli exited ${KIRO_EXITS[*]} without writing result.json"
      fi
      finish_with_outputs 30 OUTPUT_INVALID "$(jq -r '.errors[:5] | join("; ")' "$WORK_DIR/validation.json" 2>/dev/null | cut -c1-1200)"
      ;;
  esac
}

main "$@"
