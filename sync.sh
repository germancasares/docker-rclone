#!/bin/bash
# One rclone sync/copy/move run, started by cron, by FORCE_SYNC at boot, or once when there is no CRON.
# With CHECK_URL it reports to healthchecks.io: start, then success or failure. A stop (CRON_ABORT) reports a failure.

set -e

FAIL_URL=${FAIL_URL:-${CHECK_URL:+$CHECK_URL/fail}}
RETURN_CODE=
RCLONE_PID=
LOG_FILE=

# True if the rclone exit code is listed in SUCCESS_CODES (space-separated, default "0").
is_success_code() {
  local code=$1
  for success_code in $SUCCESS_CODES; do
    [ "$success_code" = "$code" ] && return 0
  done
  return 1
}

# POST a body to a healthchecks.io URL. A failed ping is logged (without the URL) but never fails the sync.
ping_hc() {
  wget -q -T 10 -t 3 -O /dev/null --post-data="$2" "$1" || echo "WARNING: healthchecks.io ping failed"
}

# report success|fail <message>: sends the end of the rclone log instead of the message when HC_LOG is set.
report() {
  [ -z "$CHECK_URL" ] && return 0
  local url=$CHECK_URL kind=complete
  if [ "$1" = fail ]; then
    url=$FAIL_URL
    kind=failure
  fi
  if [ -n "$OUTPUT_LOG" ] && [ -n "$HC_LOG" ] && [ -f "$LOG_FILE" ]; then
    echo "INFO: Sending $kind signal with logs to healthchecks.io"
    ping_hc "$url" "$(tail -c 10000 "$LOG_FILE")"
  else
    echo "INFO: Sending $kind signal to healthchecks.io"
    ping_hc "$url" "$2"
  fi
}

# Runs rclone in the background and waits, so a stop request is handled at once instead of after rclone ends.
run_rclone() {
  local cmd="rclone $RCLONE_CMD $SYNC_SRC $SYNC_DEST $RCLONE_OPTS $SYNC_OPTS_ALL"
  if [ -n "$OUTPUT_LOG" ]; then
    LOG_FILE="/logs/$PRE_LOG_NAME$(date +%Y_%m_%d-%H_%M_%S).txt"
    echo "INFO: Log file output to $LOG_FILE"
    cmd="$cmd --log-file=$LOG_FILE"
  fi
  echo "INFO: Starting $cmd"
  eval "$cmd &"
  RCLONE_PID=$!
  set +e
  wait "$RCLONE_PID"
  RETURN_CODE=$?
  set -e
  RCLONE_PID=
  echo "INFO: $RCLONE_CMD finished with return code: $RETURN_CODE"
}

# CRON_ABORT (sync-abort.sh) sends TERM: stop rclone, report the abort, and exit.
abort() {
  echo "WARNING: Stop requested $(date). Stopping rclone."
  if [ -n "$RCLONE_PID" ]; then
    kill -TERM "$RCLONE_PID" 2>/dev/null || true
    wait "$RCLONE_PID" 2>/dev/null || true
  fi
  report fail "Stopped at $(date) before the $RCLONE_CMD finished (CRON_ABORT)"
  exit 143
}

echo "INFO: Starting sync.sh pid $$ $(date)"

# One run at a time. The lock is held until this script and the rclone it starts have both exited.
exec 9>>/tmp/sync.lock
if ! flock -n 9; then
  echo "WARNING: A previous $RCLONE_CMD is still running. Skipping new $RCLONE_CMD command."
  exit 0
fi

echo $$ >/tmp/sync.pid
trap 'rm -f /tmp/sync.pid' EXIT
trap abort TERM INT

if [ -n "$CHECK_URL" ]; then
  echo "INFO: Sending start signal to healthchecks.io"
  ping_hc "$CHECK_URL/start" ""
fi

# Delete old logs by user request
if [ -n "${ROTATE_LOG##*[!0-9]*}" ]; then
  echo "INFO: Removing logs older than $ROTATE_LOG day(s)..."
  find /logs -maxdepth 1 -name '*.txt' -type f -mtime +"$ROTATE_LOG" -delete
fi

# Evaluate any sync options
if [ -n "$SYNC_OPTS_EVAL" ]; then
  SYNC_OPTS_EVALUATED=$(eval echo $SYNC_OPTS_EVAL)
  echo "INFO: Evaluated SYNC_OPTS_EVAL to: $SYNC_OPTS_EVALUATED"
  SYNC_OPTS_ALL="$SYNC_OPTS $SYNC_OPTS_EVALUATED"
else
  SYNC_OPTS_ALL="$SYNC_OPTS"
fi

if [ -n "$RCLONE_DIR_CHECK_SKIP" ]; then
  echo "INFO: Skipping source directory check..."
  run_rclone
else
  # One entry is enough: `head` ends the listing at the first line instead of walking the whole source.
  first_entry=$(rclone --max-depth "$RCLONE_DIR_CMD_DEPTH" "$RCLONE_DIR_CMD" "$(eval echo $SYNC_SRC)" $RCLONE_OPTS | head -n 1) || true
  if [ -n "$first_entry" ]; then
    echo "INFO: Source directory is not empty and can be processed without clear loss of data"
    run_rclone
  else
    echo "WARNING: Source directory is empty or unreadable. Skipping $RCLONE_CMD command."
    RETURN_CODE=empty
  fi
fi

# Wrap up the healthchecks.io call with a complete or failure signal
if [ -z "$CHECK_URL" ]; then
  echo "INFO: Define CHECK_URL with https://healthchecks.io to monitor $RCLONE_CMD job"
elif [ "$RETURN_CODE" = empty ]; then
  report fail "Source directory is empty or unreadable; nothing was synced"
elif is_success_code "$RETURN_CODE"; then
  report success "SUCCESS"
else
  report fail "Check container logs"
fi
