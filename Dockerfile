# The rclone version is chosen by the workflow (the newest release); `latest` is only the default for a local build.
ARG RCLONE_VERSION=latest
FROM rclone/rclone:${RCLONE_VERSION}

LABEL maintainer="German Casares"

ENV SYNC_SRC=
ENV SYNC_DEST=
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

COPY entrypoint.sh sync.sh sync-abort.sh healthcheck.sh /
RUN chmod +x /entrypoint.sh /sync.sh /sync-abort.sh /healthcheck.sh

VOLUME ["/config", "/logs"]

# Healthy while crond runs (scheduled mode) or a sync runs (the boot sync, or SYNC_ONCE / no CRON).
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]

CMD [""]
