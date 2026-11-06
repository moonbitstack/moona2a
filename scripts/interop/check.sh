#!/usr/bin/env bash
# Run the two interoperability directions against the official Python SDK.
#
#   scripts/interop/check.sh
#
# Direction one: the MoonBit client calls an agent the Python SDK serves.
# Direction two: the Python SDK's client calls the MoonBit server, and checks what comes back.
#
# The Python side needs `a2a-sdk` (1.3 or later), `fastapi`, `uvicorn`, `httpx` and `sse-starlette`:
#
#     uv venv && uv pip install "a2a-sdk>=1.3" fastapi uvicorn httpx sse-starlette
#
# Point A2A_PYTHON at that environment's interpreter; the default is the one on PATH.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python="${A2A_PYTHON:-python}"
moon_port="${INTEROP_MOON_PORT:-9999}"
python_port="${INTEROP_PY_PORT:-8001}"

wait_for_card() {
  for _ in $(seq 1 100); do
    if curl -fsS "$1/.well-known/agent-card.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "no card at $1" >&2
  return 1
}

echo "== building both servers =="
(cd "$repo_root" && moon build src/examples/05-conformance --target native)
# Windows names the binary with an extension and the other systems do not.
server="$repo_root/_build/native/debug/build/examples/05-conformance/05-conformance"
if [[ -x "$server.exe" ]]; then
  server="$server.exe"
fi

echo "== direction one: the MoonBit client calls the Python agent =="
"$python" "$repo_root/scripts/interop/py_server.py" --port "$python_port" &
python_pid=$!
cleanup() {
  kill "$python_pid" 2>/dev/null || true
  wait "$python_pid" 2>/dev/null || true
}
trap cleanup EXIT
wait_for_card "http://127.0.0.1:$python_port"
(cd "$repo_root" && moon run src/examples/06-interop --target native -- \
  "http://127.0.0.1:$python_port/a2a/jsonrpc")
cleanup
trap - EXIT

echo "== direction two: the Python client calls the MoonBit agent =="
"$server" &
moon_pid=$!
cleanup() {
  kill "$moon_pid" 2>/dev/null || true
  wait "$moon_pid" 2>/dev/null || true
}
trap cleanup EXIT
wait_for_card "http://127.0.0.1:$moon_port"
"$python" "$repo_root/scripts/interop/py_client.py" --url "http://127.0.0.1:$moon_port"

echo "interoperability: both directions ok"
