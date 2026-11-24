正式區 Postgres 的初始化 `*.sql`／`*.sh`（照檔名順序執行）。`prepare.sh` 會同步到 raspi 的 `/srv/pg/init`。
只在 `/srv/pg/data` 是空的、第一次啟動時執行一次。不要放密碼等機密：這個資料夾會進 git（而且 repo 是公開的）。
