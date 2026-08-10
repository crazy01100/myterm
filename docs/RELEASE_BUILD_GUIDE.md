# MyTerm 本機正式候選建置說明

最後更新：2026-08-10

一般候選建置只在目前 Mac 建立成品，不會 push、建立 GitHub Release、部署 Cloudflare 或產生 Sparkle 私鑰。正式發布入口最多只會建立 GitHub Draft Release，公開仍需要人工放行。

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

## 建立正式 GitHub 草稿

1. 複製 `docs/RELEASE_NOTES_TEMPLATE.md` 到專案外，或放在已被 Git 忽略的 `build/release-notes/`。
2. 完成內容後移除範本中的「發布前確認」區塊。
3. 確認 `main` 工作目錄乾淨，且已完整推送至 `origin/main`。
4. 執行：

```sh
./scripts/release.sh \
  --version 1.0.0-rc.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --notes /path/to/release-notes.md
```

若只想驗證本機產物，不要建立 GitHub 草稿，可加上 `--prepare-only`。

正式入口會依序：

1. 拒絕未提交檔案、非 `main`、未推送 commit、重複版本 tag 或既有 Release。
2. 執行敏感資料掃描、276 項測試、arm64 Release 建置、App 與解壓後 ZIP 驗證。
3. 使用 Keychain 內的 Sparkle 私鑰簽署 ZIP 與完整 `appcast.xml`。
4. 建立五個 GitHub Release 資產：ZIP、`appcast.xml`、`release-notes.html`、`CHECKSUMS.txt`、`release-manifest.json`。
5. 再次驗證 SHA-256、Sparkle feed／ZIP 簽章、版本、Build、最低 macOS 26、arm64、下載網址、機密掃描與 Cloudflare 25 MiB 限制。
6. 建立私人 GitHub Draft Release 後停止；`rc`、`beta` 等非純 `x.y.z` 版本會自動標成 Pre-release。

Draft 尚未公開時，不會觸發 Pages workflow。只有人工檢查並發布 Release 後，GitHub Actions 才會把已簽署資產部署到 `mtus.lieniapp.work`。

正式資產保存在：

```text
build/releases/MyTerm-<version>-build-<build>/
```

## 安全界線

- `Config/Local` 原始檔、Termius 匯出、復原金鑰與簽章私鑰不得進入 App 或 ZIP。
- App 需要的雲端公開執行參數只會從白名單欄位建立新的 runtime plist，不會直接複製整個本機設定檔。
- Google Desktop OAuth 的配對值屬於原生 App 執行參數，不能被當成伺服器端機密；真正的登入 Token 只保存在這台 Mac 的 Keychain。
- `--skip-tests` 只供本機診斷，不得用來製作 Release Candidate。
- `--allow-rebuild` 只供本機診斷；正式候選一律使用新的 Build。
- `release.sh` 不提供跳過測試或重複 Build 的選項。
- Release notes 不可包含真實主機、IP、帳號、Token、私鑰、密語或密碼。
- `release.sh` 永遠不會自動公開 Release；GitHub Draft 是最後一道人工安全閘門。

## 人工驗證

打包完成後，完全結束舊 MyTerm，再開啟 `build/MyTerm.app`。版本與 Build 仍可在「設定 → 帳號與同步 → 目前狀態」確認；「檢查更新…」只保留在 MyTerm App 選單。未提供正式 feed 與公鑰時，該選單只會顯示本機安全說明，不會連線或下載。
