#!/bin/bash
# Healthy when crond is running (scheduled mode) or a sync is in progress (the boot sync runs before crond starts,
# and SYNC_ONCE / no CRON runs a single sync without crond).

pgrep -x crond >/dev/null && exit 0
[ -f /tmp/sync.pid ] && kill -0 "$(cat /tmp/sync.pid)" 2>/dev/null && exit 0
echo "crond is not running and no sync is in progress"
exit 1
