#!/usr/bin/env bash
# quadlet-install.sh 在複製單元檔之前呼叫：檢查 secret、把 nginx 站台設定同步到 /srv/gateway。可以重複執行。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../nginx/conf.d"
dst=/srv/gateway/nginx/conf.d

podman secret exists tunnel_token || {
  echo "缺少 podman secret tunnel_token：先執行  printf '%s' '<TUNNEL_TOKEN>' | podman secret create tunnel_token -" >&2
  exit 1
}

install -d -m 755 "$dst"
find "$dst" -mindepth 1 -delete
find "$src" -maxdepth 1 -type f -name '*.conf' -exec install -m 644 {} "$dst/" \;
# podman 沒有 Docker 的 127.0.0.11：DNS 是各網路閘道上的 aardvark-dns。
# 對 gateway-edge 的閘道查詢，也查得到 nginx 所在的其他 gw-* 網路上的容器（aardvark 依查詢者所在的網路回答）
cat > "$dst/01-resolver.conf" <<'CONF'
# prepare.sh 產生（podman）：覆蓋 repo 裡給 Docker 用的版本
resolver 172.31.0.1 valid=10s ipv6=off;
resolver_timeout 5s;
CONF
chmod 644 "$dst/01-resolver.conf"
