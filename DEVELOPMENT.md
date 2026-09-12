# MyTerm 開發與發布指南

**繁體中文** | [English](DEVELOPMENT.en.md)

本文件說明如何在不影響正式版 MyTerm 的前提下，測試原始碼、建立候選版並準備發布。所有建置腳本都保存在 GitHub，讓新的 checkout 不需要依賴特定 AI 工具或本機操作紀錄，也能重現相同流程。

## 環境與產物隔離

| 用途 | checkout 內固定輸出 | 說明 |
|---|---|---|
| 正式版 | `/Applications/MyTerm.app` | 日常使用的穩定版本；開發腳本不會修改或取代它。 |
| 本機測試版 | `build/dev/MyTerm Dev.app` | 日常功能開發與人工驗證；每次建置都更新這個固定位置，並使用獨立 Bundle ID、Application Support 與本機保管庫 Keychain service。 |
| 候選版 | `build/candidates/MyTerm-<version>-build-<build>/MyTerm.app` | RC／正式發布前的不可混用候選 App。 |
| 發布資產 | `build/releases/MyTerm-<version>-build-<build>/` | GitHub Draft Release 使用的五個版本化檔案。 |

不得建立或使用 `build/MyTerm.app`。這個無版本、無通道的路徑容易讓已執行的舊 App 與磁碟上的新 App 混淆，因此建置與驗證腳本都會拒絕它。

`build/` 內所有 App、ZIP、測試結果與發布資產都可由原始碼重建，已由 Git 排除。它是開發與發布進行期間的暫存工作區，不是正式成品的長期本機備份；正式版完成 GitHub Release、Cloudflare 部署、App 內更新及人工功能驗收後，以 GitHub Release 的五項資產為權威保存來源並清除整個 `build/`，下次開發再由腳本建立。

上述位置是原始碼 checkout 內的建置與自動驗證規則，不是 App 執行時的硬編碼依賴。將已驗證的 `MyTerm Dev.app` 交給另一台 Mac 人工測試時，可放在任一穩定、可寫入的本機資料夾；建議放在 `~/Applications/MyTerm Dev.app`，不必建立 `Documents/MySSHClient/build/dev/` 專案目錄。測試資料隔離來自 App 內的開發 Bundle ID、Application Support 目錄與 Keychain service，而不是 `.app` 所在位置。外部測試仍應記錄實際路徑並核對版本、Build、Bundle ID 與簽章，且不得覆蓋 `/Applications/MyTerm.app`。

Google 登入也必須按建置通道隔離。Dev／Update Lab 不得查詢或匯入正式版早期 Keychain session；第一次執行具隔離修正的版本時，只會清除該測試通道自身過去可能誤匯入的 refresh token，正式版 session 不受影響。完成這次一次性清理後，測試者在 Dev 主動登入的帳號會保留於 Dev 自己的保管庫，後續重建同通道 App 不會重複登出。

## 開發需求

- Apple Silicon Mac（arm64）
- macOS 26 或更新版本
- Xcode 26 或相容的 Command Line Tools
- 專案鎖定的 Swift Package 相依套件

### 終端元件來源

SwiftTerm library runtime 隨原始碼保存於 `Vendor/SwiftTerm`，供標籤分色與黑白文字對比的最小 macOS 顯示擴充使用；它不是建置快取。一般建置不需下載 fork 或手動修改 `.build/checkouts`。上游 revision、MIT 授權、兩個 renderer 檔案的局部差異與更新程序見 [SwiftTerm 來源說明](Vendor/SwiftTerm/UPSTREAM.md)。`Package.resolved` 只鎖定其餘遠端依賴。

升級終端元件前，取得該說明指定 revision 的 upstream Git checkout，再執行 `bash scripts/verify-swiftterm-vendor.sh /path/to/upstream-checkout`；它會比對完整 runtime 清單、未修改檔案及授權，列出兩個 renderer 差異供審查。更新後需執行完整測試、全新 scratch build、Dev 互動與封裝資源驗收。App 會附上 `SwiftTerm-LICENSE.txt`。

