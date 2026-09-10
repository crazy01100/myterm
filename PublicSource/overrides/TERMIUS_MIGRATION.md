# 從 Termius 遷移主機資料

**繁體中文** | [English](TERMIUS_MIGRATION.en.md)

MyTerm 可以匯入 repository 內轉換工具所產生的 `myterm-termius-host-export-v1` JSON，保留主機名稱、位址、連接埠、使用者名稱、多層群組及可辨識的平台資訊。匯入前會先顯示群組、主機、重複連線與無效項目的預覽；使用者確認前不會修改現有資料。

## 先了解資料邊界

- MyTerm App 不會直接開啟或解析 Termius Vault 資料庫。
- Repository 提供的 `scripts/TermiusExport/export_decrypted_metadata.js` 是選用的進階轉換工具，不是一鍵式的 Termius 官方匯出器。它只接受相容的主機／群組中繼資料輸入，並在使用者自己的 Mac 上透過已安裝的 Termius 執行環境轉換欄位。
- Repository 刻意不提供讀取或擷取 Termius Vault 資料庫的工具；如果目前只有 Termius App、沒有相容的中繼資料輸入，就不能直接執行這支轉換腳本完成搬遷。
- 工具不讀取或輸出密碼、私鑰、私鑰密語、Token 或其他登入憑證；使用私鑰的主機只保留「曾參照私鑰」標記，匯入後需在 MyTerm 重新設定 SSH Agent、SSH config 或本機私鑰。
- Termius 內部模組不是 MyTerm 控制的公開 API，Termius 更新後路徑或格式可能改變。若不具備相容輸入，可把 Termius 官方提供的明文匯出內容作為人工搬遷參考，或在 MyTerm 手動建立主機；MyTerm 不直接匯入一般 CSV 或 Termius Vault 原始檔。

即使不含密碼，輸出檔仍可能包含真實主機名稱、IP、使用者名稱、群組與內部環境結構，應視為私人設定資料，不要提交到 GitHub、Issue 或公開訊息。

## 轉換工具需求

- Apple Silicon Mac。
- Termius 安裝於 `/Applications/Termius.app`，且目前 macOS 使用者可以正常開啟自己的 Termius 資料。
- 一份相容的中繼資料輸入 JSON；頂層需包含 `groups` 與 `hosts` 陣列，且不得加入密碼或私鑰欄位。
- 請只處理自己擁有或獲授權管理的資料，並先保留原始資料備份。

## 產生 MyTerm 可匯入檔案

以下範例把輸出放在 repository 的 `Exports/Termius/`。整個 `Exports/` 已由 Git 排除，適合保存本機遷移過程中的私人產物：

```sh
ELECTRON_RUN_AS_NODE=1 /Applications/Termius.app/Contents/MacOS/Termius \
  scripts/TermiusExport/export_decrypted_metadata.js \
  /path/to/metadata-input.json \
  Exports/Termius
```

成功後會產生：

- `termius-hosts.json`：MyTerm 可匯入的結構化資料，檔案權限設為 `0600`。
- `termius-hosts.csv`：只供人工檢查，MyTerm 不直接匯入 CSV，檔案權限同樣設為 `0600`。

JSON 內的 `summary` 會依本次資料動態列出群組數、主機數、缺少使用者名稱的主機、參照私鑰的主機及重複連線數；這些數字不是 MyTerm 的固定限制。

## 匯入 MyTerm

1. 在 MyTerm 選擇「資料 → 匯入主機資料…」，或到「設定 → 匯入與匯出」。
2. 選擇產生的 `termius-hosts.json`。
3. 檢查群組、主機、重複與無效項目預覽；需要先少量驗證時，可切換為自訂選擇並只勾選部分主機。
4. 確認後才套用資料。MyTerm 會先建立目前主機資料的本機備份。
5. 重新設定未遷移的密碼、私鑰或其他驗證方式，並先測試少量主機連線。

重複連線以「主機位址 + 連接埠 + 使用者名稱」判斷，預設跳過，也可以選擇保留兩筆；MyTerm 不會直接覆蓋既有主機。

## 清理私人輸出

完成遷移並確認備份策略後，可自行刪除 `Exports/` 中不再需要的 JSON／CSV。刪除前請確認檔案不再用於匯入或復原；repository 的發布與建置流程不需要這些輸出檔。
