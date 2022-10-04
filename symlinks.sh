#!/bin/bash

set -e

# SYMLINKS Expects an env var like: {YEAR}/{NAME}={ALBUM_NAME};{YEAR}/{NAME}={ALBUM_NAME};{YEAR}/{NAME}={ALBUM_NAME};
# Where SRC has to be relative to /data
# Where DEST has to be relative to /albums

# Example
# export SYMLINKS="/2021/Chip=/[2021] Chip random;"

echo "Deleting All Symlink Albums in /albums"
rm -rf -- /albums/*/

if [ ! -z "$SYMLINKS" ]
then
  IFS=';' read -ra ARRAY_OF_SYMLINKS <<< "$SYMLINKS"
  for symlink in "${ARRAY_OF_SYMLINKS[@]}"; do
    IFS='=' read -ra PATHS <<< "$symlink"

    echo "Creating Directory for: /albums/${PATHS[1]}"
    mkdir -p /albums/"${PATHS[1]}"

    echo "Creating Sym Links for: /data/${PATHS[0]}/* --> /albums/${PATHS[1]}"
    ln -sf /data/"${PATHS[0]}"/* /albums/"${PATHS[1]}"
  done
fi
