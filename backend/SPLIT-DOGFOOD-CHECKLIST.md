# 視窗分割（Phase 3b）人工驗收清單

這份清單配合 `backend/dogfood-split.sh` 使用，目的是讓你回來時用**最少的摩擦**
就能親眼確認「真正的兩個獨立 pane」是否成立。每一項都寫好預期結果與「壞掉長怎樣」，
照著做、打勾即可。

> 架構回顧：每個 tiled window 1:1 對應一個擁有自己 `DocumentView` +
> `PdfViewOpenGLWidget` 的 pane（肥做法）；`db_manager_` / `document_manager_` /
> `checksummer_` / `pdf_renderer_`（4 條 thread）/ `fz_context` 維持共用。
> 鍵盤事件不帶 win-id，由 backend 自己的 focused window 派發；`set_focused_win`
> 會把 `document_view_` 與 `opengl_widget_` 重指到 focused pane，所以 j/k 等
> 導航一定落在「有焦點邊框」的那一格。

---

## 0. 啟動（一行指令）

```bash
cd /tmp/ph3-split
./backend/dogfood-split.sh                 # 開 tutorial.pdf，左右分割
# 或：./backend/dogfood-split.sh /path/to.pdf v   # 指定 PDF、上下分割
```

會自動：開可見 Qt 視窗 → 開檔 → 切成兩個 pane → 落到 SBCL 提示字元。
之後所有 `(sp ...)` / `(wf ...)` / `(wc ...)` 都在那個提示字元打。

---

## 1. 分割：真的長出第二個 pane

- [ ] 啟動後視窗**左右各一格**（`v` 模式則上下各一格），中間有可拖的分隔線。
- [ ] 兩格都看得到 PDF 內容（同一份文件、同一頁），**不是**一邊白的。
- 壞掉長怎樣：只有一格、第二格全白/全黑、或整個視窗沒分割 → 記下來。

## 2. 焦點邊框：看得出哪一格是 focused

- [ ] 其中一格有**藍色 accent 邊框**（`#4a90d9`），另一格是灰色（`palette(mid)`）。
- [ ] 單一 pane 時（還沒分割、或關到剩一格）**完全沒有邊框**，跟舊版一模一樣。
- 壞掉長怎樣：兩格都有藍框、或都沒框、或邊框讓畫面跳動位移。

## 3. 焦點移動：`(wf "w2")` 邊框會跟著跑

- [ ] 在提示字元打 `(wf "w2")` → 藍色邊框從 w1 跳到 w2。
- [ ] 再打 `(wf "w1")` → 邊框跳回 w1。
- 壞掉長怎樣：邊框不動、跑錯格、或 Qt crash。

## 4. 鍵盤只驅動 focused pane（最關鍵的一項）

- [ ] `(wf "w1")` 後，點一下 Qt 視窗讓它收鍵盤，按 `j`/`k`（或空白鍵）翻頁 →
      **只有 w1 那格**在動，w2 不動。
- [ ] `(wf "w2")` 後再按 `j`/`k` → **換成 w2 在動**，w1 不動。
- 壞掉長怎樣：兩格一起動、或永遠只有 w1 動（代表 set_focused_win 沒重指成功）。

## 5. 捲動獨立：滑鼠滾輪只動游標所在格

- [ ] 滑鼠移到 w1 上滾 → 只有 w1 捲動；移到 w2 上滾 → 只有 w2 捲動。
- 壞掉長怎樣：滾一格兩格一起跑（代表兩格其實共用同一個 DocumentView）。

## 6. 多層分割：可以一直切

- [ ] `(wf "w2")` 後 `(sp "v")` → w2 那格再上下切成兩格（總共三格）。
- [ ] `(wins)` 列出 w1 / w2 / w3 三個 tiled window。
- 壞掉長怎樣：切不出來、或新格沒內容、或焦點亂掉。

## 7. 關閉 pane：`(wc ...)` 乾淨收掉、焦點自動轉移

- [ ] `(wc "w3")` → w3 那格消失，剩下的格子補滿空間。
- [ ] 若關掉的是 focused 格，焦點**自動轉移**到存活的格（藍框出現在別格）。
- [ ] 一路關到剩最後一格時，`(wc "w1")` 會被**拒絕**（不能關最後一格），
      且此時邊框消失、畫面回到單格舊版樣子。
- 壞掉長怎樣：關 pane 後 crash、殘留空白格、或焦點指向已刪除的格（之後一按鍵就 crash）。

## 8. 收尾

- [ ] `(q)` → limn 子行程被殺、SBCL 乾淨離開、沒有殘留視窗或殭屍行程。

---

## 提示字元速查

| 指令          | 作用                                              |
|---------------|---------------------------------------------------|
| `(sp "h")`    | 水平分割 focused pane（左右），回傳新的 win-id     |
| `(sp "v")`    | 垂直分割（上下）                                  |
| `(wf "w2")`   | 把焦點（邊框＋鍵盤）移到 w2                        |
| `(wc "w2")`   | 關掉 w2 這個 pane（焦點自動轉移）                  |
| `(wins)`      | 列出所有 window（哪個 `:focused T`）               |
| `(vg "w1")`   | 讀 w1 的 view 狀態（page/zoom/offset）             |
| `(tree)`      | 印 Qt widget 樹，含 `*FOCUS*` 標記                |
| `(grab "/tmp/g.png")` | 存一張目前畫面截圖到磁碟                   |
| `(q)`         | 離開（殺掉 limn 子行程）                           |

---

## 已知小限制（不是 bug，3b 範圍外）

- **分割後的旋轉**：對非 focused pane 套用 rotation 的視覺更新有已知小限制
  （win-focus 還原快照時 rotation 區塊維持原樣），留待後續處理。
- **notes-panel 並存**：M-N 註解清單側欄與真實 window-split 尚未統合
  （WINDOW-SYSTEM-DEBT，Phase 3c 處理）。同時開兩者時版面可能互搶，先別混用。

## 自動煙霧測試（不需肉眼，給 CI/快速確認用）

headless 跑完整 open→split→focus→close→關到剩一格 的生命週期、確認不 crash：

```bash
cd /tmp/ph3-split
LIMN_BIN=/tmp/ph3-split/sioyek/limn.app/Contents/MacOS/limn \
  ./backend/run-repl.sh \
    --eval '(o "/tmp/ph3-split/sioyek/tutorial.pdf")' \
    --eval '(sleep 0.4)' --eval '(p)' \
    --eval '(sp "h")' --eval '(wins)' \
    --eval '(wf "w2")' --eval '(wc "w2")' --eval '(wins)' \
    --eval '(q)'
```

預期：`split w1 → w1 + w2`、`wins` 出現 w1+w2、`closed w2`、最後 `wins` 回到單一 w1。
