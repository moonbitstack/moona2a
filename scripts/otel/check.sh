#!/usr/bin/env bash
# Run OpenTelemetry Weaver's live check over the spans this library's instrumentation
# emits.
#
# The example in `src/examples/07-otel` runs one instrumented exchange — a card read, a
# message, a task read, a stream and a refused cancellation — and sends the spans to
# Weaver over OTLP/gRPC. Weaver compares them with `registry/` and reports what does not
# belong: an attribute name the conventions do not define, an attribute of the wrong
# type, a required attribute that is missing. A finding of level `violation` is a
# non-zero exit.
#
# A run that sent nothing would have nothing to complain about, so the report is also
# read here: every span the example is supposed to produce has to be in it.
#
# Usage: scripts/otel/check.sh        (weaver must be on PATH, or set WEAVER)
# Exit status: 0 only when the registry is valid, every span arrived, and Weaver found
# no violation.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
weaver_bin="${WEAVER:-weaver}"
workdir="${OTEL_WORKDIR:-${TMPDIR:-/tmp}/moona2a-otel}"
port="${OTEL_GRPC_PORT:-14317}"
admin="${OTEL_ADMIN_PORT:-14320}"

if ! command -v "$weaver_bin" >/dev/null 2>&1; then
  echo "weaver is not on PATH: set WEAVER to the binary, see https://github.com/open-telemetry/weaver" >&2
  exit 2
fi

echo "== checking the registry =="
"$weaver_bin" registry check -r "$repo_root/scripts/otel/registry"

echo "== building the example =="
mkdir -p "$workdir/report"
rm -f "$workdir/report/live_check.json"
(cd "$repo_root" && moon build src/examples/07-otel --target native)
server="$repo_root/_build/native/debug/build/examples/07-otel/07-otel"
if [[ -x "$server.exe" ]]; then
  server="$server.exe"
fi

echo "== starting the live check on port $port =="
"$weaver_bin" registry live-check \
  -r "$repo_root/scripts/otel/registry" \
  --config "$repo_root/scripts/otel/weaver.toml" \
  --otlp-grpc-address 127.0.0.1 \
  --otlp-grpc-port "$port" \
  --admin-port "$admin" \
  --inactivity-timeout 300 \
  --format json \
  --output "$workdir/report" &
weaver_pid=$!

cleanup() {
  kill "$weaver_pid" 2>/dev/null || true
  wait "$weaver_pid" 2>/dev/null || true
}
trap cleanup EXIT

# The admin port answers only once the OTLP listener is up.
for _ in $(seq 1 300); do
  if curl -fsS "http://127.0.0.1:$admin/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

echo "== sending the spans =="
"$server" "127.0.0.1:$port"

echo "== stopping the live check =="
curl -fsS -X POST "http://127.0.0.1:$admin/stop" >/dev/null
set +e
wait "$weaver_pid"
weaver_status=$?
set -e
trap - EXIT
if [[ "$weaver_status" -ne 0 ]]; then
  echo "weaver reported a violation: see $workdir/report/live_check.json" >&2
  exit "$weaver_status"
fi

echo "== reading the report =="
python3 - "$workdir/report/live_check.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
statistics = report["statistics"]

spans = []


def walk(node):
    if isinstance(node, dict):
        span = node.get("span")
        if isinstance(span, dict):
            spans.append(span["name"])
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)


walk(report["samples"])

# What the example does, by span: read the card, send a message (once from the caller's
# side and once from the agent's), read the task back, follow a stream on both sides, and
# have a cancellation refused.
wanted = {
    "a2a.discover": 1,
    "invoke_agent echo": 4,
    "a2a.call": 2,
}
for name, count in wanted.items():
    seen = spans.count(name)
    if seen != count:
        print(f"expected {count} span(s) named {name!r}, saw {seen}: {spans}")
        sys.exit(1)

violations = statistics["advice_level_counts"].get("violation", 0)
if violations:
    print(f"{violations} violation(s) in the report")
    sys.exit(1)

print(
    f"{len(spans)} spans, {statistics['total_entities']} entities, "
    f"{statistics['total_advisories']} advisories, "
    f"{statistics['registry_coverage']:.0%} of the registry exercised"
)
PY
