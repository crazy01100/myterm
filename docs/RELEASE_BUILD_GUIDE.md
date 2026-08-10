# MyTerm 本機正式候選建置說明

最後更新：2026-08-10

這套流程只在目前 Mac 建立候選成品，不會 push、建立 GitHub Release、部署 Cloudflare 或產生 Sparkle 私鑰。

## 建置指令

```sh
cd /path/to/MySSHClient
build_number="$(date '+%Y%m%d%H%M%S')"
./scripts/prepare-release-build.sh \
  --version 0.13.0 \
  --build "$build_number"
```

- `--version` 是顯示版本，支援 `1.0.0-beta.1` 形式。
- `--build` 必須是正整數，而且高於上一次成功建置；範例使用目前時間產生 14 位數字。
- 若希望候選的顯示日期固定，可額外提供 `--build-date "2026-08-10 01:39:44 +0800"`。

## 自動執行內容

1. 確認 `Config/Local`、Termius 匯出與常見私鑰／Token 不會進入來源候選或 App。
2. 預先拒絕無效版本、重複 Build 或倒退 Build。
3. 執行 276 項本機測試。
4. 建立 macOS 26、arm64、Release App。
5. 注入版本、Build 與建置日期。
6. 使用 ad-hoc 簽章並驗證 App。
7. 建立 ZIP 與 SHA-256。
8. 解壓 ZIP，對解壓後的 App 再做一次完整驗證。

## 產物

- App：`build/MyTerm.app`
- ZIP：`build/release/MyTerm-<version>-build-<build>-arm64.zip`
- 校驗碼：`build/release/CHECKSUMS.txt`

## 安全界線

- `Config/Local` 原始檔、Termius 匯出、復原金鑰與簽章私鑰不得進入 App 或 ZIP。
- App 需要的雲端公開執行參數只會從白名單欄位建立新的 runtime plist，不會直接複製整個本機設定檔。
- Google Desktop OAuth 的配對值屬於原生 App 執行參數，不能被當成伺服器端機密；真正的登入 Token 只保存在這台 Mac 的 Keychain。
- `--skip-tests` 只供本機診斷，不得用來製作 Release Candidate。
- `--allow-rebuild` 只供本機診斷；正式候選一律使用新的 Build。

## 人工驗證

打包完成後，完全結束舊 MyTerm，再開啟 `build/MyTerm.app`。版本與 Build 仍可在「設定 → 帳號與同步 → 目前狀態」確認；「檢查更新…」只保留在 MyTerm App 選單。未提供正式 feed 與公鑰時，該選單只會顯示本機安全說明，不會連線或下載。