Firebase、OAuth、Cloudflare、Sparkle 私鑰與 code-signing 私鑰都不是一般本機建置的必要原始碼，也不得提交至 Git。

## 雲端功能建置模式

| 目標 | Firebase／OAuth 設定 | 結果 |
|---|---|---|
| 一般本機開發 | 不需要 | SSH、Terminal、Serial、SFTP 與本機資料功能可完整使用；Google 登入與同步會顯示尚未設定 |
| 自行建置並啟用同步 | 使用開發者自己的 Firebase／Google Cloud 專案 | 可驗證 Google 登入、Firestore Rules 與跨裝置端對端加密同步 |
| 官方發布 | 僅由維護者在安全本機提供正式設定 | 不得從 repository、範例檔或 CI 推導／取得正式設定 |

自架雲端功能的 Firebase Console、Google Desktop OAuth、Firestore、設定產生、Rules 部署與驗收步驟見 [Firebase 自架同步設定](FIREBASE_SETUP.md)。實際設定固定放在被 Git 排除的 `Config/Local/`；公開 repository 只保存無真實值的範例、Rules、Indexes 與安全部署工具。

## 原庫與獨立來源的界線

`myterm` 保存維護歷史、正式 Release 與部署流程；`myterm-source` 是另行整理的來源輸出。原庫公開準備不會把 source-only 排除清單套用到既有簽署成品：Sparkle 公鑰、簽章公開基線與更新網站網址不是私鑰，保留它們才能核對既有發行者。真正的雲端設定、簽署私鑰與復原材料仍在本機。

沒有 `Config/Local/` 的 checkout 不會帶入維護者雲端設定，也沒有預設更新 feed。修改或獨立發行 App 時應提供自己的服務、更新來源與簽章，不應讓自訂版本接回維護者的更新鏈。現有安裝包內的桌面 client 設定不能作為服務端秘密，界線見 [Firebase 設定](FIREBASE_SETUP.md)。

Git 歷史清理會改變 commit／tag 的識別，並可能影響 PR 差異與簽署 feed 的來源綁定；不得為了遮蔽路徑、公開公鑰或一般識別資訊直接重寫歷史或替換已簽署資產。需要清理真正敏感內容時，另行審查歷史引用與更新鏈。

## 日常開發流程

Dev 版本採「預計正式版本-dev.序號」，例如 `1.0.22-dev.1`、`1.0.22-dev.2`；不要以通用 `0.0.0-dev.*` 代替功能測試交付版本。`CFBundleVersion` 仍使用每次建置獨立且遞增的時間戳，版本名稱不取代 Build 或通道隔離。本文版本僅為命名範例，實際建置時須依當次目標版本調整。

同步可靠性回歸可獨立執行 `zsh scripts/run-sync-reliability-tests.sh`，完整 `scripts/run-tests.sh` 亦包含它。測試使用臨時目錄、獨立 UserDefaults、人工後端結果及縮短的排程時間，驗證真實協調層的單一週期、帳號世代與 JSON 保存失敗恢復，不連正式雲端。另以真實 `CloudAccountStore` 配合僅存在測試執行檔的合成登入／Keychain 依賴，驗證離線冷啟動、週期前不重試、下一輪登入及資料同步、single-flight、停用／登出／憑證失效與舊回應丟棄。加密測試另驗證既有保管庫可在未開啟 Settings 時初始化。

雙機人工自動同步驗收需使用獨立測試 Google 帳號、相同已驗證 Dev Build；不可按「立即同步」代替啟動、前景週期或離線恢復測試。先不開設定驗證啟動路徑，之後才從「帳號與同步 → 診斷資訊 → 複製同步執行記錄」取得遮蔽後的階段證據。記錄兩台實際 App 身分、觸發與耗時；持續前景至少覆蓋三個 5 分鐘週期。單機加速測試不代表雙機實傳驗收完成。

先執行自動測試：

```sh
./scripts/project-python.sh scripts/run-isolated-tests.py
```

需要人工驗證 App 行為時，使用固定的測試版入口：

```sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
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
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --build-only
```

