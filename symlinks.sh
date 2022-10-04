#!/bin/bash

set -e

# SYMLINKS Expects an env var like: {YEAR}/{NAME}={ALBUM_NAME};{YEAR}/{NAME}={ALBUM_NAME};{YEAR}/{NAME}={ALBUM_NAME};
# Where SRC has to be relative to /data
# Where DEST has to be relative to /albums

# Example
# export SYMLINKS="/data/2021/Chip=/albums/[2021] Chip random;"

if [ ! -z "$SYMLINKS" ]
then
  IFS=';' read -ra ARRAY_OF_SYMLINKS <<< "$SYMLINKS"
  for symlink in "${ARRAY_OF_SYMLINKS[@]}"; do
    IFS='=' read -ra PATHS <<< "$symlink"

    echo "Deleting Directory for: ${PATHS[1]}"
    rm -rf "${PATHS[1]}"

    echo "Creating Directory for: ${PATHS[1]}"
    mkdir -p "${PATHS[1]}"

    echo "Creating Sym Links for: ${PATHS[0]} --> ${PATHS[1]}"
    ln -sf "${PATHS[0]}"/* "${PATHS[1]}"
  done
fi
