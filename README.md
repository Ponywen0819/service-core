# service-core

所有自架服務的 docker-compose 集中放在這裡，部署在 Dokploy。對外只有一個入口：`gateway/`（一條 Cloudflare Tunnel + 一台 nginx）。

## 架構

```
瀏覽器 ──https──▶ Cloudflare（DNS *.ponygames.net、Access 登入）
                    │  Tunnel（gateway/cloudflare-tunnel.json）
                    ▼
     gateway-cloudflared ── 驗 Access JWT ──▶ gateway-nginx:8080 ── 依 Host（gateway/nginx/conf.d/<name>.conf）
                                                │
             ┌──────────── gw-newsletter ───────┼──────── gw-<name> ────────┐
             ▼                                                              ▼
       newsletter-web:8787                                              <name>-app
       （newsletter-ops repo 自己部署）                                   （這個 repo 的 services/ 或別的 repo）

家裡區網／VPN ──▶ host:8788 ──▶ gateway-nginx:8788（newsletter 的 /auth、/ops）
```

- **gateway 是唯一的入口與轉接**：誰能進來、轉到哪個服務、哪些路徑擋掉，都在 `gateway/`。服務本身不處理這些。
- **服務可以放在自己的 repo**（例如 newsletter 留在 newsletter-ops）：只要照「接上 gateway」加入 `gw-<name>` 網路，gateway 這邊的路由仍集中在這裡。
- **一個服務一個 `gw-<name>` 網路**：gateway-nginx 連得到全部服務，服務之間互相連不到，也就沒辦法繞過 gateway 的規則
  （例如別的服務直接打 `newsletter-web/api/auth`）。
- 不經 Dokploy 的 Traefik（Dokploy 的 Domain 功能不用）：路由全部在 git 裡。

## 目錄

| 路徑 | 用途 |
|---|---|
| `common/base.yml` | 一般服務的安全預設（`cap_drop`、`no-new-privileges`、log 輪替），`extends` 引用 |
| `common/postgres.yml` | 所有 Postgres 共用的部分（映像版本、時區、healthcheck） |
| `common/github-runner.yml` | 所有 GitHub runner 共用的部分 |
| `gateway/` | cloudflared + nginx、Tunnel 路由（`cloudflare-tunnel.json`）與同步腳本 |
| `gateway/nginx/conf.d/` | `00-common.conf` 共用設定；每個站台一個 `<name>.conf` |
| `services/<name>/` | 一個服務一個資料夾，一個 Dokploy Compose app |
| `services/_template/` | 新服務的起點（另有 `gateway/nginx/conf.d/_template.conf.example`） |

## 命名規則

- **compose 的服務名稱一律加 `<name>-` 前綴**（`pg-test`、`xxx-app`、`xxx-db`）。gateway-nginx 同時在每個 `gw-*` 網路上，
  兩個服務都叫 `web` 的話，`http://web` 會被 Docker DNS 輪流解到不同的容器。別的 repo 的服務改不了名稱時，用 `gw-*` 網路上的唯一別名。
- 專案內部的網路（`be`、`default`）與 volume 不用加：compose 會自動用專案名稱當前綴。
- `gw-<name>` 網路由 gateway 建立（固定名稱與子網），服務端宣告成 `external: true`。

## 新增一個對外服務

1. `cp -r services/_template services/<name>`，把 `CHANGEME` 全部換成 `<name>`。
2. `gateway/docker-compose.yml`：
   - `networks:` 加一段 `gw-<name>`，`name: gw-<name>`、subnet 往下編號（`172.31.2.0/24` …）
   - 把 `gw-<name>` 加進 `gateway-nginx.networks`
3. `gateway/nginx/conf.d/00-common.conf` 的 `geo $lan` 加這個網路的閘道 `172.31.N.1 1;`。
4. `cp gateway/nginx/conf.d/_template.conf.example gateway/nginx/conf.d/<name>.conf`，換掉 `CHANGEME`。
5. 推上去。Dokploy：**先 Deploy gateway**（建立新網路、載入新站台），再新增 `<name>` 的 Compose app
   （同一個 repo，Compose Path `./services/<name>/docker-compose.yml`，Environment 填機密）並 Deploy。
   不要在 Dokploy 加 Domain、不要開 Isolated Deployment。
6. 要登入（Access）的服務到這裡就完成：Tunnel 的 `*.ponygames.net` 規則與萬用 DNS 已經涵蓋。
   公開服務另外要：`cloudflare-tunnel.json` 在萬用規則上面加一條、`public-hosts.txt` 加一行、Access 建 Bypass Application。

只改 nginx 站台設定（不加網路）的話，只要重新 Deploy gateway。upstream 用變數＋`resolver`，服務還沒起來時只有該站台 502，gateway 不會起不來。

不對外的服務（DB、runner）不用 2～4 步，也不用 `gw-*` 網路。

## 接上 gateway（服務在別的 repo）

服務的 compose 留在它自己的 repo，gateway 這邊照「新增一個對外服務」的 2～4 步（網路、`geo $lan`、站台 conf）。服務那邊只要：

