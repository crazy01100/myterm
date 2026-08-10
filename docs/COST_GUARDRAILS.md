# MyTerm 零額外費用護欄

最後更新：2026-08-08

本文件是所有同步、發布與自動化工作的費用閘門。任何會新增付款方式、訂閱、計量帳單或年費的步驟，都必須先停下來重新取得使用者同意。

## 現階段核准範圍

| 服務 | 使用方式 | 預期費用 | 硬性護欄 |
|---|---|---:|---|
| Firebase Authentication | Google 社群登入 | NT$0 | Spark；不用電話驗證，不升級 Identity Platform |
| Cloud Firestore | 一個 `(default)` 資料庫 | NT$0 | Spark；不連結 Billing；超額即停用 |
| Google OAuth | Desktop client、基本身分 scope | NT$0 | 只用 `openid email profile`；不申請敏感／受限 scope |
| GitHub 儲存庫 | 先私人、日後可公開 | NT$0 | 不購買方案；不啟用付費大型 runner |
| GitHub Actions | 公開 repo 的標準 runner，或本機/self-hosted | NT$0 | 私人 repo 先只跑必要任務；未設付款方式時超額即停 |
| Cloudflare Pages | `mtus.lieniapp.work` 靜態更新站 | NT$0 | Free Direct Upload；不使用 Git integration、Pages Functions、R2 或付費 Worker；ZIP 必須小於 25 MiB |
| Cloudflare Worker | 不使用 | NT$0 | 目前架構沒有需求 |
| Apple Developer Program | 不加入 | NT$0 | Developer ID／公證改為未來可選升級 |
| Sparkle | 固定使用開源版 2.9.5 | NT$0 | 不購買額外服務；正式網址與金鑰分階段人工驗證 |

## 已查核的免費額度

- Firestore：1 GiB 儲存、每日 50,000 讀取、20,000 寫入、20,000 刪除、每月 10 GiB 外傳。
- Firebase Spark：Google 等社群登入免費；超過 Spark 的免費配額會停止服務，不會自動計費。
- Firebase Auth Spark：一般登入提供者每日 3,000 位活躍使用者。
- Google OAuth：只要求非敏感的基本身分 scope 時，不需要敏感／受限資料安全評估；個人用途少於 100 位使用者也屬可免完整驗證的情境。若日後要公開顯示自訂名稱與 Logo，可能需要較輕量的品牌驗證，但目前沒有必要為此新增付費服務。
- Cloudflare Pages Free：每月 500 次建置、每個站點 20,000 檔案、單檔 25 MiB。
- GitHub Actions：公開儲存庫使用標準 GitHub-hosted runner 免費；私人 GitHub Free 每月含 2,000 分鐘與 500 MB artifact storage。未設定有效付款方式時，額度用完會停止。
- Cloudflare Workers Free 雖有每日 100,000 請求，但 MyTerm 第一版不需要 Worker，避免多一個計量面。

官方來源：[Firebase 方案](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans)、[Firestore 定價](https://firebase.google.com/docs/firestore/pricing)、[Firebase Auth](https://firebase.google.com/docs/auth)、[Google OAuth 驗證](https://support.google.com/cloud/answer/13463073)、[Google OAuth 免驗證情境](https://support.google.com/cloud/answer/13464323)、[GitHub Actions 計費](https://docs.github.com/en/billing/concepts/product-billing/github-actions)、[Cloudflare Pages 限制](https://developers.cloudflare.com/pages/platform/limits/)、[Cloudflare Workers 定價](https://developers.cloudflare.com/workers/platform/pricing/)。

## 會觸發停工與重新確認的事件

- Firebase 或 Google Cloud 畫面要求綁信用卡或 Billing Account。
- Firebase 專案準備從 Spark 轉為 Blaze。
- 使用 Cloud Functions、Cloud Run、Storage、Phone Auth、額外 Firestore database、TTL、PITR、Backup、Restore 或 Clone。
- Google OAuth 要求敏感或 restricted scopes、第三方安全評估或付費驗證。
- GitHub 要求付費 runner、付費儲存、方案升級或購買 Actions 分鐘。
- Cloudflare 要求 Workers Paid、R2 超額或 Pages 方案升級。
- Apple Developer Program、Developer ID 或公證再次進入必做路徑。
- 新增任何未列在本文件的 SaaS、套件授權或訂閱。

## 現階段可接受的限制

- 未付 Apple 年費的分享版會是 ad-hoc 簽署；其他人第一次開啟時可能需要右鍵選「打開」，無法達到正式 Developer ID 公證版的無警告體驗。
- 私人 GitHub Actions 額度用完時，CI 停止；不自動購買更多分鐘。Release 可改成本機 ARM Mac 建置並手動上傳。
- Firebase 免費額度用完時，同步暫停，但 MyTerm 的本機主機管理、Keychain 與 SSH 連線必須繼續運作。
- Cloudflare 只放靜態更新檔與說明頁；目前 ZIP 約 6.3 MB，可由 Pages 公開提供。若未來單一 ZIP 接近 25 MiB，先停止發布並重新評估公開 release-only repository 或 R2，不自動啟用付費服務。
