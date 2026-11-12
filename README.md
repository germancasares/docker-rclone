# docker-rclone

A Docker image that runs an [rclone](https://rclone.org) `sync`, `copy` or `move` on a cron schedule, with
[healthchecks.io](https://healthchecks.io) monitoring.

```
ghcr.io/germancasares/docker-rclone:latest
```

- Built on the official [`rclone/rclone`](https://hub.docker.com/r/rclone/rclone) image, for `linux/amd64` and
  `linux/arm64`.
- Always on the newest rclone: GitHub Actions checks for a new rclone release every Monday and publishes it (see
  [How the image is updated](#how-the-image-is-updated)).
- The image's version label (`org.opencontainers.image.version`) is the rclone version it contains.

## What a run does

1. Takes a lock, so two runs never overlap. A run that starts while another is going logs a warning and exits.
2. Sends a start signal to `CHECK_URL`.
3. Deletes logs older than `ROTATE_LOG` days.
4. Checks that the source is not empty (it stops at the first file found). An empty or unreadable source is not
   synced, so it can't wipe the destination; the run is reported as a failure.
5. Runs `rclone <RCLONE_CMD> <SYNC_SRC> <SYNC_DEST> <RCLONE_OPTS> <SYNC_OPTS> <SYNC_OPTS_EVAL>`.
6. Reports success or failure to healthchecks.io, by the exit code (see `SUCCESS_CODES`).

`CRON_ABORT` stops a run that is still going (for example, so a sync doesn't use the bandwidth during the day). The
stopped run is reported to healthchecks.io as a failure straight away.

## Configure rclone

rclone reads its remotes from `/config/rclone/rclone.conf`. Mount a folder at `/config` that contains
`rclone/rclone.conf`.

To create the file, start the container without `SYNC_SRC` and `SYNC_DEST`: it runs `rclone config` interactively.

```sh
docker run --rm -it -v /path/to/config:/config ghcr.io/germancasares/docker-rclone
```

## Example (Docker Compose)

```yaml
services:
  pictures-to-pcloud:
    image: ghcr.io/germancasares/docker-rclone:latest
    container_name: rclone-pictures-to-pcloud
    restart: unless-stopped
    volumes:
      - /volume1/docker/rclone/config:/config
      - /volume1/docker/rclone/logs/pictures:/logs
      - /volume1/photo:/data:ro
    environment:
      UID: 1026
      GID: 100
      TZ: America/Chicago
      SYNC_SRC: '"LocalDisk:/data"'
      SYNC_DEST: '"pCloud:/Pictures"'
      SYNC_OPTS: --exclude-from /config/rclone/exclude-list.txt --delete-excluded --max-delete 500 -v
      CRON: '@daily'
      CRON_ABORT: '0 8 * * *'
      FORCE_SYNC: 'true'
      OUTPUT_LOG: 'true'
      ROTATE_LOG: 30
      CHECK_URL: https://hc-ping.com/<your-check-uuid>
```

`--max-delete 500` is a safety net for `sync`: if a share is wiped or encrypted on the source, rclone stops deleting
on the destination after 500 files, the run fails, and healthchecks.io reports it. Without it, the loss is copied to
the destination on the next run.

[`exclude-list.txt`](exclude-list.txt) is an example exclude list (Synology, macOS and Windows system files). Copy it
to your config folder to use it as above; the image doesn't contain it.

## Settings

| Name | Default | Description |
|---|---|---|
| `SYNC_SRC` | | Source, for example `"LocalDisk:/data"`. Required to sync. Wrap paths with spaces in quotes. |
| `SYNC_DEST` | | Destination, for example `"pCloud:/Pictures"`. Required to sync. Wrap paths with spaces in quotes. |
| `RCLONE_CMD` | `sync` | `sync`, `copy` or `move`. |
| `SYNC_OPTS` | `-v` | Extra rclone options. |
| `SYNC_OPTS_EVAL` | | Extra rclone options that are evaluated like a shell string right before each run, then added to `SYNC_OPTS`. For example ``--backup-dir "pCloud:/_deleted/`date -I`"``. |
| `RCLONE_OPTS` | `--config /config/rclone/rclone.conf` | Options added to every rclone call, including the source check. |
| `CRON` | | Cron schedule, for example `0 0 * * *`, or `@yearly` `@monthly` `@weekly` `@daily` `@hourly`. Without it the container syncs once and exits. |
| `CRON_ABORT` | | Cron schedule to stop a run that is still going, for example `0 8 * * *`. |
| `FORCE_SYNC` | | Set to sync once when the container starts, then follow `CRON`. |
| `SYNC_ONCE` | | With `FORCE_SYNC`, stop the container after that first sync. |
| `UID`, `GID` | | Run rclone as this user and group (both or neither). `/config` and `/logs` must be writable by them. Without them, rclone runs as root. |
| `TZ` | | Time zone for the schedules and the log names, for example `America/Chicago`. |
| `CHECK_URL` | | healthchecks.io ping URL. The run sends `/start`, then the URL itself on success. |
| `FAIL_URL` | `CHECK_URL/fail` | URL for a failure. |
| `HC_LOG` | | With `OUTPUT_LOG`, send the last 10 KB of the rclone log with the success or failure signal. |
| `SUCCESS_CODES` | `0` | rclone exit codes counted as success, space-separated, for example `0 9`. |
| `OUTPUT_LOG` | | Write each run's rclone log to `/logs/<PRE_LOG_NAME><date>.txt`. |
| `PRE_LOG_NAME` | | Text in front of each log file name. |
| `ROTATE_LOG` | | Delete logs in `/logs` older than this many days. |
| `RCLONE_DIR_CMD` | `ls` | How the source is checked for files: `ls` or `lsf`. |
| `RCLONE_DIR_CMD_DEPTH` | `-1` | `--max-depth` of that check. |
| `RCLONE_DIR_CHECK_SKIP` | | Set to skip the source check. *Use with caution:* an empty source then empties the destination. |

## Health check

The container is healthy while `crond` runs, or while a sync runs (the boot sync starts before `crond`). Docker marks
it unhealthy if `crond` dies, so a monitor such as Uptime Kuma, or a dashboard, can tell.

## How the image is updated

The [Docker workflow](.github/workflows/docker-publish.yml) builds on the newest rclone release, runs
[`tests/smoke.sh`](tests/smoke.sh) against the image, and then pushes it to GHCR:

- **Every Monday:** if rclone has a release whose image isn't published yet, it publishes
  `latest` and `rclone-<version>`. Otherwise it does nothing.
- **A push to `master`, or a manual run:** publishes `latest` and `rclone-<version>`.
- **A `v*.*.*` tag:** publishes `<version>` (for example `1.0.41`).
- **A pull request:** builds and tests only.

Every published image is signed with [cosign](https://github.com/sigstore/cosign) (keyless).
Dependabot keeps the GitHub Actions current.

To update the containers, pull the new image and recreate them, for example
`docker compose pull && docker compose up -d`.

To build locally: `docker build -t docker-rclone .` (newest rclone), or pin one with
`--build-arg RCLONE_VERSION=1.76.0`.

## Credits

Forked from [pfidr34/docker-rclone](https://github.com/pfidr34/docker-rclone), which builds on
[bcardiff/docker-rclone](https://github.com/bcardiff/docker-rclone).
