#!/usr/bin/env bash
# quadlet-install.sh 在複製單元檔之前呼叫：準備 host 上的目錄與檢查 secret。可以重複執行。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

podman secret exists pg_pw || {
  echo "缺少 podman secret pg_pw：先執行  printf '%s' '<密碼>' | podman secret create pg_pw -" >&2
  exit 1
}

# data 給容器裡的 postgres（uid 999 → host 100999，見 postgres.container 的 UIDMap）
install -d -m 700 -o 100999 -g 100999 /srv/pg/data
# init 從 repo 同步：只在 data 是空的時候被 postgres 執行，之後改了也不會重跑
install -d -m 755 /srv/pg/init
find /srv/pg/init -mindepth 1 -delete
find "$here/init" -maxdepth 1 -type f ! -name README.md -exec install -m 644 {} /srv/pg/init/ \;