1. 拿掉自己的 cloudflared 和對外的 nginx（入口由 gateway 負責），也不要 publish 對外的 port。
2. 讓 gateway 要連的那個容器加入 `gw-<name>`，並帶一個**唯一的別名**，站台 conf 的 upstream 就用這個別名：
   ```yaml
   services:
     web:
       networks:
         gw-newsletter: {aliases: [newsletter-web]}
         be: {}
   networks:
     gw-newsletter:
       external: true
   ```
   用別名的話，對方 repo 的服務名稱（`web`）不用改。只有這個容器加入 `gw-*`，worker、DB 之類的不要。
3. 部署順序：gateway 先（它建立 `gw-<name>`），服務後。

## 第一次設定

1. **Cloudflare Access**：Zero Trust → Access → Applications → Self-hosted，domain 填 `*.ponygames.net`，政策只放行自己的 email。
   把它的 AUD tag 填進 `gateway/cloudflare-tunnel.json` 萬用規則的 `audTag`（`check` 會擋下沒換掉的佔位符）。
2. **Dokploy 部署 gateway**：Create → Compose，來源選這個 repo，Compose Path `./gateway/docker-compose.yml`，Environment 填 `TUNNEL_TOKEN`。
3. **套用 Tunnel 路由與 DNS**（需要 `jq`、`curl` 與 `gateway/.env.example` 裡的 `CF_*`）：
   ```bash
   bash gateway/tunnel-sync.sh check
   bash gateway/tunnel-sync.sh diff
   bash gateway/tunnel-sync.sh apply   # PUT 整份設定，並建立 *.ponygames.net 等缺少的 CNAME
   ```
   之後改 `cloudflare-tunnel.json` 推到 main，`.github/workflows/tunnel-sync.yml` 會自動套用（repo secrets：`CF_API_TOKEN`、`CF_ACCOUNT_ID`、`CF_TUNNEL_ID`、`CF_ZONE_ID`）。
   **不要再到 Cloudflare 網頁上改 Public Hostname**：下次 apply 會整份蓋掉。

## newsletter-ops 改接 gateway

newsletter 留在 newsletter-ops repo；gateway 這邊已經備好 `gw-newsletter` 網路與 `gateway/nginx/conf.d/newsletter.conf`
（從 newsletter-ops 的 `docker/nginx.conf` 搬來，規則相同）。Tunnel 沿用**同一條**（同一個 `TUNNEL_TOKEN`、`CF_TUNNEL_ID`），
`newsletter.ponygames.net` 的 CNAME 已經指向它。

newsletter-ops 那邊要改：

- `docker-compose.yml`：拿掉 `nginx`、`cloudflared` 兩個服務與 `edge`、`app` 網路；`web` 改成加入 `gw-newsletter`（別名 `newsletter-web`）與 `be`，
  照「接上 gateway」第 2 步。`TUNNEL_TOKEN` 從 `.env.example` 拿掉。
- `docker/nginx.conf` 不再使用（規則已在 gateway），`deploy/test_nginx.py` 之類的測試要跟著調整或移到這裡。
- **停用 `.github/workflows/tunnel-sync.yml`**（或刪掉 `deploy/cloudflare-tunnel.json`）：兩個 repo 都會 PUT 整份 Tunnel 設定，互相覆蓋。

切換順序：

1. 停掉 newsletter-ops 正在跑的 cloudflared 與 nginx。同一條 Tunnel 的設定是全部 connector 共用的，
   舊的 cloudflared 還在跑的話，收到新設定會找不到 `gateway-nginx`，一部分請求 502；舊 nginx 的 8788 也會和 gateway 撞。
2. 照「第一次設定」部署 gateway、套用路由。
3. 用改好的 compose 重新部署 newsletter-ops（volume 名稱不變，資料不用搬）。
4. 照 newsletter-ops `deploy/README.md` 的驗收表檢查，特別是「未登入 `curl -sI https://newsletter.ponygames.net/reports` 絕不能是 200」，
   以及區網 `http://<host IP>:8788/auth` 開得到、`/ops` 從 Tunnel 網域開是 404。

## CI：pg-test 與 github-runner

- 兩個都在 `dokploy-network`：runner 容器裡的步驟用 `pg-test:5432` 連；runner 用 docker.sock 開的兄弟容器不在這個網路，走 host 的 `5432`。
- `pg-test` 的初始化 SQL 放 `services/pg-test/init/`（進 git）。原本的 `../files/init` 在這個 repo 結構下會解析到 `services/files/init`，所以改了。
- runner 掛 docker.sock，等於 workflow 有 host 的 root。只給自己的私有 repo；公開 repo 的 fork PR 不能跑在上面。
- 要給第二個 repo 開 runner：在 `services/github-runner/docker-compose.yml` 再加一個 `extends` 同一份 `common/github-runner.yml` 的服務，
  `RUNNER_WORKDIR` 用不同路徑（同一個路徑同時跑兩個 job 會互踩）。

## 還沒驗證的地方

- `extends: {file: ../../common/...}` 跨資料夾引用：Dokploy 部署 Git 來源時是 clone 整個 repo，應該可行，但文件沒明講。第一次部署看 Preview Compose／部署 log 確認。
- Dokploy 每次部署會重新 clone，`./nginx/conf.d`、`./init` 這類 bind mount 指到新 clone 的檔案，改了要重新 Deploy 才生效。
- `gw-*` 子網固定在 `172.31.0.0/16`：host 上若已有網路用了這段會建立失敗，換一段並同步改 `00-common.conf` 的 `geo $lan`。
