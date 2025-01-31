#!/bin/bash

set -e
# Function to check if return code is in the success codes list
is_success_code() {
  local code=$1
  for success_code in $SUCCESS_CODES; do
    if [ "$success_code" = "$code" ]; then
      return 0  # Match found, return success
    fi
  done
  return 1  # No match found, return failure
}

# Function to signal the start of sync.sh to healthchecks.io
signal_start_healthcheck() {
  if [ -n "$CHECK_URL" ]; then
    echo "INFO: Sending start signal to healthchecks.io"
    wget "$CHECK_URL/start" -O /dev/null
  fi
}

# Function to delete logs by user request
delete_old_logs() {
  if [ -n "${ROTATE_LOG##*[!0-9]*}" ]; then
    echo "INFO: Removing logs older than $ROTATE_LOG day(s)..."
    touch /logs/tmp.txt && find /logs/*.txt -mtime +$ROTATE_LOG -type f -delete && rm -f /logs/tmp.txt
  fi
}

# Function to evaluate sync options and return SYNC_OPTS_ALL
evaluate_sync_options() {
  if [ -n "$SYNC_OPTS_EVAL" ]; then
    SYNC_OPTS_EVALUALTED=$(eval echo "$SYNC_OPTS_EVAL")
    SYNC_OPTS_ALL="${SYNC_OPTS} ${SYNC_OPTS_EVALUALTED}"
  else
    SYNC_OPTS_ALL="$SYNC_OPTS"
  fi

  export SYNC_OPTS_ALL
}

# Function to handle log evaluation and rclone command execution
execute_rclone() {
  if [ -n "$HC_PROGRESS" ]; then
    echo "INFO: Starting rclone API on a temporary socket"
    rclone rcd --rc --rc-addr=localhost:5572 &
    sleep 10

    # Function to ping Healthchecks with current progress and speed
    ping_healthchecks() {
      while true; do
        STATS=$(curl -s -X POST http://localhost:5572/core/stats)
        TRANSFERRED=$(echo $STATS | jq -r '.stats.bytes')
        TOTAL=$(echo $STATS | jq -r '.transferring[] | select(.name=="total") | .size')
        PROGRESS_PERCENT=0
        ETA="unknown"
        if [ -n "$TOTAL" ] && [ "$TOTAL" -ne 0 ]; then
          PROGRESS_PERCENT=$((100 * TRANSFERRED / TOTAL))
          SPEED=$(echo $STATS | jq -r '.stats.speed')
          if [ "$SPEED" -gt 0 ]; then
            REMAINING=$((TOTAL - TRANSFERRED))
            ETA=$(date -u -d @$(($REMAINING / $SPEED)) +"%Hh%Mm%Ss")
          fi
        fi
        CHECKS=$(echo $STATS | jq -r '.checks')
        TRANSFERRED_FILES=$(echo $STATS | jq -r '.transferred')
        ELAPSED_TIME=$(echo $STATS | jq -r '.elapsedTime')

        DATA="Transferred: $(numfmt --to=iec $TRANSFERRED) / $(numfmt --to=iec $TOTAL), ${PROGRESS_PERCENT}%, $(numfmt --to=iec $SPEED)/s, ETA $ETA
Checks: $CHECKS
Transferred: $TRANSFERRED_FILES
Elapsed time: $ELAPSED_TIME"

        wget "$HC_PROGRESS" -O /dev/null --post-data="$DATA"
        sleep 60  # Adjust the interval as needed
      done
    }

    ping_healthchecks &
    PING_PID=$!
  fi

  if [ -n "$OUTPUT_LOG" ]; then
    d=$(date +%Y_%m_%d-%H_%M_%S)
    LOG_FILE="/logs/$PRE_LOG_NAME$d.txt"
    echo "INFO: Log file output to $LOG_FILE"
    echo "INFO: Starting rclone $RCLONE_CMD $SYNC_SRC $SYNC_DEST $RCLONE_OPTS $SYNC_OPTS_ALL --log-file=${LOG_FILE}"
    set +e
    eval "rclone $RCLONE_CMD $SYNC_SRC $SYNC_DEST $RCLONE_OPTS $SYNC_OPTS_ALL --log-file=${LOG_FILE}"
    export RETURN_CODE=$?
    set -e
  else
    echo "INFO: Starting rclone $RCLONE_CMD $SYNC_SRC $SYNC_DEST $RCLONE_OPTS $SYNC_OPTS_ALL"
    set +e
    eval "rclone $RCLONE_CMD $SYNC_SRC $SYNC_DEST $RCLONE_OPTS $SYNC_OPTS_ALL"
    export RETURN_CODE=$?
    set -e
  fi

  if [ -n "$HC_PROGRESS" ]; then
    kill $PING_PID
  fi

  echo "INFO: $RCLONE_CMD finished with return code: $RETURN_CODE"
}

# Function to wrap up healthchecks.io call with complete or failure signal
signal_finished_healthcheck() {
  if [ -z "$CHECK_URL" ]; then
    echo "INFO: Define CHECK_URL with https://healthchecks.io to monitor $RCLONE_CMD job"
  else
    if is_success_code "$RETURN_CODE"; then
      if [ -n "$OUTPUT_LOG" ] && [ -n "$HC_LOG" ] && [ -f "$LOG_FILE" ]; then
        echo "INFO: Sending complete signal with logs to healthchecks.io"
        m=$(tail -c 10000 "$LOG_FILE")
        wget "$CHECK_URL" -O /dev/null --post-data="$m"
      else
        echo "INFO: Sending complete signal to healthchecks.io"
        wget "$CHECK_URL" -O /dev/null --post-data="SUCCESS"
      fi
    else
      if [ -n "$OUTPUT_LOG" ] && [ -n "$HC_LOG" ] && [ -f "$LOG_FILE" ]; then
        echo "INFO: Sending failure signal with logs to healthchecks.io"
        m=$(tail -c 10000 "$LOG_FILE")
        wget "$FAIL_URL" -O /dev/null --post-data="$m"
      else
        echo "INFO: Sending failure signal to healthchecks.io"
        wget "$FAIL_URL" -O /dev/null --post-data="Check container logs"
      fi
    fi
  fi
}

echo "INFO: Starting sync.sh pid $$ $(date)"

if [ `lsof | grep $0 | wc -l | tr -d ' '` -gt 1 ]
then
  echo "WARNING: A previous $RCLONE_CMD is still running. Skipping new $RCLONE_CMD command."
else

  # Signal start oh sync.sh to healthchecks.io
  signal_start_healthcheck

  # Delete logs by user request
  delete_old_logs

  echo $$ > /tmp/sync.pid

  # Evaluate any sync options
  evaluate_sync_options
  echo "INFO: Evaluated SYNC_OPTS_ALL to: $SYNC_OPTS_ALL"

  if [ -n "$RCLONE_DIR_CHECK_SKIP" ]
  then
    echo "INFO: Skipping source directory check..."
    execute_rclone
  else
    set +e
    if test "$(rclone --max-depth $RCLONE_DIR_CMD_DEPTH $RCLONE_DIR_CMD "$(eval echo $SYNC_SRC)" $RCLONE_OPTS)";
    then
      set -e
      echo "INFO: Source directory is not empty and can be processed without clear loss of data"
      execute_rclone
    else
      echo "WARNING: Source directory is empty. Skipping $RCLONE_CMD command."
    fi
  fi

  # Wrap up healthchecks.io call with complete or failure signal
  signal_finished_healthcheck

rm -f /tmp/sync.pid

fi