純文件、註解或操作說明修改不需要建立或啟動測試 App；確認連結、腳本語法與 Git diff 即可。

功能驗證完成後，再提交並推送原始碼。在主要開發 Mac 不要把 `build/dev/MyTerm Dev.app` 搬到系統的 `/Applications`，也不要用測試版覆蓋正式版；這不限制外部測試 Mac 使用前述建議的使用者目錄 `~/Applications/MyTerm Dev.app`。

### Firebase 開發工具相容性

開發工具需要 Node.js 24 LTS及 Python 3.12 以上。`./scripts/project-node.sh --npm ci` 會執行經版本與雜湊驗證的 `scripts/patch-firebase-stream-json.py`；若使用 `--ignore-scripts`，須明確執行修補腳本。`./scripts/project-node.sh --npm run test:development-tools` 驗證既有覆寫、CLI 消費端與深度限制；`./scripts/project-node.sh --npm run test:firestore-rules` 使用本機 demo Emulator。每次 CLI 啟動前再次核對補丁，來源漂移必須重新審閱，不能跳過。範圍與撤除條件見 [安全維護指南](SECURITY_MAINTENANCE.md)。

原庫另有維護者管理入口 `scripts/invite-sync-user.sh --help`，需本機 Google Cloud CLI 與管理員授權，不是 App 建置依賴或既有 Firebase CLI wrapper 的擴權。隔離安全測試為 `./scripts/project-node.sh --test Tests/Security/invite-sync-user.test.mjs`，也由既有 `Tests/Security` Python 測試探索納入。管理設定、憑證與私人操作紀錄不進 Git；此工具未納入獨立來源輸出。

### 文件語系與同步維護

GitHub 的預設首頁是繁體中文 [README.md](README.md)，英文入口為 [README.en.md](README.en.md)。專案自有的文件配對如下；現行指南在頁首提供雙向語言切換，英文文件優先連到英文版，中文文件優先連到中文版。

| 文件 | 繁體中文 | English |
|---|---|---|
| 專案介紹 | [README.md](README.md) | [README.en.md](README.en.md) |
| 架構 | [ARCHITECTURE.md](ARCHITECTURE.md) | [ARCHITECTURE.en.md](ARCHITECTURE.en.md) |
| 開發與發布 | [DEVELOPMENT.md](DEVELOPMENT.md) | [DEVELOPMENT.en.md](DEVELOPMENT.en.md) |
| 安全設計 | [SECURITY.md](SECURITY.md) | [SECURITY.en.md](SECURITY.en.md) |
| Firebase 設定 | [FIREBASE_SETUP.md](FIREBASE_SETUP.md) | [FIREBASE_SETUP.en.md](FIREBASE_SETUP.en.md) |
| Termius 遷移 | [TERMIUS_MIGRATION.md](TERMIUS_MIGRATION.md) | [TERMIUS_MIGRATION.en.md](TERMIUS_MIGRATION.en.md) |
| 更新站 | [update-site/README.md](update-site/README.md) | [update-site/README.en.md](update-site/README.en.md) |
| UpdateLab beta.2 測試說明 | [中文原始 fixture](Resources/UpdateLab/1.0.0-beta.2.md) | [英文閱讀對照](Resources/UpdateLab/1.0.0-beta.2.en.md) |
| 安全維護 | [SECURITY_MAINTENANCE.md](SECURITY_MAINTENANCE.md) | [SECURITY_MAINTENANCE.en.md](SECURITY_MAINTENANCE.en.md) |

修改專案介紹、功能、架構、安全、安裝、建置、部署或遷移說明時，同步更新受影響文件的中英文版；內容、命令、設定鍵、資料流與限制應一致。語言翻譯不代表 App 或更新網站已提供英文介面。新增英文版採同目錄的 `<原檔名>.en.md`，並更新此表與語言連結；不要放進被 Git 排除的本機 `docs/`。

UpdateLab 中文原檔是本機更新腳本使用的歷史 fixture，英文檔只供 GitHub 閱讀。兩版由本表連結，不在原 fixture 加入切換列，也不修改腳本選用語言；日後若因測試需求改動原文，才同步更新英文對照。已是英文的上游文件與原始 LICENSE／NOTICE 保留原文，不為雙語整理改寫第三方內容。

