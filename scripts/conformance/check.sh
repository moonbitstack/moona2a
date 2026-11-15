#!/usr/bin/env bash
# Run the official Agent2Agent conformance suite against the example server in this repository.
#
# The suite is fetched at a pinned commit, so a run here and a run in CI judge the same thing. It
# drives the server over every binding the card lists: JSON-RPC and HTTP+JSON on the port below,
# gRPC on the next one.
#
# Usage: scripts/conformance/check.sh [--level must|should|may] [--transport jsonrpc,grpc,http_json]
# Exit status: 0 when every failure is one `scripts/conformance/expected.txt` explains.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
suite_repo="https://github.com/a2aproject/a2a-tck.git"
suite_commit="70f6f73c30208e80c889141907e094899e6e9f05"
workdir="${CONFORMANCE_WORKDIR:-${TMPDIR:-/tmp}/moona2a-conformance}"
port="${CONFORMANCE_PORT:-9999}"

level=""
transport=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level)
      level="$2"
      shift 2
      ;;
    --transport)
      transport="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required to build the suite: https://docs.astral.sh/uv/" >&2
  exit 2
fi

echo "== building the server =="
(cd "$repo_root" && moon build src/examples/05-conformance --target native)
# Windows names the binary with an extension and the other systems do not.
server="$repo_root/_build/native/debug/build/examples/05-conformance/05-conformance"
if [[ -x "$server.exe" ]]; then
  server="$server.exe"
fi

mkdir -p "$workdir"
if [[ ! -d "$workdir/a2a-tck/.git" ]]; then
  echo "== fetching the suite at $suite_commit =="
  git clone "$suite_repo" "$workdir/a2a-tck"
  git -C "$workdir/a2a-tck" checkout --detach "$suite_commit"
fi
if [[ ! -x "$workdir/a2a-tck/.venv/bin/python" && ! -x "$workdir/a2a-tck/.venv/Scripts/python.exe" ]]; then
  echo "== installing the suite =="
  (cd "$workdir/a2a-tck" && uv venv && uv pip install -e .)
fi

suite_python="$workdir/a2a-tck/.venv/bin/python"
if [[ ! -x "$suite_python" ]]; then
  suite_python="$workdir/a2a-tck/.venv/Scripts/python.exe"
fi

echo "== starting the server on port $port =="
"$server" &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

# The card is the server's own readiness signal: it answers only once the listener is up.
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$port/.well-known/agent-card.json" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

echo "== running the suite =="
suite_args=(--sut-host "http://127.0.0.1:$port")
if [[ -n "$level" ]]; then
  suite_args+=(--level "$level")
fi
if [[ -n "$transport" ]]; then
  suite_args+=(--transport "$transport")
fi
log="$workdir/run.log"
set +e
(cd "$workdir/a2a-tck" && "$suite_python" ./run_tck.py "${suite_args[@]}") 2>&1 | tee "$log"
set -e

# The suite's exit status counts every failure; `expected.txt` names the ones this server does
# not pass and why, so the run fails only on a failure nobody has explained, or on an explained
# one that no longer happens.
expected="$repo_root/scripts/conformance/expected.txt"
failed="$(grep -E '^FAILED tests/' "$log" | sed -E 's/^FAILED ([^ ]+).*/\1/' | sort -u)"
known="$(grep -vE '^[[:space:]]*(#|$)' "$expected" | sed -E 's/[[:space:]]+#.*$//' | sort -u)"
unexpected="$(comm -23 <(printf '%s\n' "$failed" | sed '/^$/d') <(printf '%s\n' "$known" | sed '/^$/d'))"
fixed="$(comm -13 <(printf '%s\n' "$failed" | sed '/^$/d') <(printf '%s\n' "$known" | sed '/^$/d'))"
if [[ -n "$transport" || -n "$level" ]]; then
  # A narrowed run does not reach every listed test, so a listed one missing says nothing.
  fixed=""
fi
status=0
if [[ -n "$unexpected" ]]; then
  echo "== failures expected.txt does not explain =="
  echo "$unexpected"
  status=1
fi
if [[ -n "$fixed" ]]; then
  echo "== listed in expected.txt but passing now; take them out =="
  echo "$fixed"
  status=1
fi
if [[ $status -eq 0 ]]; then
  echo "conformance: every failure is one expected.txt explains"
fi
exit $status
