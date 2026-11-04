#!/usr/bin/env bash
# Build rv-guest-relay natively and exercise it against a unix echo server.
# Not an SPM target. The shipped binary is the static Linux build from
# Scripts/build-guest-relay.sh; the relay code is plain POSIX on both.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="$ROOT/Sources/rv-guest-relay"
OUT="${RV_GUEST_RELAY_TEST_OUT:-$ROOT/.build/rv-guest-relay-tests}"
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rv-relay.XXXXXX")"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

clang -O2 -std=c11 -Wall -Wextra -Werror -o "$OUT/rv-guest-relay" "$SRC/rv_guest_relay.c"
RELAY="$OUT/rv-guest-relay"
fails=0
check() {
  local name="$1"; shift
  if "$@"; then
    printf "ok   %s\n" "$name"
  else
    printf "FAIL %s\n" "$name"
    fails=$((fails + 1))
  fi
}

# Argument validation: every bad form exits 1 before printing ready.
rejects() {
  local out
  if out="$("$RELAY" "$@" 2>/dev/null)"; then return 1; fi
  [[ "$out" != *ready* ]]
}
# No pairs: the relay is the container's init process, so it reports ready and idles.
idles_without_pairs() {
  local fifo="$WORK/idle.out" pid line
  mkfifo "$fifo"
  "$RELAY" >"$fifo" 2>/dev/null &
  pid=$!
  PIDS+=("$pid")
  disown "$pid" 2>/dev/null || true
  IFS= read -r -t 5 line <"$fifo" || return 1
  [[ "$line" == ready ]] || return 1
  sleep 0.3
  kill -0 "$pid" 2>/dev/null
}
check "idles without pairs" idles_without_pairs
check "rejects missing =" rejects "8080"
check "rejects port 0" rejects "0=/tmp/x.sock"
check "rejects port 65536" rejects "65536=/tmp/x.sock"
check "rejects relative path" rejects "8080=relative.sock"
check "rejects trailing junk in port" rejects "80x=/tmp/x.sock"
check "rejects duplicate port" rejects "18080=/tmp/a.sock" "18080=/tmp/b.sock"
long_path="/$(printf 'a%.0s' $(seq 1 200))"
check "rejects over-long socket path" rejects "18081=$long_path"

# --exec-sized: exec at once without a tty; on a tty wait for a window size.
execs_without_tty() {
  [[ "$("$RELAY" --exec-sized /bin/echo direct </dev/null)" == direct ]]
}
check "exec-sized execs at once without a tty" execs_without_tty
waits_for_window_size() {
  local out
  out="$(python3 -I - "$RELAY" <<'PY2'
import fcntl, os, pty, struct, sys, termios, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], "--exec-sized", "/bin/stty", "size"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 0, 0, 0, 0))
time.sleep(0.3)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
out = b""
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
os.waitpid(pid, 0)
print(out.decode().strip())
PY2
)"
  [[ "$out" == "40 120" ]]
}
check "exec-sized waits for a window size" waits_for_window_size
rejects_exec_sized() {
  ! "$RELAY" --exec-sized relative </dev/null 2>/dev/null && ! "$RELAY" --exec-sized </dev/null 2>/dev/null
}
check "exec-sized rejects a missing or relative command" rejects_exec_sized

# Unix echo server, then the relay in front of it.
SOCK="$WORK/echo.sock"
python3 -I - "$SOCK" <<'PY' &
import os, socket, sys, threading
path = sys.argv[1]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(16)
def handle(conn):
    with conn:
        while True:
            data = conn.recv(65536)
            if not data:
                return
            conn.sendall(data)
while True:
    conn, _ = server.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
PIDS+=($!)
disown
for _ in $(seq 1 100); do [[ -S "$SOCK" ]] && break; sleep 0.05; done

PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
"$RELAY" "$PORT=$SOCK" > "$WORK/relay.out" 2> "$WORK/relay.err" &
RELAY_PID=$!
PIDS+=("$RELAY_PID")
disown
for _ in $(seq 1 100); do grep -q ready "$WORK/relay.out" 2>/dev/null && break; sleep 0.05; done
check "prints ready after binding" grep -qx ready "$WORK/relay.out"

roundtrip() {
  python3 -I - "$PORT" "$1" <<'PY'
import socket, sys
port, size = int(sys.argv[1]), int(sys.argv[2])
payload = bytes((i * 7 + 3) % 256 for i in range(size))
with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
    s.sendall(payload)
    s.shutdown(socket.SHUT_WR)
    got = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        got += chunk
sys.exit(0 if got == payload else 1)
PY
}
check "relays a small payload and half-close" roundtrip 11
check "relays a payload larger than the buffer" roundtrip 1048577
concurrent() {
  local pids=() ok=0
  for _ in 1 2 3 4 5 6 7 8; do roundtrip 200000 & pids+=($!); done
  for pid in "${pids[@]}"; do wait "$pid" || ok=1; done
  return "$ok"
}
check "relays eight concurrent connections" concurrent
loopback_only() {
  # The listener must be bound to 127.0.0.1, never the wildcard address.
  local listening
  listening="$(lsof -nP -a -p "$RELAY_PID" -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  [[ "$listening" == *"127.0.0.1:$PORT"* && "$listening" != *"*:$PORT"* ]]
}
check "binds loopback only" loopback_only

if [[ "$fails" -ne 0 ]]; then
  printf "rv-guest-relay tests: %d failed\n" "$fails"
  exit 1
fi
printf "rv-guest-relay tests: all passed\n"
