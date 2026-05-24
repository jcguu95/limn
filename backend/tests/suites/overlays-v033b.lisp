;;;; v0.33b Qt-tier — text-buffer overlay paint + buffer/codepoint-rects wire
;;;;
;;;; 走真 limn binary，但走 wire（不需 xdotool）。三節：
;;;;
;;;;   §A buffer/codepoint-rects 新 wire (Q1-Q6)
;;;;     直接 invoke 新指令、驗 rects shape / 數量 / 多行切分 / wrap 切分。
;;;;
;;;;   §B view/overlays + type:"text-range" paint (Q7-Q10)
;;;;     Lisp 推 text-range layer → C++ 動態 layout → screenshot 找色塊。
;;;;     並與 PDF rect layer 共存、priority 規則仍對。
;;;;
;;;; 全部 RED 直到 limn_command.cpp 加 cmd_buffer_codepoint_rects +
;;;; text-range layer 分支 + limn-overlays.lisp 加 buffer-kind dispatch。

(in-package #:limn/test)

;; v0.33b 也走 in-process load（跟 marker-v030 / overlays-v033 同 pattern）
(let* ((suite-dir (make-pathname :defaults (or *load-pathname*
                                                *default-pathname-defaults*)
                                  :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir)))
  (dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
               "limn-marker.lisp" "limn-local.lisp" "limn-mark.lisp"
               "limn-face.lisp"
               "limn-overlays.lisp"
               "limn-region.lisp"))
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

(when (find-package '#:limn/marker)
  (let ((f (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER" '#:limn/marker)))
    (when f (funcall f))))

;;; ── helpers ───────────────────────────────────────────────────────────────

(defun region-bbox (x0 y0 x1 y1 match-color)
  (json-get* (send! "test/region-bbox"
                    :|x0| x0 :|y0| y0 :|x1| x1 :|y1| y1
                    :|match-color| match-color)
             :|data|))

(defun page-pixel-rect (&key (win-id "w1") (page 0))
  (json-get* (send! "test/page-pixel-rect" :|win-id| win-id :|page| page)
             :|data|))

(defun sync-faces! (&rest face-plists)
  (send! "display/sync-faces" :|faces| face-plists))

(defmacro with-text-buffer ((buf) &body body)
  "v0.33 §B 同一 helper；reset overlay / mark / region state。"
  `(let* ((r0 (send! "bridge/engine-load"
                     :|win-id| "w1" :|engine| "text" :|path| ""))
          (,buf (json-get* r0 :|data| :|buffer-id|)))
     (drain-events)
     (when (find-package '#:limn/overlays)
       (let ((f (find-symbol "RESET-OVERLAYS" '#:limn/overlays)))
         (when f (funcall f ,buf))))
     (when (find-package '#:limn/mark)
       (let ((f (find-symbol "RESET-MARKS" '#:limn/mark)))
         (when f (funcall f ,buf))))
     (unwind-protect (progn ,@body)
       (when ,buf
         (ignore-errors (send! "buffer/close" :|buffer-id| ,buf))))))

(defun codepoint-rects (buf start end &optional (win "w1"))
  "Invoke buffer/codepoint-rects, return list-of-plist (each {:page :rect})."
  (let* ((r (send! "buffer/codepoint-rects"
                   :|buf-id| buf :|win-id| win
                   :|start| start :|end| end))
         (d (json-get* r :|data|)))
    (and d (getf d :|rects|))))

(defun call-with-text-range-overlay (buf start end face)
  "Helper: send a single text-range layer via view/overlays."
  (send! "view/overlays" :|win-id| "w1"
         :|layers|
         (list (list :|type| "text-range"
                     :|buf-id| buf
                     :|start| start :|end| end
                     :|face| face
                     :|opacity| 0.5))))

;;; ════════════════════════════════════════════════════════════════════════
;;; §A buffer/codepoint-rects 新 wire (Q1-Q6)
;;; ════════════════════════════════════════════════════════════════════════

(deftest v033b-q1-short-range-single-rect
  "對單行中段範圍 [3,8) → 回一個 rect、x 軸寬度 > 0、座標都是 number。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world example")
    (drain-events)
    (let ((rects (codepoint-rects buf 3 8)))
      (assert-true rects "rects 非空")
      (assert-equal 1 (length rects)
                    (format nil "單行範圍 → 1 rect (got ~A)" (length rects)))
      (let* ((r0 (getf (first rects) :|rect|))
             (x0 (first r0)) (y0 (second r0))
             (x1 (third r0)) (y1 (fourth r0)))
        (assert-true (numberp x0) "x0 numeric")
        (assert-true (numberp y0) "y0 numeric")
        (assert-true (> x1 x0) (format nil "width > 0 (~A→~A)" x0 x1))
        (assert-true (> y1 y0) (format nil "height > 0 (~A→~A)" y0 y1))))))

(deftest v033b-q1-empty-range-empty-rects
  "start == end → 回 :ok t 且 rects = []。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello")
    (drain-events)
    (let ((rects (codepoint-rects buf 2 2)))
      (assert-equal 0 (length rects)
                    (format nil "empty range → 0 rects (got ~A)"
                            (length rects))))))

(deftest v033b-q1-multi-line-multiple-rects
  "範圍跨 \\n（如 \"line1\\nline2\" 全選）→ 回兩個 rect、第二個 y 較大。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "line1
line2
line3")
    (drain-events)
    (let ((rects (codepoint-rects buf 0 17)))  ; "line1\nline2\nline3" len=17
      (assert-true (>= (length rects) 3)
                   (format nil "三行 → >=3 rects (got ~A)" (length rects)))
      ;; y 軸單調遞增（每段 rect 的 y 應該比上一段大或等）
      (when (>= (length rects) 2)
        (let* ((r0 (getf (first  rects) :|rect|))
               (r1 (getf (second rects) :|rect|))
               (y0 (second r0))
               (y1 (second r1)))
          (assert-true (>= y1 y0)
                       (format nil "y monotonic (~A → ~A)" y0 y1)))))))

(deftest v033b-q1-narrow-window-wrapped-line
  "視窗很窄 + 長行 → 一條邏輯行被 Qt 自動 wrap 成多段 → rects > 1。
   注意：QPlainTextEdit 預設開 wrap，這裡只是驗 backend 走 wrap 路徑後也分
   多段。"
  (with-text-buffer (buf)
    ;; 故意塞超長一行
    (send! "buffer/insert" :|buffer-id| buf
           :|text| "the quick brown fox jumps over the lazy dog and then jumps back over and over")
    (drain-events)
    ;; Force narrow viewport: 用 test/inject-resize push event。
    ;; （C++ 端拿到 event 後 widget 會 reflow。實際 widget resize 在 OS-tier。）
    (send! "test/inject-resize" :|win-id| "w1" :|width| 200 :|height| 400)
    (drain-events)
    (let ((rects (codepoint-rects buf 0 77)))
      ;; 在 200 px 寬 viewport 上 77 char 應該至少 wrap 成 2 段
      (assert-true (>= (length rects) 2)
                   (format nil "wrap 至少 2 段 (got ~A)" (length rects))))))

(deftest v033b-q1-range-clamp-or-fail
  "end > buffer length → C++ 端要嘛 clamp 到 length、要嘛回 :ok false。
   不應 crash、不應回 garbage rects。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "abc")
    (drain-events)
    (let* ((r (send! "buffer/codepoint-rects"
                     :|buf-id| buf :|win-id| "w1"
                     :|start| 0 :|end| 999)))
      (assert-true (or (eq (getf r :|ok|) t)
                       (stringp (getf r :|error|)))
                   ":ok=t 或帶 :error，不該 crash")
      ;; 若 ok = t，rects 應 <= text 長度 對應的 rect 數
      (when (eq (getf r :|ok|) t)
        (let ((rects (and (getf r :|data|)
                          (getf (getf r :|data|) :|rects|))))
          (assert-true (listp rects)
                       "ok t → rects 至少是 list"))))))

(deftest v033b-q1-bad-buffer-id-fails
  "不存在 buf-id → :ok false + :error。"
  (let ((r (send! "buffer/codepoint-rects"
                  :|buf-id| "no-such-buf" :|win-id| "w1"
                  :|start| 0 :|end| 5)))
    (assert-false (eq (getf r :|ok|) t)
                  "不存在 buf-id → 不是 :ok=t")
    (assert-true (stringp (getf r :|error|))
                 "回 :error 字串")))

;;; ════════════════════════════════════════════════════════════════════════
;;; §B view/overlays + type:"text-range" paint (Q7-Q10)
;;; ════════════════════════════════════════════════════════════════════════

(deftest v033b-q7-text-range-layer-paints
  "送 type:\"text-range\" layer 到 view/overlays → screenshot 找到該 face
   的色塊（C++ 端動態 layout）。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world example")
    (drain-events)
    (sync-faces! (list :|name| "v033b-tr1"
                       :|background| "#22aa55"))
    (assert-ok (call-with-text-range-overlay buf 5 11 "v033b-tr1"))
    ;; 找色塊
    (let* ((pr (page-pixel-rect))
           (bbox (region-bbox (getf pr :|x|) (getf pr :|y|)
                              (+ (getf pr :|x|) (getf pr :|w|))
                              (+ (getf pr :|y|) (getf pr :|h|))
                              "#22aa55")))
      (assert-true bbox "found green text-range highlight")
      (when bbox
        (assert-true (> (getf bbox :|w|) 5)
                     (format nil "bbox width > 5 (~A)" (getf bbox :|w|)))))))

(deftest v033b-q8-text-range-and-pdf-rect-coexist
  "同 win-id 同時送 type:\"text-range\" + type:\"rect\" layer →
   兩個 face 的色塊都該畫上（畫家路徑相容）。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "AAAAAAAAAAAA")
    (drain-events)
    (sync-faces! (list :|name| "v033b-tr2"   :|background| "#3366ff")
                 (list :|name| "v033b-rect2" :|background| "#ff3300"))
    (assert-ok (send! "view/overlays" :|win-id| "w1"
                      :|layers|
                      (list (list :|type| "text-range"
                                  :|buf-id| buf
                                  :|start| 0 :|end| 5
                                  :|face| "v033b-tr2"
                                  :|opacity| 0.6)
                            (list :|type| "rect"
                                  :|page| 0
                                  :|x0| 0.6 :|y0| 0.6 :|x1| 0.95 :|y1| 0.95
                                  :|face| "v033b-rect2"
                                  :|opacity| 1.0))))
    (let* ((pr (page-pixel-rect))
           (px (+ (getf pr :|x|) (getf pr :|w|)))
           (py (+ (getf pr :|y|) (getf pr :|h|)))
           (bbox-text (region-bbox (getf pr :|x|) (getf pr :|y|)
                                    px py "#3366ff"))
           (bbox-rect (region-bbox (getf pr :|x|) (getf pr :|y|)
                                    px py "#ff3300")))
      (assert-true bbox-text "text-range blue bbox found")
      (assert-true bbox-rect "PDF-rect red bbox found"))))

(deftest v033b-q9-text-range-coords-match-codepoint-rects-wire
  "對同一 buf + 同一 range，buffer/codepoint-rects 拿到的 rect 應對應
   view/overlays type:\"text-range\" 畫出的色塊位置（座標一致檢查）。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "ABCDEFGHIJ")
    (drain-events)
    (sync-faces! (list :|name| "v033b-tr3" :|background| "#ffcc00"))
    (let* ((queried (codepoint-rects buf 2 6))
           (_       (call-with-text-range-overlay buf 2 6 "v033b-tr3"))
           (pr      (page-pixel-rect))
           (bbox    (region-bbox (getf pr :|x|) (getf pr :|y|)
                                  (+ (getf pr :|x|) (getf pr :|w|))
                                  (+ (getf pr :|y|) (getf pr :|h|))
                                  "#ffcc00")))
      (declare (ignore _))
      (assert-true queried   "queried rects non-empty")
      (assert-true bbox      "painted bbox visible")
      ;; 座標一致性：painted bbox 應跟 queried rects 的 union 至少接近
      (when (and queried bbox)
        (let* ((qr (getf (first queried) :|rect|))
               (qx0 (first qr)) (qy0 (second qr))
               (bx  (getf bbox :|x|))
               (by  (getf bbox :|y|)))
          (assert-true (<= (abs (- qx0 bx)) 5)
                       (format nil "x0 一致 ±5 (~A vs ~A)" qx0 bx))
          (assert-true (<= (abs (- qy0 by)) 5)
                       (format nil "y0 一致 ±5 (~A vs ~A)" qy0 by)))))))

(deftest v033b-q10-text-range-priority-sort-paint
  "兩個 text-range 同範圍、不同 face、不同 priority：高 priority 蓋低。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "AAAAAAAAAAAAAA")
    (drain-events)
    (sync-faces! (list :|name| "v033b-lo" :|background| "#0000ff")
                 (list :|name| "v033b-hi" :|background| "#ff0000"))
    (assert-ok
     (send! "view/overlays" :|win-id| "w1"
            :|layers|
            (list (list :|type| "text-range" :|buf-id| buf
                        :|start| 0 :|end| 5
                        :|face| "v033b-lo" :|priority| 1 :|opacity| 1.0)
                  (list :|type| "text-range" :|buf-id| buf
                        :|start| 0 :|end| 5
                        :|face| "v033b-hi" :|priority| 10 :|opacity| 1.0))))
    (let* ((pr (page-pixel-rect))
           (bbox-red (region-bbox (getf pr :|x|) (getf pr :|y|)
                                   (+ (getf pr :|x|) (getf pr :|w|))
                                   (+ (getf pr :|y|) (getf pr :|h|))
                                   "#ff0000")))
      (assert-true bbox-red
                   "高 priority 紅色該蓋過低 priority 藍色"))))
