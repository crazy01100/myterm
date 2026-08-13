# MyTerm 開發與發布指南

本文件說明如何在不影響正式版 MyTerm 的前提下，測試原始碼、建立候選版並準備發布。所有建置腳本都保存在 GitHub，讓新的 checkout 不需要依賴特定 AI 工具或本機操作紀錄，也能重現相同流程。

## 環境與產物隔離

| 用途 | 固定位置 | 說明 |
|---|---|---|
| 正式版 | `/Applications/MyTerm.app` | 日常使用的穩定版本；開發腳本不會修改或取代它。 |
| 本機測試版 | `build/dev/MyTerm Dev.app` | 日常功能開發與人工驗證；每次建置都更新這個固定位置，並使用獨立 Bundle ID、Application Support 與本機保管庫 Keychain service。 |
| 候選版 | `build/candidates/MyTerm-<version>-build-<build>/MyTerm.app` | RC／正式發布前的不可混用候選 App。 |
| 發布資產 | `build/releases/MyTerm-<version>-build-<build>/` | GitHub Draft Release 使用的五個版本化檔案。 |

不得建立或使用 `build/MyTerm.app`。這個無版本、無通道的路徑容易讓已執行的舊 App 與磁碟上的新 App 混淆，因此建置與驗證腳本都會拒絕它。

`build/` 內所有 App、ZIP、測試結果與發布資產都可由原始碼重建，已由 Git 排除。

## 開發需求

- Apple Silicon Mac（arm64）
- macOS 26 或更新版本
- Xcode 26 或相容的 Command Line Tools
- 專案鎖定的 Swift Package 相依套件

Firebase、OAuth、Cloudflare、Sparkle 私鑰與 code-signing 私鑰都不是一般本機建置的必要原始碼，也不得提交至 Git。

## 雲端功能建置模式

| 目標 | Firebase／OAuth 設定 | 結果 |
|---|---|---|
| 一般本機開發 | 不需要 | SSH、Terminal、Serial、SFTP 與本機資料功能可完整使用；Google 登入與同步會顯示尚未設定 |
| 自行建置並啟用同步 | 使用開發者自己的 Firebase／Google Cloud 專案 | 可驗證 Google 登入、Firestore Rules 與跨裝置端對端加密同步 |
| 官方發布 | 僅由維護者在安全本機提供正式設定 | 不得從 repository、範例檔或 CI 推導／取得正式設定 |

自架雲端功能的 Firebase Console、Google Desktop OAuth、Firestore、設定產生、Rules 部署與驗收步驟見 [Firebase 自架同步設定](FIREBASE_SETUP.md)。實際設定固定放在被 Git 排除的 `Config/Local/`；公開 repository 只保存無真實值的範例、Rules、Indexes 與安全部署工具。

## 日常開發流程

先執行自動測試：

```sh
./scripts/run-tests.sh
```

需要人工驗證 App 行為時，使用固定的測試版入口：

```sh
./scripts/run-dev-app.sh \
  --version 0.0.0-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

這個入口會：

1. 只關閉目前從 `build/dev/MyTerm Dev.app` 執行的測試版。
2. 在相同固定位置重新建置。
3. 驗證版本、Build、Bundle 與簽章。
4. 啟動測試版並核對實際執行路徑。

若只需要確認編譯與 App bundle，不需要啟動畫面：

```sh
./scripts/run-dev-app.sh \
  --version 0.0.0-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --build-only
