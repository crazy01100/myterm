# MyTerm 更新站

這個目錄是 `https://mtus.lieniapp.work` 的靜態來源。

- Cloudflare Pages 採 Direct Upload，不直接連接私人 GitHub repository。
- `appcast.xml` 是尚未正式發布時使用的空白 feed；正式發布時會由已簽署的 Release 資產覆蓋。
- 正式 ZIP、appcast 與 release notes 由主要開發 Mac 建立，GitHub Actions 只負責驗證及部署。
- 自動部署失敗時，可由 repository 擁有者以 workflow 的 `release_tag` 指定既有已發布版本重新部署；流程仍只會使用 Release 上已簽署的成品。
- 不得在此目錄加入 Sparkle 私鑰、Cloudflare Token、OAuth secret、Firebase 本機設定或使用者資料。
