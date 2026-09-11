# 自行代管更新站範例

**繁體中文** | [English](README.en.md)

此目錄是供獨立發行者調整的靜態網站範例，不是本來源專案提供的線上服務。本原始碼庫不附預先打包的 MyTerm、既有已簽署 appcast 或自動部署 workflow。

- 若只自行建置使用，不需要更新站；依 [README](../README.md#從原始碼建置) 建置 `MyTerm.app`、安裝及手動更新即可。
- 想要 App 內更新時，先建立自己的 HTTPS 主機、Sparkle 私鑰及 App 驗證公鑰，設定 `MYTERM_UPDATE_BASE_URL`，並依[開發指南](../DEVELOPMENT.md)建立簽署資產。
- `prepare-pages-deployment.sh` 將自己的 appcast、ZIP、release notes 及 checksums 放進部署輸出；它不會把來源中的空白範例當成有效更新。
- 此庫沒有 appcast 成品；以自己的發布資產建立 feed，不手動修改已簽署的 feed。部署前調整 HTML 的文案與安裝說明，使其符合自己的發行方式。
- 可將輸出放到自己的 Cloudflare Pages 或相容 HTTPS 主機；Cloudflare 專案、帳號與部署憑證由你自行配置。
- 部署後使用 `verify-public-update-site.sh` 明確指定自己的網址與資產，再由自己的 App 經 Sparkle 驗收。
- 不放入私鑰、token、OAuth secret、真實 Firebase 設定、主機清單或其他使用者資料。

部署前以可信公鑰驗證全部五項資產，包括 manifest、已簽署的來源／相依資訊及更新說明。先執行 `scripts/setup-security-tools.sh`；獨立發行者設定 `MYTERM_SPARKLE_PUBLIC_KEY_FILE`。舊資產缺少簽署欄位時需另行相容審查。見 [安全維護指南](../SECURITY_MAINTENANCE.md)。

更新說明由共用 `scripts/render-release-notes.py` 與專用 `assets/release-notes.css` 呈現；不包含首頁導覽或重複版本標題。只撰寫使用者需要的修正、相容性與操作資訊，測試／維護紀錄另行保存。內容規範見[開發指南](../DEVELOPMENT.md)。已發布的簽署內容不回寫修改。
