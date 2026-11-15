#!/usr/bin/env python3
"""Break one line at a time and record which tests notice.

This is a check on the suite, not part of the library: every mutation is applied to the
sources, the tests of the packages that hold the bindings run on the native backend, and the
sources are put back. The table it prints is the one the README quotes. Each break names the
test that has to go red, so a suite that goes red for the wrong reason is caught too.

    python3 scripts/check_mutations.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
PACKAGES = ["moonbitstack/moona2a", "moonbitstack/moona2a/asgi", "moonbitstack/moona2a/grpc"]

# (file, what it says, what it is changed to, what the change is, a test that must go red)
MUTATIONS: list[tuple[str, str, str, str, str]] = [
    (
        "binding.mbt",
        '-32001 | -32601 => { grpc: 5, name: "NOT_FOUND", http: 404, }',
        '-32001 | -32601 => { grpc: 5, name: "NOT_FOUND", http: 400, }',
        "an unknown task is a 400 on HTTP+JSON",
        "rest: an unknown task is a 404 carrying TASK_NOT_FOUND",
    ),
    (
        "binding.mbt",
        '{ grpc: 3, name: "INVALID_ARGUMENT", http: 400, }',
        '{ grpc: 9, name: "INVALID_ARGUMENT", http: 400, }',
        "invalid parameters are FAILED_PRECONDITION on gRPC",
        "grpc: a request that does not read is INVALID_ARGUMENT",
    ),
    (
        "binding.mbt",
        'fields.get("domain") is Some(String("a2a-protocol.org")) &&',
        "",
        "an ErrorInfo from any domain names an A2A error",
        "binding: a refusal read back from gRPC or HTTP+JSON takes the code its ErrorInfo names",
    ),
    (
        "grpc/server.mbt",
        "ctx.fail(@moona2a.Status::of(failure.code).grpc, failure.message)",
        "ctx.fail(@moona2a.Status::of(failure.code).http, failure.message)",
        "a gRPC refusal ends with the HTTP status as its code",
        "grpc: an unknown task fails NOT_FOUND with a TASK_NOT_FOUND ErrorInfo",
    ),
    (
        "grpc/server.mbt",
        "for detail in details {",
        "for detail in details[:0] {",
        "a gRPC refusal carries no ErrorInfo",
        "grpc: an unknown task fails NOT_FOUND with a TASK_NOT_FOUND ErrorInfo",
    ),
    (
        "asgi/rest.mbt",
        "      \"code\": Json::number(\n        status.http.to_double(),\n        repr=status.http.to_string(),\n      ),",
        "      \"code\": Json::number(\n        status.grpc.to_double(),\n        repr=status.grpc.to_string(),\n      ),",
        "an HTTP+JSON error body names the gRPC code",
        "rest: an unknown task is a 404 carrying TASK_NOT_FOUND",
    ),
    (
        "lifecycle.mbt",
        "      self.announce()\n      self.task = { ..self.task, status: update.status, }\n      self.server.record(self.task, event)\n      self.forward(event)",
        "      self.task = { ..self.task, status: update.status, }\n      self.server.record(self.task, event)\n      self.forward(event)\n      self.announce()",
        "a stream says a status changed before it says what the task is",
        "rest: a streaming send answers with StreamResponse events in the order they happened",
    ),
]


def run() -> tuple[int, list[str]]:
    failed: list[str] = []
    for package in PACKAGES:
        out = subprocess.run(
            ["moon", "test", "--target", "native", "-p", package],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        text = out.stdout + out.stderr
        if "Total tests:" not in text:
            # A mutation that does not build says nothing about the tests.
            return -1, ["the mutated sources did not build"]
        failed += [line.split('("')[1].split('")')[0] for line in text.splitlines() if '") failed' in line]
    return len(failed), sorted(set(failed))


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        backup = Path(tmp) / "src"
        shutil.copytree(SRC, backup)
        try:
            clean_count, clean_failed = run()
            if clean_count != 0:
                print("the tree is not green before the mutations:", clean_failed)
                return 1
            rows = []
            for name, old, new, what, expected in MUTATIONS:
                path = SRC / name
                text = path.read_text(encoding="utf-8")
                if old not in text:
                    print(f"!! {name}: the line to break is not there")
                    return 1
                path.write_text(text.replace(old, new, 1), encoding="utf-8", newline="\n")
                count, failed = run()
                shutil.copy2(backup / name, path)
                rows.append((name, what, count, failed, expected))
                print(f"{name}: {what}\n  -> {count} failed: {', '.join(failed) or 'NOTHING'}\n", flush=True)
        finally:
            for name, *_ in MUTATIONS:
                shutil.copy2(backup / name, SRC / name)
    print("\n| file | break | tests that went red |")
    print("|:--|:--|:--|")
    for name, what, count, failed, _ in rows:
        print(f"| `{name}` | {what} | {count}: {', '.join(f'`{f}`' for f in failed) or '**none**'} |")
    bad = [what for _, what, count, failed, expected in rows if count <= 0 or expected not in failed]
    for what in bad:
        print(f"not caught by the test named for it: {what}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
