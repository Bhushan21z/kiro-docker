#!/usr/bin/env bash
#
# End-to-end smoke test for KIRO_MODE=evaluate, with a fake kiro-cli and a
# local GET/PUT server standing in for S3. Runs the container the way the
# Kubernetes Job does: uid 1000, read-only root filesystem, writable /eval,
# /home/evaluator and /tmp only.
#
#   IMAGE=kiro-docker:eval-smoke tests/eval/smoke.sh
#
# Linux only (uses --network host so the container reaches the local server).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-kiro-docker:eval-smoke}"
PORT="${PORT:-18765}"
KEY="ksk_SMOKEtestKEY0123456789"
RUN_ID="11111111-2222-4333-8444-555555555555"
UE=42
WORK="$(mktemp -d)"
PASS=0
FAILED=()

cleanup() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }
trap cleanup EXIT; [ -n "${KEEP:-}" ] && echo "work dir: $WORK"

python3 "$HERE/make_fixture.py" "$WORK/good" "$RUN_ID" "$UE" > "$WORK/good.sha"
python3 "$HERE/make_fixture.py" "$WORK/slip" "$RUN_ID" "$UE" --zip-slip > "$WORK/slip.sha"
python3 "$HERE/make_fixture.py" "$WORK/adv" "$RUN_ID" "$UE" --adversarial > "$WORK/adv.sha"

mkdir -p "$WORK/serve" "$WORK/up"
python3 "$HERE/server.py" "$PORT" "$WORK/serve" "$WORK/up" &
SERVER_PID=$!
sleep 1

SIG="?X-Amz-Signature=deadbeefSIG&X-Amz-Credential=AKIDsmoke"
U="http://127.0.0.1:$PORT"

# run_case NAME FIXTURE MODE EXPECTED_EXIT [extra docker args...]
run_case() {
  local name="$1" fixture="$2" mode="$3" want="$4"; shift 4
  rm -rf "${WORK:?}/up" "$WORK/term" && mkdir -p "$WORK/up" "$WORK/term" && chmod 777 "$WORK/term"
  cp "$WORK/$fixture/input.zip" "$WORK/serve/input.zip"
  local sha; sha="$(cat "$WORK/$fixture.sha")"
  docker run --rm --network host --user 1000:1000 --read-only \
    --tmpfs /eval:rw,mode=1777,size=256m --tmpfs /home/evaluator:rw,mode=1777 --tmpfs /tmp:rw,mode=1777 \
    -v "$HERE/fake-kiro-cli:/opt/fake/kiro-cli:ro" -v "$WORK/term:/term" \
    -e KIRO_MODE=evaluate -e HOME=/home/evaluator -e KIRO_CLI_BIN=/opt/fake/kiro-cli \
    -e TERMINATION_LOG=/term/log -e FAKE_KIRO_MODE="$mode" \
    -e KIRO_API_KEY="$KEY" -e RUN_ID="$RUN_ID" -e INPUT_SHA256="${SHA_OVERRIDE:-$sha}" \
    -e INPUT_URL="$U/input.zip$SIG" -e RESULT_PUT_URL="$U/result.json$SIG" -e REPORT_PUT_URL="$U/report.html$SIG" \
    -e TRANSCRIPT_PUT_URL="$U/transcript.jsonl$SIG" -e META_PUT_URL="$U/meta.json$SIG" \
    "$@" "$IMAGE" >"$WORK/$name.log" 2>&1
  local got=$?
  if [ "$got" -ne "$want" ]; then
    FAILED+=("$name: exit $got, want $want")
    sed 's/^/    /' "$WORK/$name.log" | tail -n 25
    return 1
  fi
  return 0
}

check() { # check NAME CONDITION_DESCRIPTION COMMAND...
  local name="$1" desc="$2"; shift 2
  if "$@"; then return 0; fi
  FAILED+=("$name: $desc"); return 1
}

ok() { PASS=$((PASS + 1)); echo "  ok  $1"; }