開發前先提出計劃與驗收案例並取得維護者確認。計劃末尾逐份盤點 README、ARCHITECTURE、DEVELOPMENT、SECURITY、FIREBASE_SETUP、TERMIUS_MIGRATION、更新站及 UpdateLab 的中英文文件，以及依影響加入 LICENSE 與素材聲明；每份記錄是否需要更新、理由與實際結果。必要更新及內容、連結與語言切換驗證完成後再結案；未受影響的文件可明確記錄不需更新。中英文開發來源署名與圖片標示也須保持語意一致。

MyTerm 原創程式碼與文件的 MIT 授權位於根目錄 [LICENSE](LICENSE)。第三方元件及素材保留原有 LICENSE／NOTICE；更新專案授權說明時不得覆寫第三方聲明。

README 專用品牌素材位於 `Resources/Readme/`，來源及使用條款見 [NOTICE.md](Resources/Readme/NOTICE.md)。OpenAI 標誌只用於開發工具署名，使用官方原始黑白版本及明暗模式切換；不裁切、改色或併入 MyTerm 自有標誌，且不屬於專案 MIT 授權。調整頁首時同步核對兩版 README 的呈現與聲明。

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
| `scripts/cleanup-build-artifacts.sh` | 正式版完整驗收後，重新下載並驗證 GitHub 五項資產、確認沒有 App 從 `build/` 執行，再清除本機建置暫存。預設只預覽，必須加 `--apply`。 | 否 |
| `scripts/prepare-pages-deployment.sh` | 從已發布資產準備 Cloudflare Pages 靜態內容。 | 否 |
| `scripts/verify-public-update-site.sh` | 從外部驗證正式 appcast、下載檔與安全標頭。 | 否 |

較底層的腳本保留給上述入口組合使用。一般開發優先使用 `run-dev-app.sh`，正式發布優先使用 `release.sh`，不要手動拼接一組看似相同的發布步驟。

## App 版號與發布前判斷

MyTerm 採 `Major.Minor.Patch`，依使用者影響與相容性分級：

- **Patch**：相容的錯誤／安全修正、效能或小幅呈現改善。
- **Minor**：相容的功能新增／擴充，或仍可使用的功能棄用預告。
- **Major**：破壞既有功能、資料格式、同步或平台相容性；提高最低 macOS 版本亦屬此級。

混合變更取最高等級；不以工作量、漏洞嚴重度或第三方套件版號決定 App 等級。UI 大改或資料遷移依實際相容性判斷，不單憑名稱升 Major。純 CI、工具或文件維護可不發 App；隨 App 封裝的必要修補仍須以新版交付。

升 Minor 時 Patch 歸零，升 Major 時其餘兩位歸零；沒有累積次數門檻。Dev／RC 使用目標版號加後綴（如 `1.1.0-dev.1`、`1.1.0-rc.1`），Build 獨立遞增。規則自後續發布採用，已發布版號與簽署資產不重編、不覆寫。

每份發布計劃固定列出：**目前版本 → 建議版本｜等級與理由｜相容性影響及必要操作｜是否需要發布 App**。維護者確認後沿既有流程執行；自動化只驗證一致性，不自行決定等級或公開發布。

## 更新說明內容與呈現

更新視窗只呈現使用者可見的功能／修正摘要、必要相容性、重要已知限制，以及更新後需要採取的動作。測試數量、驗證過程、CI、部署、監測與開發工具例外保留在功能計劃、CI 或安全 Issue，不放入一般更新說明；直接影響 App 使用者的安全資訊仍須說明。

撰寫更新說明時不要加入「驗證與維護」區塊。版本標題可省略，或以第一行 `# MyTerm X.Y.Z` 提供；必須符合目標版本。私人／公開的資產腳本共用 `scripts/render-release-notes.py` 產生已簽署 HTML，版本標題只顯示一次，沒有返回網站導覽。App 與網站使用同一份精簡內容及 `update-site/assets/release-notes.css`；網站首頁樣式不套用到更新說明。

