#!/bin/bash
# Synthetic, read-only visual fixture. No remote commands or real host data.
printf '\033[0mMyTerm — 終端配色驗收 / ANSI color preview\n\n'
printf '一般文字：檔案、路徑與中文輸出，維持清楚的閱讀層次。\n'
printf '\033[1;34mdocuments/  scripts/  reports/\033[0m  README.md  \033[1;31marchive.zip\033[0m\n\n'
printf '訊息標籤分色（以下全部送出相同的預設文字色）：\n'
printf '[資訊] 正在檢查設定與執行結果\n'
printf '[警告] 請確認設定，需要留意這個項目。\n'
printf '[合格] 所有檢查項目符合要求\n'
printf '[成功] 作業完成，結果已準備好\n'
printf '[錯誤] 範例訊息：檔案不存在，請檢查路徑。\n'
printf '[除錯] Synthetic diagnostic message\n'
printf '[提示] 可選取文字並測試字體放大、縮小。\n\n'
printf '\033[33m[資訊] 原本同為黃色的輸出，只有標籤改色。\033[0m\n'
printf '\033[33m[警告] 原本同為黃色的輸出，只有標籤改色。\033[0m\n'
printf '\033[32m[合格] 原本同為綠色的輸出，只有標籤改色。\033[0m\n'
printf '\033[32m[成功] 原本同為綠色的輸出，只有標籤改色。\033[0m\n\n'
for style in 0 1; do
    printf 'ANSI style %s: ' "$style"
    for color in 30 31 32 33 34 35 36 37; do
        printf '\033[%s;%sm Aa字 \033[0m' "$style" "$color"
    done
    printf '\n'
done
printf 'Bright slots: '
for color in 90 91 92 93 94 95 96 97; do
    printf '\033[%sm Aa字 \033[0m' "$color"
done
printf '\n\n\033[40;97m explicit black / white \033[0m  \033[7m reverse / 反白 \033[0m\n'
printf '\033[38;5;196m256-index red (unchanged)\033[0m  \033[38;2;180;90;160mRGB (unchanged)\033[0m\n'
printf '\n切換淺色／深色／自動後，既有 ANSI 文字應同步套用色盤。\n'
printf '「設定 → 外觀 → 訊息等級標籤分色」可關閉標籤效果。\n'
