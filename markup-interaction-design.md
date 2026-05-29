# 標記系統互動設計 (Markup Interaction Design)

狀態:設計定稿,分階段實作中。
分支:`feat/markup-interaction`。

## 背景:為什麼要重做

目前畫面上疊了三套「色塊」,使用者分不清、也無法可靠操作既有標記:

1. **limn annotation**(`H` / `M-h` 建立)— 持久,存 sidecar,半透明填色。
2. **搜尋 highlight**(`/`)— 短暫的系統回饋,卻長得跟 (1) 一樣是色塊。
3. **PDF 原生 annotation** — 檔案內嵌,由 MuPDF render。

而且 `v` / `M-t` / `E` / `D`(對既有標記操作的指令)實際上**無法命中**任何標記,原因有二:

- **沒有「使用者指了哪裡」的輸入**。`%annotation-at-current-point` 拿 `view/get` 的 `offset-x/offset-y`(viewport 的捲動位置)當作「point」,但捲動位置不是「我要這個標記」的意圖。
- **座標系不符**。那個 offset 是 sioyek 的*絕對 document 座標*(y 跨頁累加),annotation rect 卻是*頁內座標* — 兩者尺度不同,hit-test 幾乎永遠 false,結果永遠 echo `"No annotation here"`。

## 核心原則

**持久標記(我做的)與短暫回饋(系統的)必須視覺正交 — 它們不該長得像。**

## 概念分類

| 類別 | 本質 | 生命週期 | 擁有者 |
|---|---|---|---|
| limn highlight | 我刻意做的標記 (markup) | 持久 (sidecar) | 使用者 |
| 搜尋結果 | 系統的暫時回饋 (feedback) | 短暫,自動消失 | 系統 |
| PDF 原生 | 外部資料 | 持久 (檔案內) | 別的工具 |

## (甲) 視覺語言:用不同 channel,不是只有顏色

色塊疊色塊一定糊,因為搶同一個視覺 channel(填色)。每一類佔用獨立 channel:

- **limn highlight** = 半透明**填色**(使用者選色)。唯一用「填滿」的。
- **limn highlight 有 note** = 填色 + 頁邊 **margin note icon**(沿用 icon-overlay / PR4)。
- **搜尋結果** = **不填色**,改用**底線**(保留系統色,例如青/藍),current match 加亮。短暫、自動消失。
- **目前選中的標記** = **focus ring**(明亮邊框)+ 稍強填色。鍵盤現在作用在這一個的唯一視覺。
- **PDF 原生** = 不另做視覺;改用 show/hide toggle(見丁)。

五個獨立 channel(填色 / 底線 / focus ring / margin icon / show-hide)疊起來仍可讀。

## (乙) 互動模型:清單為主,in-page 為輔

PDF 沒有原生文字游標 (point);新模型的 point 由**使用者真正指出來的輸入**產生,並一律用**頁座標**(頁碼 + 頁內 0..1 的 x,y)hit-test。

三層:

- **Layer 1 — 清單 buffer(管理主力,逃生門)。**
  把 `M-N`(list-notes)升級成可操作的 occur/tablist buffer:一行一個標記,顯示頁碼、預覽、tags、type。`RET` 跳轉並選中、`e` 編輯 note、`t` 改 tags、`d` 刪除、`/` 篩 tag。當標記在頁面上互相重疊、點不準時,清單是逃生門。
- **Layer 2 — in-page current annotation(快速路徑)。**
  per-window 的 PDF point,由兩種方式設定:
  - **滑鼠點擊** → 經 `window_to_document_pos` 取得 `(頁, 頁內座標)`。
  - **`Tab` / `S-Tab`** → 循環當前頁的標記清單(不需要座標)。
  point 命中(或循環選到)的標記成為 **current annotation**,畫 focus ring。
  `v` / `E` / `M-t` / `D` 一律改成對 **current annotation** 操作。順帶根治座標 bug(統一頁座標)。
- **Layer 3 — margin gutter(發現性,後續)。**
  頁邊細欄,每個標記一個 marker(有 note 用 note icon)。跟 icon-overlay 同源,後階段做。

## (丙) 搜尋結果改底線

把搜尋 overlay 從填色色塊改成底線樣式(current match 加亮)。這是最痛點、也最獨立的一刀,先做。

## (丁) PDF 原生:show/hide toggle

不做特別視覺。提供 `pdf-toggle-native-annotations`(per-buffer 狀態,預設顯示)。技術上靠 MuPDF render 頁面時的 annotation 旗標:關掉時重新 render 一張不含原生 annotation 的頁面圖。

## 實作順序(風險低 → 高,每步可單獨驗證)

1. **(丙) 搜尋結果改底線** — 立刻解掉「疊在一起分不清」最痛的部分。
2. **(乙 Layer 1) `M-N` 清單 buffer** — 逃生門先有,不依賴 in-page targeting。
3. **(乙 Layer 2) in-page current annotation** — click + `Tab` 選取 + focus ring,`v`/`E`/`M-t`/`D` 改對 current annotation;修掉座標 bug。
4. **(丁) PDF 原生 toggle**。
5. **(甲/乙 Layer 3) margin gutter / note icon** — 跟 icon-overlay 整合。

## 不在本次範圍

- 編輯 PDF 原生 annotation(目前只 show/hide)。
- 把原生 annotation 匯入 sidecar。