渲染器保留作者輸入的章節，不偷偷刪除內容；維護者應在撰寫與審閱時確認範圍。簽章與發布前驗證門檻保持原樣。每次發布前檢查窄幅、深淺色與捲動預覽，並在實際 Sparkle 更新驗收核對畫面；瀏覽器預覽不代替 App 內驗收。已發布的簽署說明與 appcast 不直接覆寫，模板調整隨下一次核准發布採用。

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

人工驗收全部完成、對應功能／發布計劃準備結案後，執行：

```sh
./scripts/cleanup-build-artifacts.sh \
  --version X.Y.Z \
  --build <build> \
  --apply
```

清理工具只接受正式版本，並要求該版本是 GitHub 最新的非 Draft、非 prerelease Release；它會把五項資產下載到系統暫存目錄重新執行完整驗證，且在無法列舉程序或仍有 App 從專案 `build/` 執行時拒絕刪除。清理目標只有整個 `build/`，不包含 `/Applications/MyTerm.app`、Application Support、Keychain、`Config/Local/`、簽章／復原材料或 SwiftPM 相依快取。

### 正式部署保護

更新站 workflow 僅在 `crazy01100/myterm` 執行；手動重新部署須選擇 `main` 並指定既有的 `release_tag`，Release 發布事件仍可從正式 tag 觸發。部署 job 宣告 `environment: production`，使用 Node 24.21.0，下載並驗證原有簽署資產後才部署。

管理員必須另外在 GitHub 的 `production` 設定必要 reviewer、只允許 `main` branch 與 `v*` tags，並禁止略過保護。單人維護可允許本人核准自己觸發的部署；這仍是一次明確的部署確認，不是第二人審查。宣告 environment 不會自動建立核准規則，也不會限制其他未綁定該環境的 workflow。

將 `CLOUDFLARE_API_TOKEN` 與 `CLOUDFLARE_ACCOUNT_ID` 設為 production environment Secrets；由管理員安全填入既有值，不把值放進來源、指令紀錄或 Issue。確認該環境可部署後移除 repository 層級的同名 Secrets，才能避免未綁 production 的工作繼續取得原本的憑證。舊 tag 的 workflow 可能尚未綁 environment，重新部署時應使用目前 main 的入口，不改舊 tag 或簽署資產。

這些 GitHub 設定須在遠端逐項啟用並驗收，來源檔不能證明已生效。公開前及日後改回私人前，核對當時方案是否支援所需的規則與環境 Secrets；GitHub Free 改回私人時，既有 environment 保護及 Secrets 會被忽略。見 [GitHub environment 說明](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)。

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

不要只看 Dock 圖示或磁碟上的 App。先確認實際執行檔路徑、版本與 Build。主要開發 checkout 日常測試的正確執行檔是：

```text
build/dev/MyTerm Dev.app/Contents/MacOS/MySSHClient
```

### 正式版會被測試建置覆蓋嗎？

不會。開發腳本只允許輸出到 `build/dev/`、`build/candidates/` 或 `build/update-lab/`。正式版只有使用者執行 Sparkle 更新或明確進行正式安裝時才會變更。

### 為什麼不能使用 `build/MyTerm.app`？

因為它沒有標示 development、candidate 或 production，容易把不同版本的磁碟檔案和執行中程序混在一起。相關腳本會直接拒絕這個路徑。

### 發布腳本會直接公開版本嗎？

不會。`release.sh` 最多只建立 Draft。公開 Release、部署正式更新站及 App 端更新驗收都有獨立的人工確認門檻。

## 私人維護與公開原始碼

- 此私人維護庫保留個人版本、既有 Git 歷史、簽署成品與自動部署；`crazy01100/myterm-source` 是獨立的 source-only 專案。公開來源不提供個人 App 成品、雲端設定或更新服務。
- 維護者以 `scripts/export-public-source.py --output build/public-source/<新的候選名稱>` 匯出；`PublicSource/export-manifest.json` 定義明確檔案清單，`PublicSource/overrides/` 維護公開版文件與工具差異。來源變動導致雜湊不符時，先審閱並更新公開差異與雙語文件，再更新清單；不將整個工作目錄或私人 Git 歷史推到公開庫。
- 公開前執行 `./scripts/project-python.sh PublicSource/test_export.py`、站點／憑證掃描、文件核對及無個人設定的 build-only 驗證。初次建立全新 Git 歷史，之後以公開庫自己的正常提交同步；私人版本發布及更新站部署仍沿用各自流程與授權。

