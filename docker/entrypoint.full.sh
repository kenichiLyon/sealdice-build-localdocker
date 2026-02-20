#!/bin/sh
set -e

mkdir -p /data /backups /lagrange

if [ -d /opt/sealdice/buildin-data ] && [ -z "$(ls -A /data 2>/dev/null)" ]; then
  cp -r /opt/sealdice/buildin-data/. /data/
fi

if [ -d /opt/sealdice/lagrange ] && [ -z "$(ls -A /lagrange 2>/dev/null)" ]; then
  cp -r /opt/sealdice/lagrange/. /lagrange/
fi

exec /usr/local/bin/sealdice-core --container-mode

