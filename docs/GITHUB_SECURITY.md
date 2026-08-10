# MyTerm GitHub 安全政策

最後更新：2026-08-10

## Repository 狀態

- 正式來源 repository：`crazy01100/myterm`。
- 初始可見性：Private。
- 現階段不加入開源 LICENSE；若未來公開原始碼，再單獨決定授權方式。
- GitHub 只保存原始碼、測試與公開設定；不保存使用者主機資料、密碼、Token 或發布私鑰。

## 發布信任根

- Sparkle Ed25519 私鑰只保存在主要開發 Mac 的 Keychain。
- 私鑰備份只保存在私人 iCloud Drive 的 AES-256 加密映像檔。
- GitHub Actions、GitHub Secrets、Cloudflare、Firebase 與 repository 都不得保存 Sparkle 私鑰或備份密碼。
- GitHub Release 由主要開發 Mac 在本機完成測試、建置與簽章後建立，公開前仍需人工確認。

## GitHub Actions 規則

初始版本不建立 GitHub Actions workflow，因此不會產生 Actions 用量或付款需求。未來若加入 CI：

1. PR workflow 不得取得發布私鑰、OAuth client secret、Firebase Token 或任何持續性憑證。
2. 禁止使用 `pull_request_target` 執行 PR 提供的程式碼。
3. 第三方 Action 必須固定到完整 commit SHA，不使用浮動 tag。
4. 發布 workflow 不負責簽署正式更新；正式簽章維持在主要開發 Mac。
5. 啟用 workflow 前先確認私人 repository 的 Actions 配額與付款畫面；若要求付款方式，停止並請使用者決定。

## 提交前檢查

每次提交或發布前執行：

```sh
./scripts/check-release-safety.sh --app build/MyTerm.app
```

檢查只掃描 Git 實際可能提交的檔案，並只回報命中的檔名，避免把疑似憑證內容輸出到終端或 CI 紀錄。