- 公開文件須分清「一般自用 MyTerm.app」「隔離開發 MyTerm Dev.app」與「獨立發行／更新站」；自用入口採現有 build-app.sh 的 candidate 輸出與 verify-app.sh，並解釋安裝、重建更新、共享一般資料身分及 ad-hoc 授權限制。這不取代私人 release.sh／固定簽章／更新驗收流程。

相依漏洞警示、隔離測試與公開金鑰部署驗證：[安全維護指南](SECURITY_MAINTENANCE.md)。

<a id="python-runtime"></a>
## Python 工具環境

專案管理、測試與發布腳本使用仍受上游支援的 Python 3.12 或更新穩定版，統一入口為 `./scripts/project-python.sh`。它依序使用明確指定的 `MYTERM_PYTHON`、專案 `.build/python-runtime/bin/python3`，或 PATH 中可用的受支援版本；不接受低於 3.12 的版本，也不修改系統 Python。

若已安裝 Python 3.12，可在專案根目錄建立獨立環境：

```sh
python3.12 -m venv .build/python-runtime
./scripts/project-python.sh --version
./scripts/setup-security-tools.sh
```

也可將 `MYTERM_PYTHON` 指向自己安裝的受支援 Python 執行檔。最低版本門檻不代替生命週期檢查；更新工具時仍需核對官方 EoL／EoS 狀態。驗簽套件另由 `.build/security-tools` 的隔離環境管理，重新執行 setup 會以選定的 Python 重建該可重建目錄，並以固定版本、wheel 及雜湊安裝。App 使用者不需要安装 Python。

Node／npm 統一入口為 `./scripts/project-node.sh`；使用 Node 24 LTS，依序接受 `MYTERM_NODE`、`.build/node-runtime/bin/node` 或已安裝的 Node 24，並讓子程序沿用相同 PATH。`./scripts/project-node.sh --npm ci` 可避免系統預設 Node 指到已EoL的奇數版本。可將官方 Node 24 發行包完整解壓至 `.build/node-runtime`，或指定已安裝的 Node 24 執行檔；不需覆蓋全域 Node。套件引擎範圍與 `.npmrc` 亦拒絕非24版本的安裝。

## 建置時的同步服務說明

開發者代管的同步服務暫不開放新使用者，既有使用者保留同步功能；公開來源仍支援使用自己的雲端服務。`Config/Local/CloudSyncServiceNotice.txt` 可加入該發行者的服務說明，僅在已配置雲端且非 Update Lab 的建置嵌入 `MyTermCloudSyncServiceNotice`；不放入 Git，也不作為後端權限判斷。修改說明須重建 App 才會顯示，舊版不會自動取得新文字。操作與驗收見 [Firebase 設定](FIREBASE_SETUP.md)。

登入回應測試位於 `SelfTests/GoogleFirebaseAuthResponseTests.swift`，由 `scripts/run-tests.sh` 納入完整隔離回歸。測試以不落盤的 URLSession 與 URLProtocol 攔截所有請求，驗證 HTTP 成功內的登入失敗、缺失欄位、隱私邊界及正常登入，不連正式雲端或使用真實憑證。

30 分鐘重試的期限／時鐘案例在 `SelfTests/GoogleSignInRetryTests.swift`；`CloudAccountRecoveryTests.swift` 使用真實 store 驗證免重新 OAuth、單一請求、取消、切換、過期與保存界線；`GoogleFirebaseAuthResponseTests.swift` 以合成傳輸驗證同一 Google 憑證重試 Firebase，不需等待真實半小時或操作正式帳號。完整入口仍為 `scripts/run-isolated-tests.py`。
