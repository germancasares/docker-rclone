FROM rclone/rclone

LABEL maintainer="German Casares"

ENV SYNC_SRC=
ENV SYNC_DEST=
# ENV SYNC_OPTS=--exclude-from /config/rclone/exclude-list.txt --delete-excluded -v
ENV SYNC_OPTS=-v
ENV SYNC_OPTS_EVAL=
ENV SYNC_ONCE=
ENV RCLONE_CMD=sync
ENV RCLONE_DIR_CMD=ls
ENV RCLONE_DIR_CMD_DEPTH=-1
ENV RCLONE_DIR_CHECK_SKIP=
ENV RCLONE_OPTS="--config /config/rclone/rclone.conf"
ENV OUTPUT_LOG=
ENV PRE_LOG_NAME=
ENV ROTATE_LOG=
ENV CRON=
ENV CRON_ABORT=
ENV FORCE_SYNC=
ENV CHECK_URL=
ENV FAIL_URL=
ENV HC_LOG=
ENV TZ=
ENV UID=
ENV GID=
ENV SUCCESS_CODES="0"

RUN apk --no-cache add bash wget dcron tzdata

COPY entrypoint.sh /
COPY sync.sh /
COPY sync-abort.sh /

VOLUME ["/config"]
VOLUME ["/logs"]

ENTRYPOINT ["/entrypoint.sh"]

CMD [""]