has() { [ -f "$WORK/up/$1" ]; }
hasnt() { [ ! -f "$WORK/up/$1" ]; }
meta() { jq -e "$1" "$WORK/up/meta.json" >/dev/null 2>&1; }
noleak() { ! grep -q -E "deadbeefSIG|X-Amz-Signature|$KEY" "$WORK/up/transcript.jsonl" "$WORK/up/meta.json" "$WORK/term/log" 2>/dev/null; }
term() { jq -e "$1" "$WORK/term/log" >/dev/null 2>&1; }

echo "evaluate-mode smoke test ($IMAGE)"

run_case success good good 0 \
  && check success "all four outputs uploaded" has result.json \
  && check success "report uploaded" has report.html \
  && check success "content types" bash -c "[ \"\$(cat $WORK/up/result.json.ctype)\" = application/json ] && [ \"\$(cat $WORK/up/report.html.ctype)\" = text/html ] && [ \"\$(cat $WORK/up/transcript.jsonl.ctype)\" = application/x-ndjson ]" \
  && check success "meta records a valid run" meta '.validation.ok == true and .exit_code == 0 and .prompt.sha256 != "" and .repair_attempted == false' \
  && check success "every citation resolved" meta '.validation.evidence.ratio == 1' \
  && check success "no URL or key in transcript/meta/termination log" noleak \
  && check success "termination log" term '.exit == 0' \
  && ok success

SHA_OVERRIDE=0000000000000000000000000000000000000000000000000000000000000000 run_case tampered good good 11 \
  && check tampered "nothing graded or uploaded" hasnt result.json \
  && check tampered "termination code" term '.code == "INPUT_INTEGRITY"' \
  && ok tampered

run_case zip_slip slip good 11 \
  && check zip_slip "rejected before grading" hasnt result.json \
  && ok zip_slip

run_case invalid good invalid 30 \
  && check invalid "invalid result never uploaded" hasnt result.json \
  && check invalid "report never uploaded" hasnt report.html \
  && check invalid "meta explains the failure" meta '.repair_attempted == true and .validation.ok == false and .failure_code == "OUTPUT_INVALID"' \
  && check invalid "transcript still uploaded" has transcript.jsonl \
  && ok invalid

run_case repair good fix_on_repair 0 \
  && check repair "repair turn recorded" meta '.repair_attempted == true and .validation.ok == true and (.kiro_exit_codes | length) == 2' \
  && ok repair

run_case bad_refs good bad_refs 30 \
  && check bad_refs "unresolvable citations fail the run" meta '.validation.errors | map(test("evidence references resolve")) | any' \
  && ok bad_refs

run_case leak good leak 31 \
  && check leak "credential-bearing outputs never uploaded" hasnt report.html \
  && check leak "result never uploaded" hasnt result.json \
  && check leak "termination code" term '.code == "OUTPUT_SECRET_LEAK"' \
  && ok leak

run_case read_env good read_env 0 \
  && check read_env "key redacted from transcript" noleak \
  && check read_env "redaction recorded" meta '.transcript_redactions >= 1' \
  && ok read_env

run_case adversarial adv good 0 \
  && check adversarial "candidate .kiro neutralised" meta '.neutralised_kiro_dirs == 1' \
  && ok adversarial

run_case agent_missing good missing_agent 24 \
  && check agent_missing "termination code" term '.code == "KIRO_AGENT_MISSING"' \
  && ok agent_missing

run_case crash good crash 20 \
  && check crash "termination code" term '.code == "KIRO_FAILED"' \
  && ok crash

run_case bad_config good good 2 -e RESULT_PUT_URL= \
  && check bad_config "names the missing setting" grep -q RESULT_PUT_URL "$WORK/term/log" \
  && ok bad_config

# The default prompt mode must be untouched: no key, no prompt -> exit 1.
docker run --rm "$IMAGE" "hello" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then ok default_mode_unchanged; else FAILED+=("default_mode_unchanged: exit $rc, want 1"); fi

echo
echo "$PASS passed, ${#FAILED[@]} failed"
for f in "${FAILED[@]}"; do echo "  FAIL $f"; done
[ "${#FAILED[@]}" -eq 0 ]
