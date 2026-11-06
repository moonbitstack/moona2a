#!/usr/bin/env bash
# Run the official Agent2Agent conformance suite against the example server in this repository.
#
# The suite is fetched at a pinned commit, so a run here and a run in CI judge the same thing. It
# drives the server over the JSON-RPC transport, which is the one this library speaks.
#
# Usage: scripts/conformance/check.sh [--level must|should|may] [--suite-tag <tag>]
# Exit status is the suite's own: 0 only when every automated check passed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
suite_repo="https://github.com/a2aproject/a2a-tck.git"
suite_commit="70f6f73c30208e80c889141907e094899e6e9f05"
workdir="${CONFORMANCE_WORKDIR:-${TMPDIR:-/tmp}/moona2a-conformance}"
port="${CONFORMANCE_PORT:-9999}"

level=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level)
      level="$2"
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
"$repo_root/_build/native/debug/build/examples/05-conformance/05-conformance.exe" &
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
suite_args=(--sut-host "http://127.0.0.1:$port" --transport jsonrpc)
if [[ -n "$level" ]]; then
  suite_args+=(--level "$level")
fi
(cd "$workdir/a2a-tck" && "$suite_python" ./run_tck.py "${suite_args[@]}")
