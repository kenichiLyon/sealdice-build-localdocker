#!/bin/sh
set -e

mkdir -p /data /backups

if [ -d /opt/sealdice/buildin-data ] && [ -z "$(ls -A /data 2>/dev/null)" ]; then
  cp -r /opt/sealdice/buildin-data/. /data/
fi

exec /usr/local/bin/sealdice-core --container-mode

