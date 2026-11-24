# service-core

所有自架服務的 docker-compose 集中放在這裡，部署在 Dokploy，對外只有一個入口：一條 Cloudflare Tunnel。

## 架構

```
瀏覽器 ──https──▶ Cloudflare（DNS *.ponygames.net、Access 登入）
                    │  Tunnel（ingress/cloudflare-tunnel.json）
                    ▼
                cloudflared（ingress/）── 驗 Access JWT ──▶ dokploy-traefik:80
                                                              │ 依 Host 分流（各服務 compose 裡的 Traefik labels）
                         ┌────────────────────────────────────┼─────────────────────┐
                         ▼                                    ▼                     ▼
              newsletter.ponygames.net               xxx.ponygames.net            ...
              services/newsletter: newsletter-nginx:8080   services/xxx: xxx-app:8080
                 └─▶ newsletter-web:8787（app 網路）
                 └─  newsletter-worker 只在 be 網路，外面碰不到
```

**為什麼不另外放一台 nginx 當總路由**：Dokploy 本來就跑著 Traefik（`dokploy-traefik`，在 `dokploy-network` 上），它就是依 Host 分流的反向代理，
而且會自己從容器 labels 讀路由，新增服務不用 reload 任何東西。再疊一層 nginx 只是多一個要同步的設定檔。
nginx 留在**服務自己裡面**當閘門（例如 newsletter 的 `/auth`、`/ops` 只能從區網開），那是該服務的商業邏輯，不是入口的事。

## 目錄

| 路徑 | 用途 |
|---|---|
| `common/base.yml` | 共用的安全預設（`cap_drop`、`no-new-privileges`、log 輪替…），各服務用 `extends` 引用，不用複製貼上 |
| `ingress/` | 唯一的 cloudflared，以及 Tunnel 路由（`cloudflare-tunnel.json`）與同步腳本 |
| `services/<name>/` | 一個服務一個資料夾，一個 Dokploy Compose app |
| `services/_template/` | 新服務的起點 |

## 改路由要改哪裡

| 想做的事 | 改哪裡 |
|---|---|
| 新增一個要登入（Access）才看得到的服務 | 只要服務 compose 裡的 Traefik labels。Tunnel 的 `*.ponygames.net` 規則與萬用 DNS 已經涵蓋 |
| 新增一個公開服務 | labels，加上 `ingress/cloudflare-tunnel.json` 一條、`ingress/public-hosts.txt` 一行、Access 的 Bypass Application |
| 某個服務要用自己的 Access 政策 | Cloudflare 建該 hostname 的 Access Application，`cloudflare-tunnel.json` 在萬用規則上面加一條帶它 AUD tag 的規則（像 newsletter） |

Tunnel 規則由上往下比對，**具體的 hostname 要放在 `*.ponygames.net` 前面**，最後一條必須是 `http_status:404`。

## 第一次設定

1. **Cloudflare Access**：Zero Trust → Access → Applications → Self-hosted，domain 填 `*.ponygames.net`，政策只放行自己的 email。
   把它的 Application Audience (AUD) Tag 填進 `ingress/cloudflare-tunnel.json` 萬用規則的 `audTag`（`check` 會擋下沒換掉的佔位符）。
2. **Dokploy 部署 ingress**：Create → Compose，來源選這個 Git repo，Compose Path `./ingress/docker-compose.yml`，
   Environment 填 `TUNNEL_TOKEN`。不要加 Domain。
3. **套用 Tunnel 路由與 DNS**：在本機或 CI 跑（需要 `jq`、`curl` 與 `ingress/.env.example` 裡的 `CF_*`）：
   ```bash
   bash ingress/tunnel-sync.sh check
   bash ingress/tunnel-sync.sh diff
   bash ingress/tunnel-sync.sh apply   # PUT 整份設定，並建立 *.ponygames.net 等缺少的 CNAME
   ```
   之後改 `cloudflare-tunnel.json` 推到 main，`.github/workflows/tunnel-sync.yml` 會自動套用（repo secrets 要設 `CF_API_TOKEN`、`CF_ACCOUNT_ID`、`CF_TUNNEL_ID`、`CF_ZONE_ID`）。
   **不要再到 Cloudflare 網頁上改 Public Hostname**：下次 apply 會整份蓋掉。
