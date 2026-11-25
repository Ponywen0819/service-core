# 推送式部署（CI 打 tag → ssh → host 上的 deploy.sh）

給「compose 放在自己 repo、跑在 raspi 這類自管 host」的專案用的部署方式。**host 不輪詢**：只有在 `main` 打 `vX.Y.Z` tag 時，
CI 建好映像後 ssh 到 host，跑專案自己的 `deploy/deploy.sh <版本>`。參考實作是 newsletter-ops（`deploy/deploy.sh`、`.github/workflows/release.yml`）。

Dokploy 上的服務（`services/` 底下）不用這套，照根目錄 README 在 Dokploy 部署。

## 流程

```
合併到 main ─────────────────────────────▶（什麼都不會發生，host 不動）

git tag v1.2.3 && git push origin v1.2.3
  └─ 專案的 release.yml
       ├─ image：建映像推 GHCR，打 v1.2.3、latest、sha-<commit> 三個標籤
       └─ deploy（映像推完才開始）→ service-core 的 .github/workflows/deploy.yml（reusable）
            └─ 自架 runner：ssh <DEPLOY_HOST>，只送出「v1.2.3」這個字串
                 └─ host 的 authorized_keys：這把 key 有 command=，不管送什麼都只執行 deploy/deploy.sh
                      └─ deploy.sh v1.2.3（版本號從 SSH_ORIGINAL_COMMAND 來）
                           1. 檢查格式、git fetch、確認 tag 存在且裡面有 deploy.sh、repo 沒有本機修改
                           2. repo 切到 tag（compose 檔一定和映像同一版）
                           3. docker compose pull
                           4. busy() 為真就等（每 30 秒看一次，最多 30 分）——不打斷正在跑的工作
                           5. 版本寫進 .env 的 <TAG_VAR>（之後手動下 compose 指令也是這一版）
                           6. docker compose up -d --remove-orphans
                           7. 等全部容器 healthy（沒有 healthcheck 的看 running）
                           8. 清掉沒在用的映像
```

任何一步失敗就停、Actions 顯示紅色。第 4 步之前失敗容器完全不動。

| | 輪詢（timer 每 N 分鐘 git pull） | 推送（這套） |
|---|---|---|
| 什麼時候部署 | 合進 main 就會拉到 | 只有打 tag |
| compose 與映像版本 | 可能不一致（compose 新、映像還舊） | 一定同一個 tag |
| 工作正在跑 | 跳過這輪 | 等它跑完 |
| 結果在哪看 | host 的 journal | GitHub Actions |
| 退版 | 手動改 `.env` | Actions 跑 deploy、填版本號 |

## 檔案

| 路徑 | 用途 |
|---|---|
| `.github/workflows/deploy.yml` | 共用的 reusable workflow：ssh 到 host、送版本號。各專案用 `uses:` 呼叫，不用複製 |
| `deploy/deploy.sh` | host 端腳本的範本：複製到專案的 `deploy/deploy.sh`，改開頭「設定」那段 |
| `deploy/examples/release.yml` | 專案的 release workflow 範本（建映像 → 呼叫共用部署） |
| `deploy/examples/deploy.yml` | 專案的手動部署／退版 workflow 範本 |

`deploy.sh` 用複製而不是共用：它跟著專案的 tag 走，部署哪一版就用那一版的腳本與 compose 檔。

## 新專案接上（一次）

以下 `<app>` 是專案名稱，`/root/<app>` 是 host 上 repo 的位置（自己定，但 authorized_keys 要寫同一個絕對路徑）。

**1. 專案 repo**

- `docker-compose.yml`：每個服務都要有 `image:`（要能 `pull`），標籤用一個變數：
  ```yaml
  image: ghcr.io/<owner>/<app>:${APP_TAG:-latest}
  ```
  建議每個服務都有 `healthcheck`，`deploy.sh` 才知道新版本真的起來了（沒有的話只看 running）。
- `cp deploy/deploy.sh <專案>/deploy/deploy.sh && chmod +x`，改「設定」：
  - `TAG_VAR`：上面那個變數名稱
  - `busy()`：有不能被打斷的工作（排程、批次）時，告訴腳本怎麼判斷「正在忙」；沒有就保持 `return 1`
  - Windows 上提交要確認執行權限：`git update-index --chmod=+x deploy/deploy.sh`
  - `.gitattributes` 要有 `*.sh text eol=lf`：Windows 的 git 預設轉成 CRLF，host 上的 bash 會讀到 `\r` 而失敗
- `cp deploy/examples/{release,deploy}.yml <專案>/.github/workflows/`，換掉 `CHANGEME`。
  host 和 runner 都是 x64 的話，拿掉 QEMU 那步與 `platforms`。
- **手動部署的 workflow 要在 repo 的預設分支上才看得到**（`gh repo view --json defaultBranchRef` 確認是哪個）。

**2. host**

```bash
git clone https://github.com/<owner>/<app> /root/<app>
cd /root/<app> && cp .env.example .env && chmod 600 .env   # 填機密
```

**3. 部署專用 key**（不要用自己的 key）

```bash
ssh-keygen -t ed25519 -N '' -C <app>-deploy -f <app>-deploy    # 不設 passphrase：CI 沒辦法輸入
```

host 的 `/root/.ssh/authorized_keys` 加一行（先備份）。**前面的 `command=...` 一定要有**，漏掉的話這把 key 就是完整的 root shell，
CI 送來的版本號也會被當成 shell 指令（`v1.2.3: command not found`）：

```
command="/root/<app>/deploy/deploy.sh",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA… <app>-deploy
```

一個專案一把 key、一行：`command=` 決定這把 key 能部署哪個專案。你自己的 key 不受影響，照常拿到 shell。

