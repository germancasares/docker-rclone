#!/bin/bash
# CRON_ABORT: stop the running sync. sync.sh catches TERM, stops rclone and reports the abort to healthchecks.io.

if [ ! -f /tmp/sync.pid ]; then
  echo "INFO: No outstanding sync $(date)"
  exit 0
fi

pid=$(cat /tmp/sync.pid)
echo "INFO: Stopping sync pid $pid $(date)"
if ! kill -TERM "$pid" 2>/dev/null; then
  echo "INFO: Sync pid $pid is no longer running"
  rm -f /tmp/sync.pid
  exit 0
fi

# Give sync.sh up to 60 s to stop rclone and report; then force it.
for _ in $(seq 60); do
  kill -0 "$pid" 2>/dev/null || exit 0
  sleep 1
done
echo "WARNING: Sync pid $pid did not stop within 60 s; killing it and its rclone"
pkill -KILL -P "$pid" || true
kill -KILL "$pid" 2>/dev/null || true
rm -f /tmp/sync.pid