4. Dokploy 的網域都**不要開 HTTPS／Let's Encrypt**：TLS 在 Cloudflare 結束，Traefik 收的是 `web`（:80）entrypoint 的 HTTP。
   Cloudflare 的 SSL/TLS 模式不要用 Flexible（Dokploy 文件說會和 Traefik 轉址打轉）。

## 新增一個服務

1. `cp -r services/_template services/<name>`，把 `CHANGEME` 全部換成 `<name>`：compose 服務名稱、映像、port、`Host(...)`、Traefik router／service 名稱（這些都是跨 compose 共用的命名空間）。
2. Dokploy → Create → Compose，同一個 repo，Compose Path `./services/<name>/docker-compose.yml`，Environment 填機密。
   - **不要**在 Dokploy UI 加 Domain：路由寫在 labels 裡，才會跟著 git 走。
   - **不要**開 Isolated Deployment：它會把同一個網路加到每個容器，內部服務（DB、worker）就會被 Traefik 那個網路碰到。
3. 推上去、Deploy。登入過 Access 後開 `https://<name>.ponygames.net` 應該看到服務；沒登入的 `curl -sI` 應該是 302 到 `cloudflareaccess.com` 或 403。

撞名注意：所有接 Traefik 的容器都在同一個 `dokploy-network`，同網路上的服務名稱（`web`、`app`、`db`）會互相解析到。
所以 **compose 的服務名稱一律加資料夾名稱當前綴**（`newsletter-web`、`newsletter-nginx`、`xxx-db`），服務之間互連也用這個名字。
網路（`app`、`be`）與 volume 不用加：compose 會自動用專案名稱當前綴，不會撞。

## 從 newsletter-ops 搬過來

沿用**同一條 Tunnel**（同一個 `TUNNEL_TOKEN`、`CF_TUNNEL_ID`），`newsletter.ponygames.net` 的 CNAME 已經指向它，不用動 DNS。順序很重要：

1. 停掉 newsletter-ops 原本的 `cloudflared` 容器（以及 `newsletter-autodeploy.timer`）。同一條 Tunnel 的設定是全部 connector 共用的，
   舊的 cloudflared 還在跑的話，它收到新設定後會找不到 `dokploy-traefik`，一部分請求會 502。
2. **停用 newsletter-ops repo 的 `tunnel-sync.yml`**（刪掉 workflow 或 `deploy/cloudflare-tunnel.json`）。兩個 repo 都會 PUT 整份 Tunnel 設定，互相覆蓋。
3. 按上面「第一次設定」部署 ingress、套用路由；再部署 `services/newsletter`（Environment 填 Gmail 等，不需要 `TUNNEL_TOKEN`）。
4. 資料：原本的 volume 叫 `newsletter-ops_newsletter-data`，Dokploy 會以 app 名稱建新的 volume。部署前先把舊 volume 的內容複製過去
   （或在 compose 的 `volumes.newsletter-data` 加 `external: true` + `name: newsletter-ops_newsletter-data` 直接沿用）。
5. 照 newsletter-ops `deploy/README.md` 的驗收表檢查，特別是「未登入 `curl -sI https://newsletter.ponygames.net/reports` 絕不能是 200」，
   以及區網 `http://<host IP>:8788/auth` 仍然開得到。

## 還沒驗證的地方

- `extends: {file: ../../common/base.yml}` 跨資料夾引用：Dokploy 部署 Git 來源時是 clone 整個 repo，應該可行，但文件沒明講。第一次部署時看 Dokploy 的 Preview Compose／部署 log 確認。
  不行的話退路是把 `common/base.yml` 的內容貼回各服務的 `x-hardened` anchor。
- Traefik 的 HTTP entrypoint 名稱是 `web`：這是 Dokploy 預設的 traefik.yml；若你改過，labels 的 `entrypoints=` 要跟著改（在 Dokploy → Web Server → Traefik 看設定）。
- Dokploy 每次部署會重新 clone，`./nginx.conf` 這類 bind mount 會指到新 clone 的檔案，改 nginx.conf 後要重新 Deploy 才生效。
