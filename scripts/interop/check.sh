#!/usr/bin/env bash
# The zRPC interoperability check, both directions.
#
# One end is this library; the other is a gRPC server and client written against
# the Go implementation. They meet on a TCP port with nothing in between: no
# proxy, no translation layer, no shared code. What a green run means is that the
# frames this library puts on the wire are the frames a gRPC peer expects, and
# that it can read the ones a peer sends back.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
moon_pid=""
go_pid=""

cleanup() {
  [ -n "$moon_pid" ] && kill "$moon_pid" 2>/dev/null || true
  [ -n "$go_pid" ] && kill "$go_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

ext=""
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) ext=".exe" ;;
esac

go_end="$work/go-interop$ext"
moon_end="$root/_build/native/debug/build/examples/15-interop/15-interop$ext"

# Wait for a listener to answer on `port`, or fail rather than wait forever: a
# server that never bound is a build problem, not a slow one.
wait_for_port() {
  local port=$1
  for _ in $(seq 1 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3<&- 3>&-
      return 0
    fi
    sleep 0.1
  done
  echo "port $port never opened" >&2
  return 1
}

# Compare a reply against what the peer should have echoed.
expect_reply() {
  local label=$1 expected=$2 actual=$3
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $label: expected '$expected', got '$actual'" >&2
    exit 1
  fi
  echo "   ok: $actual"
}

echo "== build the Go end"
(cd "$root/scripts/interop" && go build -o "$go_end" .)

echo "== build this library's end"
(cd "$root" && moon build --target native src/examples/15-interop >/dev/null)

echo "== go client -> this library's server"
"$moon_end" serve 12011 >"$work/moon-serve.log" 2>&1 &
moon_pid=$!
wait_for_port 12011
reply=$("$go_end" -mode call -addr 127.0.0.1:12011 -msg "hi-from-go")
kill "$moon_pid" 2>/dev/null || true
wait "$moon_pid" 2>/dev/null || true
moon_pid=""
expect_reply "go client -> moonzero server" "reply hi-from-go" "$reply"

echo "== this library's client -> go server"
"$go_end" -mode serve -addr 127.0.0.1:12012 >"$work/go-serve.log" 2>&1 &
go_pid=$!
wait_for_port 12012
reply=$("$moon_end" call 12012 "hi-from-moonbit")
kill "$go_pid" 2>/dev/null || true
wait "$go_pid" 2>/dev/null || true
go_pid=""
expect_reply "moonzero client -> go server" "reply hi-from-moonbit" "$reply"

echo "interop ok"
