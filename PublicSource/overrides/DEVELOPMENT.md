# 自行建置與維護 MyTerm

**繁體中文** | [English](DEVELOPMENT.en.md)

這個專案只發布原始碼、必要素材與文件，不提供 App 安裝包、代管 Firebase 或更新站。MyTerm 以維護者自己的工作習慣為出發點；你可以修改功能、自己建置，並決定是否建立自己的發行與更新服務。

## 本機建置

需要 Apple Silicon、macOS 26、Xcode 26／相容 Command Line Tools（Swift 6.2）、Git 與 ripgrep。雲端設定工具另需 jq；Firestore Rules 測試另需 Node.js 24 與專案 npm 相依套件。

```sh
git clone https://github.com/crazy01100/myterm-source.git
cd myterm-source
./scripts/run-tests.sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --build-only
```

版本僅為範例，請依自己的目標調整。移除 `--build-only` 可由同一安全入口啟動 App；每次啟動核對實際路徑、版本、Build、Bundle ID、簽章與 development 通道。腳本只終止本 checkout 固定 `build/dev/MyTerm Dev.app` 路徑的程序，不終止 `/Applications/MyTerm.app`；其他非標準 MyTerm 程序會阻擋操作。

預設為 MyTerm Dev，使用獨立 Bundle ID、Application Support 與機密保管庫 service。沒有本機簽章身分時使用 ad-hoc code signing；不需維護者的憑證、雲端設定或更新公鑰。移交別台 Mac 時，可放在穩定可寫入目錄，例如 `~/Applications/MyTerm Dev.app`；App 不依賴 checkout 的絕對路徑。跨裝置使用仍須核對實際 App 身分。

## 更新自己的建置

最簡單的方法是取得新版原始碼並重新建置：

```sh
git pull --ff-only
./scripts/run-tests.sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.2 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

有自己的修改時先處理 Git 合併，再建置。預設沒有 `SUFeedURL`，App 不會連到任何預設更新站；只有 Sparkle 公鑰但沒有網址也不會啟動更新器。

## 設定自己的同步服務

本機功能不需要帳號。Google 登入及跨裝置同步需依 [Firebase 設定](FIREBASE_SETUP.md) 建立自己的 Firebase／Google OAuth 專案。真實設定只放在 Git 排除的 `Config/Local/`，不能公開。主機、群組、密碼與已結束 Logs 仍在 Mac 端加密後才同步；私鑰路徑與 known_hosts 不同步。

## 選用：設定自己的 App 內更新

更新來源在建置時指定，不由 App 設定畫面切換。使用自己的 HTTPS appcast 和 Sparkle Ed25519 公鑰；網址與金鑰必須對應自己的已簽署更新包。

```sh
export MYTERM_SPARKLE_FEED_URL="https://updates.example.org/appcast.xml"
export MYTERM_SPARKLE_PUBLIC_KEY="YOUR_BASE64_ED25519_PUBLIC_KEY"
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --build-only
```

請替換範例值；公鑰必須是 Base64 編碼的 32-byte Ed25519 公鑰。`build-app.sh` 也支援 `--sparkle-feed-url`／`--sparkle-public-key`。若設定 `MYTERM_SPARKLE_PUBLIC_KEY`，驗證工具優先核對該值；否則核對自行產生的 `Config/Release/SparklePublicKey.txt`（如有）。建置入口沿用安全通道與路徑規則，不直接覆蓋正式 App。

## 選用：獨立發行

發布給其他人前，先替自己的發行版建立獨立 App／資料身分，避免與其他 MyTerm 建置共享資料。核對 `Resources/Info.plist` 的 Bundle ID，以及 `build-app.sh`／`verify-app.sh` 的 development Bundle ID、Application Support 與 Keychain service 設定；若改身分，相關驗證也要同步更新。這項來源預設供本機 Dev 使用，不承諾多個衍生發行版可直接並存。

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
