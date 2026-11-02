#!/usr/bin/env bash
#
# Run one real evaluation locally, exactly as the Kubernetes Job would (uid
# 1000, read-only root, real kiro-cli), against an input.zip on disk. Outputs
# land in OUT (default ./eval-out/<run_id>/).
#
#   KIRO_API_KEY=ksk_... tests/eval/local-run.sh path/to/input.zip
#
# The input.zip is either a fixture (tests/eval/make_fixture.py) or one built
# by codinferno's `db/tasks/build_evaluation_input.js`. Real candidate data
# leaves your machine for Kiro's model provider when you run this.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-kiro-docker:latest}"
PORT="${PORT:-18767}"
INPUT="${1:?usage: local-run.sh INPUT_ZIP}"
[ -n "${KIRO_API_KEY:-}" ] || { echo "KIRO_API_KEY is required" >&2; exit 2; }

RUN_ID="$(unzip -p "$INPUT" eval-manifest.json | jq -r .run_id)"
OUT="${OUT:-$PWD/eval-out/$RUN_ID}"
SERVE="$(mktemp -d)"
mkdir -p "$OUT"
cp "$INPUT" "$SERVE/input.zip"
SHA="$(sha256sum "$SERVE/input.zip" | cut -d' ' -f1)"

python3 "$HERE/server.py" "$PORT" "$SERVE" "$OUT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; rm -rf "$SERVE"' EXIT
sleep 1

U="http://127.0.0.1:$PORT"
set +e
docker run --rm --network host --user 1000:1000 --read-only \
  --tmpfs /eval:rw,mode=1777,size=2g --tmpfs /home/evaluator:rw,mode=1777 --tmpfs /tmp:rw,mode=1777 \
  -v "$OUT:/term" -e TERMINATION_LOG=/term/termination.json \
  -e KIRO_MODE=evaluate -e HOME=/home/evaluator -e KIRO_API_KEY \
  ${KIRO_MODEL:+-e KIRO_MODEL="$KIRO_MODEL"} \
  -e RUN_ID="$RUN_ID" -e INPUT_SHA256="$SHA" -e EVAL_IMAGE="$IMAGE" \
  -e INPUT_URL="$U/input.zip" -e RESULT_PUT_URL="$U/result.json" -e REPORT_PUT_URL="$U/report.html" \
  -e TRANSCRIPT_PUT_URL="$U/transcript.jsonl" -e META_PUT_URL="$U/meta.json" \
  "$IMAGE"
rc=$?
set -e
echo "exit $rc; outputs in $OUT" >&2
ls -la "$OUT" >&2
exit "$rc"
