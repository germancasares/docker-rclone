#!/bin/bash
# Smoke test of a built image with local folders only (no cloud remote):
# a sync, an empty source, the run lock, the health check, and CRON_ABORT during the boot sync.
# Usage: tests/smoke.sh <image>
set -euo pipefail

IMAGE=$1
WORK=$(mktemp -d)
PORT=8099
NAME=rclone-smoke
HC=http://127.0.0.1:$PORT
HC_PID=

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  [ -n "$HC_PID" ] && kill "$HC_PID" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*"
  [ -f "$WORK/pings" ] && { echo "--- pings"; cat "$WORK/pings"; }
  docker logs "$NAME" 2>&1 | tail -30 || true
  exit 1
}

# wait_for <seconds> <command…>: retry once a second until the command succeeds.
wait_for() {
  local seconds=$1
  shift
  for _ in $(seq "$seconds"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

mkdir -p "$WORK/config/rclone" "$WORK/src" "$WORK/empty"
: >"$WORK/config/rclone/rclone.conf"
echo hello >"$WORK/src/a.txt"
head -c 3000000 /dev/urandom >"$WORK/src/big.bin"
chmod -R 777 "$WORK"

# A fake healthchecks.io that records the path of each request.
python3 - "$PORT" "$WORK/pings" <<'EOF' &
import http.server
import sys

port, out = int(sys.argv[1]), sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def hit(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open(out, "a") as f:
            f.write(self.path + "\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")

    do_GET = do_POST = hit

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
EOF
HC_PID=$!
touch "$WORK/pings"
wait_for 10 python3 -c "import urllib.request; urllib.request.urlopen('$HC/ready')" || fail "fake healthchecks did not start"

run_once() {
  docker run --rm --network host -v "$WORK/config:/config" -v "$WORK:/w" -e UID=1001 -e GID=1001 "$@" "$IMAGE"
}

echo "== 1. a single sync copies the files and reports start and success"
run_once -e SYNC_SRC=/w/src -e SYNC_DEST=/w/dest1 -e CHECK_URL="$HC/ok" | tee "$WORK/out1"
[ -f "$WORK/dest1/a.txt" ] && [ -f "$WORK/dest1/big.bin" ] || fail "files were not synced"
[ "$(stat -c %u "$WORK/dest1/a.txt")" = 1001 ] || fail "the sync did not run as UID 1001"
grep -qx "/ok/start" "$WORK/pings" && grep -qx "/ok" "$WORK/pings" || fail "start or success ping missing"

echo "== 2. an empty source is skipped and reported as a failure"
run_once -e SYNC_SRC=/w/empty -e SYNC_DEST=/w/dest1 -e CHECK_URL="$HC/empty" | tee "$WORK/out2"
grep -q "Source directory is empty" "$WORK/out2" || fail "the empty source was not detected"
[ -f "$WORK/dest1/a.txt" ] || fail "an empty source deleted the destination"
grep -qx "/empty/fail" "$WORK/pings" || fail "the empty source was not reported as a failure"

echo "== 3. a slow boot sync: health check, run lock, CRON_ABORT, then cron keeps running"
docker run -d --name "$NAME" --network host -v "$WORK/config:/config" -v "$WORK:/w" \
  -e UID=1001 -e GID=1001 -e SYNC_SRC=/w/src -e SYNC_DEST=/w/dest3 -e SYNC_OPTS="-v --bwlimit 20k" \
  -e CRON="0 0 1 1 *" -e FORCE_SYNC=1 -e CHECK_URL="$HC/slow" "$IMAGE" >/dev/null
wait_for 30 docker exec "$NAME" test -f /tmp/sync.pid || fail "the boot sync did not start"
docker exec "$NAME" /healthcheck.sh || fail "unhealthy during the boot sync"
docker exec -u 1001 "$NAME" /sync.sh | tee "$WORK/out3"
grep -q "is still running" "$WORK/out3" || fail "a second sync was not blocked by the lock"
docker exec "$NAME" /sync-abort.sh
wait_for 30 grep -qx "/slow/fail" "$WORK/pings" || fail "the abort was not reported as a failure"
docker logs "$NAME" 2>&1 | grep -q "Stop requested" || fail "sync.sh did not handle the stop"
wait_for 30 docker exec "$NAME" pgrep -x crond || fail "crond did not start after the aborted boot sync"
[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || fail "the container exited after the abort"
docker exec "$NAME" /healthcheck.sh || fail "unhealthy while crond runs"
docker exec "$NAME" test ! -f /tmp/sync.pid || fail "sync.pid was left behind"

echo "== all smoke tests passed"
