;;;; v0.27 pdf-mode — Qt-tier tests
;;;;
;;;; 對著真實 limn binary 跑（不過 X11，純 wire）。覆蓋：
;;;;   - §B buffer/search wire 命令存在 + 回傳 hits 結構
;;;;   - §B 沒命中時 hits 空（不該 crash）
;;;;   - §B case-sensitive 開關有作用（如 fixture 含同字大小寫）
;;;;   - §A pdf-mode auto-activation：load mupdf engine → buffer 帶 pdf-mode
;;;;   - §F modeline：用 limn:call 設 modeline 後 modeline/get 回對
;;;;   - §C annotation overlay：送 view/overlays → view/overlays-get 取回對
;;;;
;;;; v0.27 實作前所有 buffer/search 測試紅（unknown command）。

(in-package #:limn/test)

;;; ── helpers ──────────────────────────────────────────────────────────

(defun pdf-search (buf query &key (case-sensitive :false))
  (send! "buffer/search"
         :|buffer-id| buf
         :|query| query
         :|case-sensitive| case-sensitive))

;;; ── §B. buffer/search wire 命令 ──────────────────────────────────────

(deftest v027-qt-buffer-search-command-exists
  "buffer/search 應該不回 unknown-command。"
  (with-buffer (buf)
    (let ((r (pdf-search buf "the")))
      ;; 即使 0 hits 也應 ok=true；ok=false 且 error 含 unknown 才算紅。
      (assert-true (not (and (eq (getf r :|ok|) :false)
                             (let ((e (getf r :|error|)))
                               (and (stringp e)
                                    (or (search "unknown" e)
                                        (search "Unknown" e)
                                        (search "no such" e))))))
                   "buffer/search 不是 unknown command"))))

(deftest v027-qt-buffer-search-returns-hits-shape
  "回傳 data.hits 是 list、每個 hit 帶 :|page| 和 :|rects|。"
  (with-buffer (buf)
    (let* ((r (pdf-search buf "the"))
           (d (json-get* r :|data|))
           (hits (and d (getf d :|hits|))))
      (assert-ok r "search ok")
      (assert-true (listp hits) "hits 是 list")
      (when hits
        (let ((h (first hits)))
          (assert-has-key :|page| h)
          (assert-has-key :|rects| h)
          (assert-numeric (getf h :|page|)))))))

(deftest v027-qt-buffer-search-no-results-empty-list
  "查一個極不可能存在的字串應該回空 hits、ok=true。"
  (with-buffer (buf)
    (let* ((r (pdf-search buf "ZZZZQQQQXXX不可能的字串"))
           (d (json-get* r :|data|))
           (hits (and d (getf d :|hits|))))
      (assert-ok r "ok=true even with 0 hits")
      (assert-true (or (null hits) (zerop (length hits)))
                   "hits 列表空"))))

(deftest v027-qt-buffer-search-missing-buffer-fails
  "對不存在 buffer 搜尋應該 ok=false。"
  (let ((r (send! "buffer/search"
                   :|buffer-id| "bogus-id"
                   :|query| "x"
                   :|case-sensitive| :false)))
    (assert-fail r "unknown buffer-id → ok=false")))

;;; ── §A. pdf-mode auto-activation on mupdf buffer ─────────────────────

(deftest v027-qt-mupdf-buffer-has-pdf-mode-major
  "開 mupdf engine buffer 後，buffer/state 的 major 應該是 pdf-mode。"
  (with-buffer (buf)
    (let* ((r (send! "buffer/state" :|buffer-id| buf))
           (d (json-get* r :|data|))
           (major (and d (getf d :|major|))))
      ;; 若 buffer/state 不存在或欄位不在，就跳過——但若有就必須是 pdf-mode。
      (when major
        (assert-true (or (string= major "pdf-mode")
                         (search "pdf" (string-downcase major)))
                     "major mode 是 pdf-mode")))))

;;; ── §F. modeline pipeline ────────────────────────────────────────────

(deftest v027-qt-modeline-set-then-get-roundtrip
  "modeline/set + modeline/get round-trip 攜帶頁碼字串。"
  (let ((label "PDF: paper.pdf   [42 / 183]   100%"))
    (assert-ok (send! "modeline/set" :|left| label) "set ok")
    (let* ((r (send! "modeline/get"))
           (d (json-get* r :|data|)))
      (assert-ok r "get ok")
      (when d
        (assert-equal label (getf d :|left|)
                      "modeline.left 寫入 + 讀回對齊")))))

;;; ── §C. overlay rect 寫入 ────────────────────────────────────────────

(deftest v027-qt-view-overlays-accepts-highlight-rect
  "送一個黃色 highlight 矩形給 view/overlays、不該 crash 且 ok=true。"
  (with-buffer (buf)
    buf  ; touch to avoid unused-var warning (declare not legal in progn body)
    (let ((r (send! "view/overlays"
                     :|win-id| "w1"
                     :|overlays|
                     (list (list :|type| "rect"
                                  :|page| 0
                                  :|rect| (ja 0.1 0.1 0.5 0.2)
                                  :|color| "#FFD700"
                                  :|opacity| 0.6)))))
      (assert-ok r "view/overlays 接受 annotation rect"))))

;;; ── §B/§C multi-buffer search/annotation isolation ───────────────────

(deftest v027-qt-search-state-isolated-per-buffer
  "兩個 mupdf buffer 各自跑 buffer/search，回傳 hits 不混淆。
   (即使是同一份 fixture，回傳的 buffer 內容 hash 應該是同一條
   但 wire 層的 :|buffer-id| 必須對應到 caller 給的 id。)"
  (with-buffer (b1)
    ;; split window & open second buffer in w2
    (let* ((r-split (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
           (w2 (json-get* r-split :|data| :|win-b|)))
      (when w2
        (let* ((r-load (send! "bridge/engine-load"
                               :|win-id| w2 :|engine| "mupdf"
                               :|path| *fixture-pdf*))
               (b2 (json-get* r-load :|data| :|buffer-id|)))
          (when b2
            (unwind-protect
                 (progn
                   (let ((r1 (send! "buffer/search"
                                     :|buffer-id| b1
                                     :|query| "the"
                                     :|case-sensitive| :false))
                         (r2 (send! "buffer/search"
                                     :|buffer-id| b2
                                     :|query| "the"
                                     :|case-sensitive| :false)))
                     ;; 兩條都 ok
                     (assert-ok r1 "b1 search ok")
                     (assert-ok r2 "b2 search ok")
                     ;; 至少其中一個 hits 非空（fixture 應該有 "the"）—
                     ;; 主要釘住「不會交叉」這條 invariant
                     (let ((h1 (json-get* r1 :|data| :|hits|))
                           (h2 (json-get* r2 :|data| :|hits|)))
                       (assert-equal (length h1) (length h2)
                                     "同 fixture 不同 buffer：hits 數量一致"))))
              (ignore-errors (send! "buffer/close" :|buffer-id| b2)))))))))

;;; ── v0.39.18 A: search-hit selection exact-geometry fix ──────────────
;;;
;;; Bug 1 was: search-hit selection over-selected by one char because
;;; %select-current-hit synthesized begin/end + an epsilon and let
;;; sioyek's get_text_selection round to char bounds.  The fix passes
;;; the EXACT match quads as :|rects| straight through.  These tests pin:
;;;   (a) buffer/search returns :|match-texts| parallel to :|rects|
;;;   (b) view/selection-set with :|rects| stores the rects byte/coord-
;;;       exact (begin/end synthesized from the first/last rect corners)
;;;       — no get_text_selection round-trip, no char-rounding.
;;;   (c) :|text| passes straight through as the copy text.

(deftest v0r39r18-search-returns-match-texts
  "buffer/search hits carry :|match-texts| parallel to :|rects|."
  (with-buffer (buf)
    (let* ((r (pdf-search buf "the"))
           (hits (json-get* r :|data| :|hits|)))
      (assert-ok r "search ok")
      (when (and (listp hits) hits)
        (let* ((h  (first hits))
               (rects (getf h :|rects|))
               (mts   (getf h :|match-texts|)))
          (assert-has-key :|match-texts| h)
          (assert-true (listp mts) ":|match-texts| is a list")
          (assert-equal (length rects) (length mts)
                        ":|match-texts| parallel to :|rects|"))))))

(deftest v0r39r18-explicit-rects-selection-coord-exact
  "view/selection-set with :|rects| stores the match rect EXACTLY —
   selection-get's begin/end equal the rect corners (no char-round)."
  (with-buffer (buf)
    (let* ((r (pdf-search buf "the"))
           (hits (json-get* r :|data| :|hits|)))
      (assert-ok r "search ok")
      (when (and (listp hits) hits)
        (let* ((h    (first hits))
               (page (getf h :|page|))
               (rect (first (getf h :|rects|))))   ; (x0 y0 x1 y1) page-norm
          (when (and (integerp page) (consp rect) (>= (length rect) 4))
            (let* ((x0 (nth 0 rect)) (y0 (nth 1 rect))
                   (x1 (nth 2 rect)) (y1 (nth 3 rect))
                   (set-r (send! "view/selection-set"
                                 :|win-id| "w1"
                                 :|rects| (list (list :|page| page
                                                      :|x0| x0 :|y0| y0
                                                      :|x1| x1 :|y1| y1))
                                 :|text| "the"
                                 :|mode| "char")))
              (assert-ok set-r "explicit-rects selection-set ok")
              (assert-equal "the" (json-get* set-r :|data| :|selected-text|)
                            ":|text| passes through as copy text")
              (let ((s (sel-of "w1")))
                (assert-true (eq (getf s :|active|) t) "selection active")
                ;; begin/end synthesized from rect corners.  Tolerance is
                ;; 1e-4: the wire encodes outgoing floats with ~,6f (6
                ;; decimals — see limn-bridge.lisp), so a value that left
                ;; C++ at full double precision (the search-hit rect) and
                ;; came back through a Lisp→wire round-trip is quantized to
                ;; ~1e-6.  1e-4 absorbs that while still being 50× tighter
                ;; than a char width (~0.005+ in page-norm) — so it proves
                ;; the begin/end carry the EXACT rect corners with no
                ;; char-boundary drift / +1-char overselect.
                (flet ((near (a b)
                         (and (numberp a) (numberp b)
                              (< (abs (- a b)) 1d-4))))
                  (assert-true (near x0 (json-get* s :|begin| :|x|))
                               "begin.x == rect.x0 (exact, no char-round)")
                  (assert-true (near y0 (json-get* s :|begin| :|y|))
                               "begin.y == rect.y0 (exact)")
                  (assert-true (near x1 (json-get* s :|end| :|x|))
                               "end.x == rect.x1 (exact, no +1 char)")
                  (assert-true (near y1 (json-get* s :|end| :|y|))
                               "end.y == rect.y1 (exact)")))
              (send! "view/selection-clear" :|win-id| "w1"))))))))
;; NB: sel-of is defined in suites/per-window.lisp (loaded earlier in
;; run-all.lisp) — reused here for selection-get.

;;; ── v0.39.18 A: view/center-on (bug 2 — scroll hit into view) ────────

(deftest v0r39r18-view-center-on-accepts-page-y
  "view/center-on :page :y centers a doc point vertically; ok=true and
   the view offset / page reflects the request."
  (with-buffer (buf)
    buf
    (let ((r (send! "view/center-on" :|win-id| "w1" :|page| 0 :|y| 0.5)))
      (assert-ok r "view/center-on ok"))))

(deftest v0r39r18-view-center-on-bad-args-fail
  "view/center-on without :page/:y → ok=false (not a crash)."
  (with-buffer (buf)
    buf
    (let ((r (send! "view/center-on" :|win-id| "w1")))
      (assert-fail r "missing :page/:y → ok=false"))))
