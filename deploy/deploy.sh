#!/usr/bin/env bash
# 推送式部署的 host 端腳本（範本）。複製到專案 repo 的 deploy/deploy.sh，只改下面「設定」那段。說明見 service-core 的 deploy/README.md。
#
#   deploy/deploy.sh v1.2.3          # 在 host 上手動部署或退版
#   ssh <deploy key> host v1.2.3     # CI：authorized_keys 的 command= 固定執行這支，版本號從 SSH_ORIGINAL_COMMAND 來
#
# 做的事：repo 切到那個 tag（compose 檔跟著版本走）→ 拉同版本映像 → 等正在跑的工作結束 → 把版本寫進 .env
#        → docker compose up -d --remove-orphans → 等全部容器 healthy → 清舊映像。任何一步失敗就停，容器不動。
# 包成函式：git checkout 會換掉這個檔，bash 要先讀完整個函式才執行
set -euo pipefail

# ---------------- 設定（每個專案改這段） ----------------
# compose 檔裡映像標籤用的變數，例如 image: ghcr.io/<owner>/<app>:${APP_TAG:-latest}
TAG_VAR=APP_TAG
# 等全部容器 healthy（沒有 healthcheck 的看 running）最多幾秒
HEALTH_TIMEOUT=${DEPLOY_HEALTH_TIMEOUT:-180}
# 有不能被打斷的工作在跑時回 0（忙），部署會等它結束，最多 DEPLOY_WAIT 秒（預設 1800）。
# 沒有這種工作就保持 return 1。例子（newsletter-ops：worker 握著 pipeline 鎖就是忙）：
#   [ -n "$(docker compose ps --status running -q worker)" ] || return 1
#   ! docker compose exec -T worker python -c 'import fcntl; fcntl.flock(open("state/pipeline.lock", "a"), fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null
busy() { return 1; }
# ---------------- 設定結束 ----------------

fail() { echo "[deploy] $*" >&2; exit 1; }

state_of() { docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1"; }

main() {
  local tag=${1:-${SSH_ORIGINAL_COMMAND:-}}
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "版本號要是 vX.Y.Z：'$tag'"

  cd "$(dirname "$0")/.."
  git fetch --quiet --force --tags origin
  git rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null || fail "找不到 tag $tag"
  # 沒有這支腳本的舊版本：切過去之後下次就部署不了，退到那麼舊要手動
  git cat-file -e "$tag:deploy/deploy.sh" 2>/dev/null || fail "$tag 沒有 deploy/deploy.sh，不能用這個方式部署"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "repo 有本機修改，不覆蓋（本機設定放 .env 或 docker-compose.override.yml）"

  git checkout --quiet --detach "$tag"
  echo "[deploy] repo 在 $tag（$(git rev-parse --short HEAD)）"

  export "$TAG_VAR=$tag"
  docker compose pull --quiet

  local waited=0 limit=${DEPLOY_WAIT:-1800}
  while busy; do
    [ "$waited" -lt "$limit" ] || fail "有工作跑了超過 ${limit} 秒還沒結束，這次不部署（repo 已切到 $tag，容器沒動）"
    [ "$waited" -gt 0 ] || echo "[deploy] 有工作正在跑，等它結束"
    sleep 30; waited=$((waited + 30))
  done

  # 版本寫進 .env：之後在 host 上手動下 docker compose 指令也是這一版（本機的 latest 可能是舊的映像）
  if [ ! -f .env ]; then
    install -m 600 /dev/null .env
  fi
  if grep -q "^$TAG_VAR=" .env; then
    sed -i "s/^$TAG_VAR=.*/$TAG_VAR=$tag/" .env
  else
    printf '\n# deploy/deploy.sh 維護：目前部署的版本\n%s=%s\n' "$TAG_VAR" "$tag" >> .env
  fi

  docker compose up -d --remove-orphans

  # podman 的 docker compose ps 不顯示 healthy，直接看每個容器
  local ids id st pending t=0
  ids=$(docker compose ps -q)
  [ -n "$ids" ] || fail "沒有任何容器起來"
  while :; do
    pending=""
    for id in $ids; do
      st=$(state_of "$id")
      case "$st" in
        healthy|running) ;;
        *) pending+=" $(docker inspect --format '{{.Name}}' "$id" | sed 's#^/##')=$st" ;;
      esac
    done
    [ -n "$pending" ] || break
    [ "$t" -lt "$HEALTH_TIMEOUT" ] || fail "${HEALTH_TIMEOUT} 秒內沒有全部 healthy：$pending（看 docker compose logs）"
    sleep 5; t=$((t + 5))
  done
  echo "[deploy] 全部容器 healthy"

  docker image prune -f >/dev/null
  echo "[deploy] $tag 部署完成"
}

main "$@"
exit
