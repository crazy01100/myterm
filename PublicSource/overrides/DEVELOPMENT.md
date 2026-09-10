# 自行建置與維護 MyTerm

**繁體中文** | [English](DEVELOPMENT.en.md)

這個專案只發布原始碼、必要素材與文件，不提供 App 安裝包、代管 Firebase 或更新站。MyTerm 以維護者自己的工作習慣為出發點；你可以修改功能、自己建置，並決定是否建立自己的發行與更新服務。

<a id="build-tools"></a>
## 建置前準備

需要 Apple Silicon、macOS 26、Xcode 26／相容 Command Line Tools（Swift 6.2）、Git、Python 3 與 ripgrep（`rg`）。未安裝 Apple 開發工具時可執行 `xcode-select --install`，依系統提示完成；若已有 Xcode，請確認目前選用的工具鏈提供 Swift 6.2。以 `swift --version`、`git --version`、`python3 --version`、`rg --version` 檢查工具；缺少 ripgrep 時可透過自己使用的套件管理器安裝（已使用 Homebrew 者可執行 `brew install ripgrep`）。

首次建置需要網路下載 Swift 相依套件。基本本機建置不需要 Node.js 或 Firebase；雲端設定工具另需 jq，Firestore Rules 測試另需 Node.js 24 與專案 npm 相依套件。

## 建立日常使用的 MyTerm.app

