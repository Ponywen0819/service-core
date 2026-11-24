#!/usr/bin/env bash
# 把一個服務資料夾裡的 Quadlet 單元（*.container、*.network、*.volume、*.pod）裝到 rootful 的 /etc/containers/systemd，並啟動。
#   sudo scripts/quadlet-install.sh services/pg            安裝／更新並（重新）啟動
#   sudo scripts/quadlet-install.sh --remove services/pg   停止並移除單元（不刪 host 上的資料目錄）
# 資料夾裡有 prepare.sh 的話，安裝前先執行（建目錄、檢查 secret 之類）。
# 一律 rootful：raspi 沒開 user 的 D-Bus／logind，rootless 的 systemd 單元起不來。
set -euo pipefail

DEST=/etc/containers/systemd
remove=0
[ "${1:-}" = "--remove" ] && { remove=1; shift; }
dir=${1:?usage: $0 [--remove] services/<name>}
dir=$(cd "$dir" && pwd)

[ "$(id -u)" = 0 ] || { echo "要用 root 執行（rootful Quadlet）" >&2; exit 1; }

shopt -s nullglob
units=("$dir"/*.container "$dir"/*.network "$dir"/*.volume "$dir"/*.pod)
[ ${#units[@]} -gt 0 ] || { echo "$dir 裡沒有 Quadlet 單元檔" >&2; exit 1; }

# Quadlet 產生的 systemd 服務名稱：foo.container → foo.service，foo.network → foo-network.service
service_of() {
  local f=${1##*/} base=${1##*/}; base=${base%.*}
  case $f in
    *.container) echo "$base.service" ;;
    *) echo "$base-${f##*.}.service" ;;
  esac
}

if [ $remove = 1 ]; then
  for f in "${units[@]}"; do [[ $f == *.container ]] && systemctl stop "$(service_of "$f")" || true; done
  for f in "${units[@]}"; do [[ $f != *.container ]] && systemctl stop "$(service_of "$f")" || true; done
  for f in "${units[@]}"; do rm -fv "$DEST/${f##*/}"; done
  systemctl daemon-reload
  echo "已移除；host 上的資料目錄沒有動"
  exit 0
fi

[ -x "$dir/prepare.sh" ] || [ ! -e "$dir/prepare.sh" ] || chmod +x "$dir/prepare.sh"
[ -e "$dir/prepare.sh" ] && "$dir/prepare.sh"

mkdir -p "$DEST"
for f in "${units[@]}"; do install -m 644 -v "$f" "$DEST/"; done

# 先讓 Quadlet 檢查語法，有錯就停（不要 daemon-reload 半套設定）
/usr/libexec/podman/quadlet -dryrun >/dev/null

systemctl daemon-reload
for f in "${units[@]}"; do
  [[ $f == *.container ]] || continue
  svc=$(service_of "$f")
  systemctl restart "$svc"
  systemctl --no-pager --lines=0 status "$svc" || true
done
