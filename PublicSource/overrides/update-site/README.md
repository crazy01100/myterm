# 自行代管更新站範例

**繁體中文** | [English](README.en.md)

此目錄是供獨立發行者調整的靜態網站範例，不是本來源專案提供的線上服務。本原始碼庫不附預先打包的 MyTerm、既有已簽署 appcast 或自動部署 workflow。

- 若只自行建置使用，不需要更新站；取得原始碼後重新建置即可。
- 想要 App 內更新時，先建立自己的 HTTPS 主機、Sparkle 私鑰及 App 驗證公鑰，設定 `MYTERM_UPDATE_BASE_URL`，並依[開發指南](../DEVELOPMENT.md)建立簽署資產。
- `prepare-pages-deployment.sh` 將自己的 appcast、ZIP、release notes 及 checksums 放進部署輸出；它不會把來源中的空白範例當成有效更新。
- 此庫沒有 appcast 成品；以自己的發布資產建立 feed，不手動修改已簽署的 feed。部署前調整 HTML 的文案與安裝說明，使其符合自己的發行方式。
- 可將輸出放到自己的 Cloudflare Pages 或相容 HTTPS 主機；Cloudflare 專案、帳號與部署憑證由你自行配置。
- 部署後使用 `verify-public-update-site.sh` 明確指定自己的網址與資產，再由自己的 App 經 Sparkle 驗收。
- 不放入私鑰、token、OAuth secret、真實 Firebase 設定、主機清單或其他使用者資料。