**4. GitHub**（專案 repo → Settings → Secrets and variables → Actions；放 repo 層級，或 Environments → `production`）

| 類型 | 名稱 | 值 |
|---|---|---|
| Variable | `DEPLOY_HOST` | `root@<host 的固定 IP>`。runner 是 Docker 容器，**解析不到 `.local`（mDNS）**，用 IP 並在路由器設 DHCP 保留 |
| Secret | `DEPLOY_SSH_KEY` | 私鑰檔的完整內容（含 `-----BEGIN/END …-----` 兩行） |

公鑰只放 host，不放 GitHub。設好後刪掉本機的私鑰檔；要換就重產一對。
想在部署前按一下核准：Environments → `production` → Required reviewers。

**5. 驗證 key 的限制**（在區網的電腦上）

```bash
ssh -i <app>-deploy -o IdentitiesOnly=yes root@<host> v0.0.0   # 應該回「找不到 tag v0.0.0」
ssh -i <app>-deploy -o IdentitiesOnly=yes root@<host> id       # 應該回「版本號要是 vX.Y.Z」，不是 uid=0
```

還沒部署過有 `deploy.sh` 的版本時，兩個都會回 `deploy.sh: No such file or directory`——這也代表限制生效了。

**6. 第一次部署**

host 上的 repo 還沒有 `deploy.sh` 時 CI 的 deploy 會失敗（`No such file or directory`，容器不動）。第一次在 host 上手動跑：

```bash
cd /root/<app> && git fetch --tags && git checkout --detach v1.2.3 && deploy/deploy.sh v1.2.3
```

之後每次部署都會把 repo 切到新的 tag，`deploy.sh` 就一直在。要確認 CI 這段也通，到 Actions 重跑失敗的 deploy job（同一版再部署一次不會重建容器）。

**有一次性的搬遷步驟時**（資料庫匯入之類、必須在新版服務啟動前做）：不要讓 CI 先部署。
等 CI 的 deploy 因為還沒有 `deploy.sh` 而失敗（或在 `production` 加 Required reviewers 擋住），
在 host 上切到新 tag、`docker compose pull`、`docker compose run --rm <service> <搬遷指令>`，再手動跑 `deploy.sh`。

## 日常

- **發版**：合併到 `main` → `git tag vX.Y.Z && git push origin vX.Y.Z` → 自動建映像、部署。結果看 Actions 的 deploy job。
- **重新部署／退版**：Actions → deploy → Run workflow，填版本號（那個 tag 要已經建過映像、而且有 `deploy.sh`）。
- **在 host 上**：`deploy/deploy.sh vX.Y.Z` 效果一樣。`.env` 的 `<TAG_VAR>` 由腳本維護，不要手動改。
- 正在跑的工作會讓部署等最多 30 分鐘（`DEPLOY_WAIT` 可改）；超過就失敗、容器不動，晚點再跑一次 deploy。

## 維運：臨時連進沒有 publish port 的容器

服務不 publish port（只讓 gateway 連）時，用 ssh 的 port forwarding 開一條臨時 tunnel。容器 IP 每次重建會變，先查：

```powershell
$ip = (ssh root@raspi "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' <容器名稱>").Trim().Split(' ')[0]
ssh -N -L "28787:${ip}:8787" root@raspi     # 開著的期間 http://localhost:28787 直連容器；Ctrl+C 關掉
```

這條路不經過 gateway 的規則，只有能 ssh 進 host 的人開得起來。部署 key 有 `no-port-forwarding`，開不了，要用自己的 key。
只是要看狀態或下指令的話，`docker compose exec <service> …` 就夠了。

## 安全上的設計

- **key 只能做一件事**：`command=` 讓 host 不管收到什麼都只執行 `deploy.sh`，送來的字串只當版本號、格式不對就拒絕；
  也禁止 port／agent／X11 轉發與 pty。拿到這把 key 頂多能部署某個已經存在、而且含 `deploy.sh` 的 tag。
- **不檢查 host key**：host 重灌 host key 就會變，維護成本高。公鑰認證的簽章綁定這次連線，冒充的主機拿不到私鑰、也無法轉送去登入真的 host，
  最壞只是 CI 顯示一個假的「部署完成」。要更嚴格的話，自己在 workflow 加 known_hosts 檢查。
- **誰能觸發**：只有 tag push 與手動 Run workflow。公開 repo 的 fork PR 碰不到 deploy（拿不到 secrets，也不會在自架 runner 跑）。
- **同時只部署一個**：共用 workflow 依 repo＋environment 排隊，後到的等前一個結束。
- runner 掛著 docker.sock（見 `common/github-runner.yml`），等於 workflow 有 runner host 的 root：只給自己的 repo。

## 踩過的坑

| 狀況 | 原因／做法 |
|---|---|
| `bash: line 1: v1.2.3: command not found` | authorized_keys 那行漏了 `command=...`，這把 key 拿到的是一般 shell。補上前綴 |
| `deploy.sh: No such file or directory` | host 的 repo 還在沒有 `deploy.sh` 的版本：照「第一次部署」手動跑一次 |
| runner 連不到 `<name>.local` | runner 是 Docker 容器，沒有 mDNS；`DEPLOY_HOST` 用固定 IP |
| `workflow deploy.yml not found on the default branch` | 手動觸發的 workflow 要在預設分支上；先合併到預設分支 |
| podman 的 `docker compose ps` 看不到 healthy | `deploy.sh` 改用 `docker inspect` 看每個容器 |
| 部署後手動 `docker compose up` 跑成舊版 | 本機的 `latest` 可能是舊映像；`deploy.sh` 已把版本寫進 `.env`，不要刪那行 |
| repo 有本機修改，拒絕部署 | 本機設定放 `.env` 或 `docker-compose.override.yml`（不進 git），不要改 tracked 的檔 |