```

純文件、註解或操作說明修改不需要建立或啟動測試 App；確認連結、腳本語法與 Git diff 即可。

功能驗證完成後，再提交並推送原始碼。不要把 `build/dev/MyTerm Dev.app` 搬到「應用程式」資料夾，也不要用測試版覆蓋正式版。

## 建置與發布腳本

每個主要腳本都支援 `--help`。不確定參數時，先查看說明，例如：

```sh
./scripts/build-app.sh --help
./scripts/release.sh --help
```

| 腳本 | 用途 | 是否會發布 |
|---|---|---|
| `scripts/run-tests.sh` | 執行主要回歸測試與加密／同步測試。 | 否 |
| `scripts/run-crypto-tests.sh` | 單獨執行加密、Vault 與同步測試。 | 否 |
| `scripts/configure-cloud.sh` | 從本機 Firebase／Desktop OAuth 輸入檔產生 MyTerm 執行期雲端設定。 | 否 |
| `scripts/deploy-firestore.sh` | 要求明確指定 Firebase Project ID，再部署 Firestore Rules 與 Indexes。 | 是，僅部署指定專案的 Firestore 設定 |
| `scripts/run-dev-app.sh` | 安全建置、驗證及選擇性啟動固定測試 App。 | 否 |
| `scripts/build-app.sh` | 底層 App 建置工具；依通道限制輸出位置。 | 否 |
| `scripts/verify-app.sh` | 驗證指定 App 的版本、Build、架構、簽章與更新設定。 | 否 |
| `scripts/verify-packaged-resources.sh` | 比對 App／ZIP 內的平台圖示，並拒絕會依賴建置機路徑的 MyTerm SwiftPM resource accessor。 | 否 |
| `scripts/check-release-safety.sh` | 掃描發布設定、機密與不安全產物。 | 否 |
| `scripts/prepare-release-build.sh` | 執行測試、建立版本化候選 App 並封裝 ZIP。 | 否 |
| `scripts/package-app.sh` | 把明確指定的候選 App 封裝成版本化 ZIP。 | 否 |
| `scripts/prepare-release-assets.sh` | 建立 appcast、更新說明、checksum 與 manifest。 | 否 |
| `scripts/verify-release-assets.sh` | 驗證 GitHub／Cloudflare 使用的五個發布資產。 | 否 |
| `scripts/release.sh` | 執行完整發布準備，最多只建立 GitHub Draft Release。 | 僅建立草稿 |
| `scripts/prepare-pages-deployment.sh` | 從已發布資產準備 Cloudflare Pages 靜態內容。 | 否 |
| `scripts/verify-public-update-site.sh` | 從外部驗證正式 appcast、下載檔與安全標頭。 | 否 |

較底層的腳本保留給上述入口組合使用。一般開發優先使用 `run-dev-app.sh`，正式發布優先使用 `release.sh`，不要手動拼接一組看似相同的發布步驟。

## 候選版與發布流程

建立候選版但不建立 GitHub Release；先把下列 `X.Y.Z` 換成預計發布的版本：

```sh
./scripts/prepare-release-build.sh \
  --version X.Y.Z-rc.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

完整發布入口需要一份本機 release notes：

```sh
./scripts/release.sh \
  --version X.Y.Z-rc.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --notes build/release-notes/X.Y.Z-rc.1.md
```

`release.sh` 的界線如下：

1. 要求工作目錄乾淨、位於 `main`，且本機 `HEAD` 等於 `origin/main`。
2. 執行安全掃描、全部測試、arm64 Release 建置與固定簽章驗證。
3. 建立並重新驗證五個發布資產。
4. 建立 GitHub Draft Release 後停止。

五個正式資產必須是：

- `MyTerm-<version>-build-<build>-arm64.zip`
- `appcast.xml`
- `release-notes.html`
- `CHECKSUMS.txt`
- `release-manifest.json`

Draft 必須經人工確認後才能發布。候選 App、封裝後 ZIP 與 GitHub 回下載資產都會執行相同的 App 資源檢查；公開 GitHub Release 觸發 `.github/workflows/deploy-update-site.yml` 後，Cloudflare 部署前還會再次檢查下載 ZIP。正式更新仍需由既有 App 經 Sparkle 安裝並完成人工驗收，不能以直接覆蓋 `/Applications/MyTerm.app` 代替。

## 簽章與機密

可以提交：

- 簽章與部署流程的腳本
- Sparkle 公鑰與公開的 designated requirement 基線
- 不含憑證值的設定範例

不得提交：

- code-signing 私鑰、`.p12`、Keychain 匯出或加密備份密碼
- Sparkle Ed25519 私鑰
- Google OAuth client secret、Firebase token、Cloudflare token
- 寫死於範例、`.firebaserc` 或共用 npm script 的正式 Firebase Project ID
- 同步密語、復原金鑰、主機密碼或真實主機 inventory
- 本機 `.env`、Firebase 實際設定檔及 `build/` 產物

公開腳本只能描述如何取得或使用本機憑證，不得內嵌憑證內容。若腳本需要個人路徑，應由專案根目錄推導或透過參數傳入。

## Codex skill 與原始碼的關係

本機的 `release-myterm` skill 是操作 MyTerm 發布流程時給 Codex 使用的安全手冊，不是專案的建置依賴，也不在此 repository 內。

本文件與 `--help` 是 GitHub 上對人類開發者公開的權威說明；即使沒有安裝 Codex skill，仍應能只依這些文件與腳本完成測試、候選版準備和 Draft 建立。

## 常見問題

### 畫面仍是舊版本

不要只看 Dock 圖示或磁碟上的 App。先確認實際執行檔路徑、版本與 Build。日常測試的正確執行檔是：

```text
build/dev/MyTerm Dev.app/Contents/MacOS/MySSHClient
```

### 正式版會被測試建置覆蓋嗎？

不會。開發腳本只允許輸出到 `build/dev/`、`build/candidates/` 或 `build/update-lab/`。正式版只有使用者執行 Sparkle 更新或明確進行正式安裝時才會變更。

### 為什麼不能使用 `build/MyTerm.app`？

因為它沒有標示 development、candidate 或 production，容易把不同版本的磁碟檔案和執行中程序混在一起。相關腳本會直接拒絕這個路徑。

### 發布腳本會直接公開版本嗎？

不會。`release.sh` 最多只建立 Draft。公開 Release、部署正式更新站及 App 端更新驗收都有獨立的人工確認門檻。