依 [README 建置步驟](README.md#從原始碼建置)執行測試、`build-app.sh --channel candidate` 與 `verify-app.sh`。這會建立 Release 最佳化、一般 MyTerm 名稱與資料身分的 App；建置與驗證本身不啟動、不安裝、不上傳，也不建立更新站。

既有腳本以 `candidate` 表示安裝前的 App 輸出位置：`build/candidates/MyTerm-<version>-build-<build>/MyTerm.app`。這個目錄名稱不代表程式只供開發，也不保證來源經過正式發布驗收。README 的 `1.0.21` 是版本標籤範例；修改 `--version` 不會切換 Git 原始碼，請保留自己採用的來源 commit。Build 為每次建置產生、遞增的正整數；即使版本相同，也使用新的 Build。

一般自用不需要 `prepare-release-build.sh` 或 `release.sh`；前者為固定簽章候選的測試／建置／封裝流程，後者為搭配自有更新站的發行流程，要求不同。自用建置沿用 `build-app.sh` 既有能力，不移除發行流程的簽章要求。

<a id="install-and-data"></a>
## 安裝與既有資料

- 首次安裝：建置／驗證成功後，從 Finder 將 `MyTerm.app` 複製到 `/Applications`（應用程式）；若無該目錄寫入權限，可使用自己的 `~/Applications`。之後從選定位置開啟，不需每次啟動都進入原始碼目錄或重新建置。
- 已有 MyTerm：先確認來源、版本、Build 與資料用途；完成連線工作並退出原 App 後，才決定是否替換。不要同時啟動兩份使用相同資料身分的 App；若想並存測試，選 Dev。此指南不會自動覆蓋任何安裝。
- 一般版使用 `tw.local.MySSHClient` Bundle ID、`~/Library/Application Support/MySSHClient/` 與 `tw.local.MySSHClient.local-secret-vault-root` Keychain 根金鑰項目。它可能讀取這台 Mac 上既有一般 MyTerm 的資料；換名稱或移動 App 不會隔離資料。
- Dev 使用 `tw.local.MySSHClient.Development`、`~/Library/Application Support/MyTerm Development/` 及開發專用 Keychain service。Dev 與一般版不自動遷移主機、密碼、登入或設定；需要搬移時使用 App 支援的匯入／匯出或自己的同步服務，核對其涵蓋範圍，不直接複製保管庫檔案。主機匯出不含密碼，詳見 [資料界線](SECURITY.md)。
- 移交另一台相容 Mac 時可複製完整 App bundle；另核對 macOS 的開啟許可與簽章。App 不依賴原始碼目錄，但本機保管庫根金鑰不能透過複製 App 或資料夾搬到另一台 Mac。

<a id="manual-update"></a>
## 手動更新日常使用版

保留原始碼目錄以便更新。先在該目錄執行：

```sh
git pull --ff-only
```

只有成功後才重新執行 README 的完整建置／驗證區塊。若有自己的修改或更新失敗，先解決來源差異，不用強制重設或刪除設定來排除問題。`git pull` 不會更新已安裝的 App。

確認新 App 驗證成功後，退出舊 App，把新 App 替換到同一安裝位置，再開啟並核對「關於」的版本／Build。替換 App 不需要刪除 Application Support、Keychain、同步資料或 `Config/Local/`；保留這些資料及自己設定的簽章身分。若新舊版身分相同，會沿用原本的資料位置，但仍應核對新來源是否有遷移或相容性限制。保管庫密文與裝置根金鑰缺一不可，不能把主機匯出當作密碼備份。

乾淨來源預設沒有 `SUFeedURL`，所以不會從預設服務取得更新；單獨設定公鑰而沒有網址也不啟動更新器。有自訂同步或更新配置時，每次重建都要保留相同設定，不能只複製上次已建好的 App 內檔案。

<a id="local-signing"></a>
## 自用簽章

未設定本機 code-signing 身分時，`build-app.sh` 使用 ad-hoc 簽章；不需付費開發者帳號即可建置，但這不等同 Developer ID 簽章或 Apple 公證。macOS 可能要求開啟許可；重建或更換簽章後，Keychain 可能要求重新授權，不能保證不出現提示。不要以刪除 Keychain 根金鑰或停用系統保護來解決問題。

長期自行維護者可使用自己的固定 code-signing 身分，透過 `MYTERM_CODE_SIGN_IDENTITY` 或 `Config/Local/CodeSigningIdentity.txt` 指定；簽章憑證與私鑰應保留在自己的 Keychain 並妥善備份。固定簽章有助於維持身分，不代表已通過公證；對外發行的完整簽章／更新要求見下方「獨立發行」。

## 開發與測試用的 MyTerm Dev

在來源目錄執行：

```sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

此入口會建置、驗證並啟動隔離的 `build/dev/MyTerm Dev.app`；加上 `--build-only` 則不啟動。版本僅為範例。腳本只終止本 checkout 固定 Dev 路徑的程序，不終止 `/Applications/MyTerm.app`；其他非標準 MyTerm 程序會阻擋操作。若一般自用 App 安裝在 `~/Applications`，執行開發入口前先自行退出它。每次啟動核對實際路徑、版本、Build、Bundle ID、簽章與 development 通道。

Dev 同樣使用 Release 最佳化，其差異是名稱與資料隔離。移交其他 Mac 的已驗證 Dev 可放在穩定、可寫入的 `~/Applications/MyTerm Dev.app` 或其他位置；它不依賴主要開發 checkout 路徑。

## 設定自己的同步服務

本機功能不需要帳號。Google 登入及跨裝置同步需依 [Firebase 設定](FIREBASE_SETUP.md) 建立自己的 Firebase／Google OAuth 專案。真實設定只放在 Git 排除的 `Config/Local/`，不能公開。主機、群組、密碼與已結束 Logs 仍在 Mac 端加密後才同步；私鑰路徑與 known_hosts 不同步。

## 選用：設定自己的 App 內更新

更新來源在建置時指定，不由 App 設定畫面切換。使用自己的 HTTPS appcast 和 Sparkle Ed25519 公鑰；網址與金鑰必須對應自己的已簽署更新包。

```sh
export MYTERM_SPARKLE_FEED_URL="https://updates.example.org/appcast.xml"
export MYTERM_SPARKLE_PUBLIC_KEY="YOUR_BASE64_ED25519_PUBLIC_KEY"
```

在同一個終端機設定後，重新執行 README 的日常使用版建置區塊，或上方 Dev 指令。只有配置網址及公鑰不會產生可用更新；還須完成下方自有簽署資產與服務流程。請替換範例值；公鑰必須是 Base64 編碼的 32-byte Ed25519 公鑰。`build-app.sh` 也支援 `--sparkle-feed-url`／`--sparkle-public-key`。若設定 `MYTERM_SPARKLE_PUBLIC_KEY`，驗證工具優先核對該值；否則核對自行產生的 `Config/Release/SparklePublicKey.txt`（如有）。建置入口沿用安全通道與路徑規則，不直接覆蓋正式 App。

## 選用：獨立發行

發布給其他人前，先替自己的發行版建立獨立 App／資料身分，避免與其他 MyTerm 建置共享資料。核對 `Resources/Info.plist` 的 Bundle ID，以及 `build-app.sh`／`verify-app.sh` 的 development Bundle ID、Application Support 與 Keychain service 設定；若改身分，相關驗證也要同步更新。一般自用建置與 Dev 的身分不同，但不承諾多個一般衍生發行版可直接並存。

自行發行需要自己的固定 code-signing 身分、Sparkle 私鑰與可管理的 HTTPS 主機。私鑰保存在自己的 Keychain 並安全備份，不能寫入 repository。取得自己的簽章身分後，使用 `stage-code-signing-baseline.sh --identity <IDENTITY>` 建立本機基線；`create-sparkle-signing-key.sh` 產生自己的 Sparkle 公鑰。產生金鑰前先完成依賴建置。工具可能開啟 Keychain 或建立金鑰，請確認執行目的後再使用。

公開來源不附簽章基線。`Config/Release/` 在本來源中被 Git 排除，供自行產生的公鑰與 code-signing 基線使用。Sparkle 工具預設使用 `MyTerm.Source.Release.ed25519` 帳號，也可明確設定 `MYTERM_SPARKLE_KEY_ACCOUNT`；所有產生、簽署與驗證步驟需使用相同帳號。

要使用選用的發布工具，明確指定自己的更新基底網址：

```sh
export MYTERM_UPDATE_BASE_URL="https://updates.example.org"
export MYTERM_SPARKLE_KEY_ACCOUNT="MyTerm.Source.Release.ed25519"
./scripts/release.sh \
  --version 1.0.22 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --notes /path/to/your-release-notes.md \
  --prepare-only
```

範例值須替換，`--prepare-only` 不上傳。工具要求乾淨的 main 與 origin/main 一致、可用的自有簽章基線，以及通過完整測試。未指定合法 HTTPS 基底網址時停止；不預設任何維護者服務。`release.sh` 從基底網址建立 `/appcast.xml`，ZIP 位於 `/downloads/`；底層封裝與驗證工具共用同一 `MYTERM_UPDATE_BASE_URL`。自行啟用更新的 App 也應使用相同 feed 與公鑰。

移除 `--prepare-only` 會在目前 origin 所屬的 GitHub 專案建立 Draft Release；只有確認要在自己的 fork 發行時才執行。此來源專案本身維持 source-only。發行者需自行審閱並發布 ZIP、appcast、release notes、CHECKSUMS 及 manifest，維持版本／Build／雜湊／簽章一致。

`prepare-pages-deployment.sh` 可從自己的已簽署資產準備靜態部署資料；`verify-public-update-site.sh` 使用 `MYTERM_UPDATE_BASE_URL` 或明確的 `--base-url`。本專案不提供自動部署 workflow 或雲端憑證。你可自行部署到 Cloudflare Pages 或相容的 HTTPS 服務，見 [更新站說明](update-site/README.md)。

## 測試、資源與清理

- `run-tests.sh` 涵蓋核心、OAuth、加密同步、登入恢復及真實終端 renderer 測試；`run-crypto-tests.sh` 與 `run-sync-reliability-tests.sh` 可獨立執行。
- Firestore Rules 使用 `npm install` 後的 `npm run test:firestore-rules`；測試 Firebase Emulator，不連正式雲端。
- SwiftTerm runtime 固定於 `Vendor/SwiftTerm`，兩個 renderer hook 的來源與升級核對見 [UPSTREAM.md](Vendor/SwiftTerm/UPSTREAM.md)。保留 MIT 授權，升級後驗證來源、完整測試、乾淨建置與 App 互動。
- 包裝與 App 驗證使用 `verify-app.sh`、`verify-packaged-resources.sh`、`package-app.sh`。測試成功不能代替拖放、焦點、捲動、分割及真實連線驗收。
- `build/`、SwiftPM 快取與 ZIP 為可重建產物；清理前確認沒有程序執行、沒有待驗收或發布仍引用的資產。不清除使用者資料、Keychain、Config/Local 或簽章復原材料。

## 文件對照與維護

| 文件 | 繁體中文 | English |
|---|---|---|
| 專案介紹 | [README.md](README.md) | [README.en.md](README.en.md) |
| 架構 | [ARCHITECTURE.md](ARCHITECTURE.md) | [ARCHITECTURE.en.md](ARCHITECTURE.en.md) |
| 開發 | [DEVELOPMENT.md](DEVELOPMENT.md) | [DEVELOPMENT.en.md](DEVELOPMENT.en.md) |
| 安全 | [SECURITY.md](SECURITY.md) | [SECURITY.en.md](SECURITY.en.md) |
| Firebase | [FIREBASE_SETUP.md](FIREBASE_SETUP.md) | [FIREBASE_SETUP.en.md](FIREBASE_SETUP.en.md) |
| Termius | [TERMIUS_MIGRATION.md](TERMIUS_MIGRATION.md) | [TERMIUS_MIGRATION.en.md](TERMIUS_MIGRATION.en.md) |
| 更新站 | [README.md](update-site/README.md) | [README.en.md](update-site/README.en.md) |
| UpdateLab | [中文 fixture](Resources/UpdateLab/1.0.0-beta.2.md) | [英文對照](Resources/UpdateLab/1.0.0-beta.2.en.md) |

變更前先建立計劃與驗收案例，取得維護者確認；計劃末尾逐份盤點各語系，記錄需要／不需要更新、理由與結果。修改受影響的中英文文件與連結後才結案。UpdateLab 原 fixture 的引用不因翻譯改動；第三方授權與原始英文聲明保留原文。App 介面仍以繁體中文為主。

原創程式碼與文件採 [MIT License](LICENSE)；第三方素材適用自身條款，包括 [OpenAI 品牌素材](Resources/Readme/NOTICE.md)。請保留開發來源與原作者聲明，不把品牌工具署名當成官方背書。
