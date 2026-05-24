;;;; v0.33 — Qt-tier 視覺系統測試 (~15 tests)
;;;;
;;;; 對著真 limn binary 跑、走實際 view/overlays wire + display/sync-faces +
;;;; （C 節）真 text buffer + Lisp overlay/region 模組。三節：
;;;;
;;;;   A view/overlays :face paint (~6)
;;;;     verifies the C++ cmd_view_overlays change：layer 帶 :face 名稱、
;;;;     paint 時查 LimnFaceRegistry 拿到 foreground 顏色、pixel 結果對。
;;;;
;;;;   B Overlay render (~5)
;;;;     real text buffer + Lisp limn/overlays + wire payload → screenshot
;;;;     verify rect 出現、before-string 視覺插入、priority 覆蓋、:window
;;;;     filter 對。
;;;;
;;;;   C Region 視覺化 (~4)
;;;;     real text buffer + Lisp set-mark + move cursor → screenshot 出現
;;;;     region face；transient-mark off / on 切換、跨行 region。
;;;;
;;;; 全部 RED 直到 §A C++ patch + §B+C Lisp module 落地。

(in-package #:limn/test)

;; Qt-tier 框架預設只走 wire；§B/§C 整合點跨 wire+Lisp，所以把 backend
;; module 在 in-process 載進來 — 跟 marker-v030.lisp 同個 dogfood pattern。
(let* ((suite-dir (make-pathname :defaults (or *load-pathname*
                                                *default-pathname-defaults*)
                                  :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir)))
  (dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
               "limn-marker.lisp" "limn-local.lisp" "limn-mark.lisp"
               "limn-face.lisp"
               ;; v0.33 新模組（落地後）
               "limn-overlays.lisp"
               "limn-region.lisp"))
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

(when (find-package '#:limn/marker)
  (let ((f (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER" '#:limn/marker)))
    (when f (funcall f))))

;;; ── helpers ───────────────────────────────────────────────────────────────

(defun sample-pixel (x y)
  "Returns {:r :g :b :a} at widget pixel coordinate (X, Y)."
  (json-get* (send! "test/sample-pixel" :|x| x :|y| y) :|data|))

(defun page-pixel-rect (&key (win-id "w1") (page 0))
  (json-get* (send! "test/page-pixel-rect" :|win-id| win-id :|page| page)
             :|data|))

(defun region-bbox (x0 y0 x1 y1 match-color)
  (json-get* (send! "test/region-bbox"
                    :|x0| x0 :|y0| y0 :|x1| x1 :|y1| y1
                    :|match-color| match-color)
             :|data|))

(defun pixel-equals (px r g b &optional (tol 10))
  (and px
       (<= (abs (- (getf px :|r|) r)) tol)
       (<= (abs (- (getf px :|g|) g)) tol)
       (<= (abs (- (getf px :|b|) b)) tol)))

(defun page-center (&key (win-id "w1") (page 0))
  (let ((pr (page-pixel-rect :win-id win-id :page page)))
    (when pr
      (values (+ (getf pr :|x|) (round (/ (getf pr :|w|) 2)))
              (+ (getf pr :|y|) (round (/ (getf pr :|h|) 2)))))))

(defun sync-faces! (&rest face-plists)
  (send! "display/sync-faces" :|faces| face-plists))

(defun set-face-rect (win-id page face-name &key (x0 0.1) (y0 0.1)
                                                  (x1 0.9) (y1 0.9)
                                                  (opacity 1.0)
                                                  (color nil))
  "Send one rect overlay using :face FACE-NAME (optionally also :color)."
  (let ((layer (list :|type| "rect" :|page| page
                     :|face| face-name
                     :|x0| x0 :|y0| y0 :|x1| x1 :|y1| y1
                     :|opacity| opacity)))
    (when color (setf (getf layer :|color|) color))
    (send! "view/overlays" :|win-id| win-id :|layers| (list layer))))

(defun clear-overlays (&optional (win-id "w1"))
  (send! "view/overlays" :|win-id| win-id :|layers| nil))

;;; ════════════════════════════════════════════════════════════════════════
;;; §A view/overlays :face paint (6 tests)
;;; ════════════════════════════════════════════════════════════════════════

(deftest v033-a1-face-foreground-paints
  "defface 推 face-A foreground #FF0000、view/overlays :face face-A
   → page 中心 pixel = 紅。"
  (with-buffer (buf)
    (declare (ignore buf))
    (sync-faces! (list :|name| "v033-face-a1" :|foreground| "#ff0000"))
    (assert-ok (set-face-rect "w1" 0 "v033-face-a1"))
    (multiple-value-bind (cx cy) (page-center)
      (assert-true cx "page-pixel-rect 有數據")
      (let ((px (sample-pixel cx cy)))
        (assert-true (pixel-equals px 255 0 0)
                     (format nil "expected red, got ~s" px))))))

(deftest v033-a1-face-beats-color
  "同 layer 帶 :color #0000FF 跟 :face face-red → face 勝、pixel = 紅。"
  (with-buffer (buf)
    (declare (ignore buf))
    (sync-faces! (list :|name| "v033-face-a1b" :|foreground| "#ff0000"))
    (assert-ok (set-face-rect "w1" 0 "v033-face-a1b" :color "#0000ff"))
    (multiple-value-bind (cx cy) (page-center)
      (let ((px (sample-pixel cx cy)))
        (assert-true (pixel-equals px 255 0 0)
                     (format nil ":face wins over :color; got ~s" px))))))

(deftest v033-a1-unknown-face-fallback
  "送一個未在 registry 的 face name → C++ 不崩，layer 用 fallback
   或被略過 — 但 view/overlays 回 :ok t。"
  (with-buffer (buf)
    (declare (ignore buf))
    (let ((r (set-face-rect "w1" 0 "v033-face-no-such-face")))
      (assert-ok r))))

(deftest v033-a1-face-update-relects-immediately
  "set-face-attribute 改了 foreground 再重送 view/overlays → 用新顏色。"
  (with-buffer (buf)
    (declare (ignore buf))
    (sync-faces! (list :|name| "v033-face-a1d" :|foreground| "#0000ff"))
    (set-face-rect "w1" 0 "v033-face-a1d")
    (multiple-value-bind (cx cy) (page-center)
      (let ((before (sample-pixel cx cy)))
        (assert-true (pixel-equals before 0 0 255)
                     (format nil "initial blue, got ~s" before)))
      ;; 改 face → 重新 sync + 重送
      (sync-faces! (list :|name| "v033-face-a1d" :|foreground| "#00ff00"))
      (set-face-rect "w1" 0 "v033-face-a1d")
      (let ((after (sample-pixel cx cy)))
        (assert-true (pixel-equals after 0 255 0)
                     (format nil "after update green, got ~s" after))))))

(deftest v033-a1-multi-layers-multi-faces
  "兩個 layer 各自 :face → page 不同象限 pixel 顏色對應正確。"
  (with-buffer (buf)
    (declare (ignore buf))
    (sync-faces!
     (list :|name| "v033-face-tl" :|foreground| "#ff0000")
     (list :|name| "v033-face-br" :|foreground| "#00ff00"))
    (assert-ok
     (send! "view/overlays" :|win-id| "w1"
            :|layers|
            (list (list :|type| "rect" :|page| 0 :|face| "v033-face-tl"
                        :|x0| 0.05 :|y0| 0.05 :|x1| 0.45 :|y1| 0.45
                        :|opacity| 1.0)
                  (list :|type| "rect" :|page| 0 :|face| "v033-face-br"
                        :|x0| 0.55 :|y0| 0.55 :|x1| 0.95 :|y1| 0.95
                        :|opacity| 1.0))))
    (let* ((pr (page-pixel-rect))
           (tl-x (+ (getf pr :|x|) (round (* 0.25 (getf pr :|w|)))))
           (tl-y (+ (getf pr :|y|) (round (* 0.25 (getf pr :|h|)))))
           (br-x (+ (getf pr :|x|) (round (* 0.75 (getf pr :|w|)))))
           (br-y (+ (getf pr :|y|) (round (* 0.75 (getf pr :|h|))))))
      (assert-true (pixel-equals (sample-pixel tl-x tl-y) 255 0 0)
                   "TL = 紅")
      (assert-true (pixel-equals (sample-pixel br-x br-y) 0 255 0)
                   "BR = 綠"))))

(deftest v033-a1-enabled-theme-routes-to-overlay
  "deftheme + enable-theme 覆蓋 face foreground → 之後送 :face overlay
   用 theme 顏色。"
  (with-buffer (buf)
    (declare (ignore buf))
    ;; 基線 #FF0000
    (sync-faces! (list :|name| "v033-face-themed" :|foreground| "#ff0000"))
    (set-face-rect "w1" 0 "v033-face-themed")
    (multiple-value-bind (cx cy) (page-center)
      (let ((base (sample-pixel cx cy)))
        (assert-true (pixel-equals base 255 0 0) "baseline red"))
      ;; 模擬 theme switch（直接 push 新值給 wire）
      (sync-faces! (list :|name| "v033-face-themed" :|foreground| "#888800"))
      (set-face-rect "w1" 0 "v033-face-themed")
      (let ((dark (sample-pixel cx cy)))
        (assert-true (pixel-equals dark #x88 #x88 #x00 15)
                     (format nil "after theme, expected olive, got ~s" dark))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; §B Overlay 渲染 (5 tests)
;;;
;;; 用真 text-engine buffer + Lisp limn/overlays 模組 → 推 wire payload
;;; → screenshot 反映。
;;; ════════════════════════════════════════════════════════════════════════

(defmacro with-text-buffer ((buf) &body body)
  "Open a fresh text buffer for v0.33 §B/§C tests."
  `(let* ((r0 (send! "bridge/engine-load"
                     :|win-id| "w1" :|engine| "text" :|path| ""))
          (,buf (json-get* r0 :|data| :|buffer-id|)))
     (drain-events)
     ;; reset overlay / mark / region state if modules loaded
     (when (find-package '#:limn/overlays)
       (let ((f (find-symbol "RESET-OVERLAYS" '#:limn/overlays)))
         (when f (funcall f ,buf))))
     (when (find-package '#:limn/mark)
       (let ((f (find-symbol "RESET-MARKS" '#:limn/mark)))
         (when f (funcall f ,buf))))
     (unwind-protect (progn ,@body)
       (when ,buf
         (ignore-errors (send! "buffer/close" :|buffer-id| ,buf))))))

(deftest v033-b1-overlay-paints-text-range
  "在 text buffer 建 overlay [5,10) 帶 face = 'isearch-match → screenshot
   出現黃色（或 isearch-match face 預設色）的色塊。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world example text")
    (drain-events)
    ;; Sync isearch-match face → 黃
    (sync-faces! (list :|name| "isearch-match" :|foreground| "#ffd700"))
    ;; Lisp 建 overlay 並用 overlays-to-wire-layers 推給 wire
    (let* ((pkg-ov (find-package '#:limn/overlays))
           (mk-ov  (find-symbol "MAKE-OVERLAY"   pkg-ov))
           (put    (find-symbol "OVERLAY-PUT"    pkg-ov))
           (to-wl  (find-symbol "OVERLAYS-TO-WIRE-LAYERS" pkg-ov))
           (ov     (funcall mk-ov 5 10 buf)))
      (funcall put ov 'face 'isearch-match)
      (let ((layers (funcall to-wl 0 100 buf)))
        (assert-ok (send! "view/overlays" :|win-id| "w1" :|layers| layers))))
    ;; 確認 page 內 有黃色 pixel 區塊出現
    (let* ((pr (page-pixel-rect))
           (bbox (region-bbox (getf pr :|x|)
                              (getf pr :|y|)
                              (+ (getf pr :|x|) (getf pr :|w|))
                              (+ (getf pr :|y|) (getf pr :|h|))
                              "#ffd700")))
      (assert-true bbox "expected to find a yellow region somewhere on page"))))

(deftest v033-b1-before-string-not-in-buffer-text
  "overlay 帶 before-string \"▶ \" → buffer/text wire 回傳不含此字串。
   （資料 / 顯示分離）"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world")
    (drain-events)
    (let* ((pkg-ov (find-package '#:limn/overlays))
           (mk-ov  (find-symbol "MAKE-OVERLAY" pkg-ov))
           (put    (find-symbol "OVERLAY-PUT" pkg-ov))
           (ov     (funcall mk-ov 6 6 buf)))
      (funcall put ov 'before-string "▶ "))
    (let* ((r (send! "buffer/text" :|buffer-id| buf))
           (txt (json-get* r :|data| :|text|)))
      (assert-equal "hello world" txt
                    "buffer text 不含 before-string 字串"))))

(deftest v033-b1-priority-paints-on-top
  "兩個 overlay 同範圍、不同 priority + face：高 priority 蓋過低 priority。
   layer 順序 = 低 priority 先（底）、高 priority 後（上）。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "AAAAAAAAAAA")
    (drain-events)
    (sync-faces! (list :|name| "v033-lo" :|foreground| "#0000ff")  ; blue
                 (list :|name| "v033-hi" :|foreground| "#ff0000")) ; red
    (let* ((pkg-ov (find-package '#:limn/overlays))
           (mk     (find-symbol "MAKE-OVERLAY" pkg-ov))
           (put    (find-symbol "OVERLAY-PUT" pkg-ov))
           (to-wl  (find-symbol "OVERLAYS-TO-WIRE-LAYERS" pkg-ov))
           (lo     (funcall mk 0 5 buf))
           (hi     (funcall mk 0 5 buf)))
      (funcall put lo 'face 'v033-lo) (funcall put lo 'priority 1)
      (funcall put hi 'face 'v033-hi) (funcall put hi 'priority 10)
      (let ((layers (funcall to-wl 0 5 buf)))
        (assert-equal 2 (length layers))
        ;; first = 低 priority = blue (bottom)；second = 高 = red (top)
        (assert-equal "v033-lo" (getf (first  layers) :|face|))
        (assert-equal "v033-hi" (getf (second layers) :|face|))
        (assert-ok (send! "view/overlays" :|win-id| "w1" :|layers| layers))))
    ;; Final pixel：紅（高 priority 在上）
    (let* ((pr (page-pixel-rect))
           (cx (+ (getf pr :|x|) 30))
           (cy (+ (getf pr :|y|) 30))
           (px (sample-pixel cx cy)))
      (assert-true (or (pixel-equals px 255 0 0)
                       ;; 若 anti-alias 邊緣可能稍偏，放寬到只要不是 blue
                       (and (> (getf px :|r|) (getf px :|b|))))
                   (format nil "expected red on top, got ~s" px)))))

(deftest v033-b1-window-property-filters
  "overlay 帶 'window \"w2\" + split → 只在 w2 出現、w1 不出現。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "AAAA")
    (drain-events)
    (send! "bridge/win-split" :|win-id| "w1" :|dir| "h")
    (sync-faces! (list :|name| "v033-w2-only" :|foreground| "#ff00ff"))
    (let* ((pkg-ov (find-package '#:limn/overlays))
           (mk     (find-symbol "MAKE-OVERLAY" pkg-ov))
           (put    (find-symbol "OVERLAY-PUT" pkg-ov))
           (to-wl  (find-symbol "OVERLAYS-TO-WIRE-LAYERS" pkg-ov))
           (ov     (funcall mk 0 4 buf)))
      (funcall put ov 'face 'v033-w2-only)
      (funcall put ov 'window "w2")
      ;; layer-list filtered by window
      (let ((l-w1 (funcall to-wl 0 4 buf :window "w1"))
            (l-w2 (funcall to-wl 0 4 buf :window "w2")))
        (assert-equal 0 (length l-w1) "w1 → 0 layer")
        (assert-equal 1 (length l-w2) "w2 → 1 layer")))))

(deftest v033-b1-multi-line-overlay
  "overlay 跨行（包含 \\n） → screenshot 中應該看到多行同色 highlight bbox。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "line1
line2
line3")
    (drain-events)
    (sync-faces! (list :|name| "v033-multi" :|foreground| "#00ffff"))
    (let* ((pkg-ov (find-package '#:limn/overlays))
           (mk     (find-symbol "MAKE-OVERLAY" pkg-ov))
           (put    (find-symbol "OVERLAY-PUT" pkg-ov))
           (to-wl  (find-symbol "OVERLAYS-TO-WIRE-LAYERS" pkg-ov))
           ;; "line1\nline2\n" len = 12, 包含中間整列
           (ov     (funcall mk 0 17 buf)))
      (funcall put ov 'face 'v033-multi)
      (let ((layers (funcall to-wl 0 17 buf)))
        (assert-ok (send! "view/overlays" :|win-id| "w1" :|layers| layers))))
    (let* ((pr (page-pixel-rect))
           (bbox (region-bbox (getf pr :|x|) (getf pr :|y|)
                              (+ (getf pr :|x|) (getf pr :|w|))
                              (+ (getf pr :|y|) (getf pr :|h|))
                              "#00ffff")))
      (assert-true bbox "multi-line cyan region found"))))

;;; ════════════════════════════════════════════════════════════════════════
;;; §C Region 視覺化 (4 tests)
;;; ════════════════════════════════════════════════════════════════════════

(deftest v033-c1-region-face-paints
  "(set-mark 3) 然後 cursor 移到 8、update-region-overlay → screenshot
   有 region face 反白範圍。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world!!!!!")
    (drain-events)
    (sync-faces! (list :|name| "region" :|background| "#3366ff"
                                        :|foreground| "#ffffff"))
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 8)
    (let* ((pkg-mk (find-package '#:limn/mark))
           (set-mk (find-symbol "SET-MARK" pkg-mk))
           (pkg-rg (find-package '#:limn/region))
           (update (find-symbol "UPDATE-REGION-OVERLAY" pkg-rg)))
      (setf (symbol-value (find-symbol "*TRANSIENT-MARK-MODE*" pkg-mk)) t)
      (funcall set-mk 3 buf)
      (funcall update buf))
    ;; 推 region overlay 到 wire（透過 overlays-to-wire-layers）
    (let* ((pkg-ov (find-package '#:limn/overlays))
           (to-wl  (find-symbol "OVERLAYS-TO-WIRE-LAYERS" pkg-ov))
           (layers (funcall to-wl 0 100 buf)))
      (assert-true (>= (length layers) 1) "至少一個 region layer")
      (assert-ok (send! "view/overlays" :|win-id| "w1" :|layers| layers)))
    (let* ((pr (page-pixel-rect))
           (bbox (region-bbox (getf pr :|x|) (getf pr :|y|)
                              (+ (getf pr :|x|) (getf pr :|w|))
                              (+ (getf pr :|y|) (getf pr :|h|))
                              "#3366ff")))
      (assert-true bbox "region face blue background visible"))))

(deftest v033-c1-transient-mark-off-no-region
  "transient-mark-mode off → set-mark + update 後 region-overlay-for 回 nil、
   wire layers 空、screenshot 看不到 region 色塊。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world!!!!!")
    (drain-events)
    (sync-faces! (list :|name| "region" :|background| "#3366ff"))
    (let* ((pkg-mk (find-package '#:limn/mark))
           (set-mk (find-symbol "SET-MARK" pkg-mk))
           (pkg-rg (find-package '#:limn/region))
           (update (find-symbol "UPDATE-REGION-OVERLAY" pkg-rg))
           (region-for (find-symbol "REGION-OVERLAY-FOR" pkg-rg)))
      (setf (symbol-value (find-symbol "*TRANSIENT-MARK-MODE*" pkg-mk)) nil)
      (funcall set-mk 3 buf)
      (funcall update buf)
      (assert-false (funcall region-for buf)
                    "transient off → no overlay"))))

(deftest v033-c1-region-clears-on-edit
  "active region 後送 edit command (self-insert) → mark deactivate、
   再 update → region-overlay-for 回 nil → wire 沒 region layer。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world!!!!!")
    (drain-events)
    (sync-faces! (list :|name| "region" :|background| "#3366ff"))
    (let* ((pkg-mk     (find-package '#:limn/mark))
           (set-mk     (find-symbol "SET-MARK" pkg-mk))
           (note       (find-symbol "NOTE-COMMAND" pkg-mk))
           (active-p   (find-symbol "MARK-ACTIVE-P" pkg-mk))
           (pkg-rg     (find-package '#:limn/region))
           (update     (find-symbol "UPDATE-REGION-OVERLAY" pkg-rg))
           (region-for (find-symbol "REGION-OVERLAY-FOR" pkg-rg)))
      (setf (symbol-value (find-symbol "*TRANSIENT-MARK-MODE*" pkg-mk)) t)
      (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 7)
      (funcall set-mk 3 buf)
      (funcall update buf)
      (assert-true (funcall active-p buf) "active after set-mark")
      ;; Edit command
      (funcall note 'self-insert-command buf)
      (funcall update buf)
      (assert-false (funcall active-p buf) "edit → deactivate")
      (assert-false (funcall region-for buf) "no overlay after edit"))))

(deftest v033-c1-region-multi-line
  "mark 在 line 1、point 在 line 3 → region overlay 涵蓋三行、screenshot
   找得到貫穿三行的高亮像素。"
  (with-text-buffer (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "alpha
beta
gamma
delta")
    (drain-events)
    (sync-faces! (list :|name| "region" :|background| "#ff00aa"))
    (let* ((pkg-mk (find-package '#:limn/mark))
           (set-mk (find-symbol "SET-MARK" pkg-mk))
           (pkg-rg (find-package '#:limn/region))
           (update (find-symbol "UPDATE-REGION-OVERLAY" pkg-rg))
           (pkg-ov (find-package '#:limn/overlays))
           (to-wl  (find-symbol "OVERLAYS-TO-WIRE-LAYERS" pkg-ov)))
      (setf (symbol-value (find-symbol "*TRANSIENT-MARK-MODE*" pkg-mk)) t)
      ;; "alpha\nbeta\ngamma\ndelta" — mark 在 0、point 在 16（第三行末）
      (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 16)
      (funcall set-mk 0 buf)
      (funcall update buf)
      (let ((layers (funcall to-wl 0 100 buf)))
        (assert-ok (send! "view/overlays" :|win-id| "w1" :|layers| layers))))
    (let* ((pr (page-pixel-rect))
           (bbox (region-bbox (getf pr :|x|) (getf pr :|y|)
                              (+ (getf pr :|x|) (getf pr :|w|))
                              (+ (getf pr :|y|) (getf pr :|h|))
                              "#ff00aa")))
      (assert-true bbox "multi-line region pink visible")
      ;; 高度應 ≥ ~2 行（粗略：>= 20 像素）
      (when bbox
        (assert-true (>= (getf bbox :|h|) 20)
                     (format nil "multi-line height >= 20, got ~A" (getf bbox :|h|)))))))
