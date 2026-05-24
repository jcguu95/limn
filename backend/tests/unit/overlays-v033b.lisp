;;;; v0.33b — text-buffer overlay wire path + codepoint-rects client
;;;; RED tests (~12 個)
;;;;
;;;; v0.33a 把 overlay 資料層 + region state 做完了，但「文字 buffer 上的
;;;; overlay 怎麼送到 C++ 渲染」這條路徑還沒打通：
;;;;
;;;;   §D buffer-kind dispatch (C1-C4)
;;;;     新 vtable *buffer-kind-fn* — 給 buf-id 回 :text / :pdf / nil。
;;;;     overlay-as-wire-layer 依 buffer-kind 自動選 wire :type：
;;;;       :text → "text-range"（C++ 端動態 layout）
;;;;       :pdf  → "rect"（既有路徑，需要 caller 補 page/rect）
;;;;       nil   → "overlay"（fallback，保留 v0.33a 行為）
;;;;
;;;;   §E text-range layer payload shape (C5-C8)
;;;;     新 type "text-range" 必須帶 :buf-id :start :end；其他屬性透傳。
;;;;
;;;;   §F buffer/codepoint-rects client helper (C9-C12)
;;;;     limn/overlays:make-codepoint-rects-request 回構造好的 wire plist；
;;;;     limn/overlays:parse-codepoint-rects-response 把回應拆成 list-of-plist。
;;;;
;;;; 全部 RED — 上述 vtable / dispatch / helper 都還沒實作。

;; ── package stubs — 確保 in-package 之前 symbol 已 export ────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/overlays)
    (make-package '#:limn/overlays :use '(#:cl)))
  (dolist (sym '(;; v0.33a 已有，這裡僅引用
                 "MAKE-OVERLAY" "OVERLAY-PUT" "OVERLAY-AS-WIRE-LAYER"
                 "OVERLAYS-TO-WIRE-LAYERS"
                 ;; v0.33b 新增
                 "*BUFFER-KIND-FN*"
                 "MAKE-CODEPOINT-RECTS-REQUEST"
                 "PARSE-CODEPOINT-RECTS-RESPONSE"))
    (export (intern sym '#:limn/overlays) '#:limn/overlays)))

(in-package #:limn/unit-test)

;;; ── 共用 mock buffer (重用 v0.33a 的 with-overlay-buf) ───────────────────

;; with-overlay-buf 已在 overlays-v033.lisp 定義；本檔案會被 run-unit.lisp
;; 在 overlays-v033.lisp 之後載入，符號已可見。

;;; ════════════════════════════════════════════════════════════════════════
;;; §D buffer-kind dispatch (C1-C4)
;;;
;;; vtable *buffer-kind-fn* 給 buf-id 回 :text / :pdf / nil
;;; ════════════════════════════════════════════════════════════════════════

(deftest overlays-v033b-c1-text-buffer-emits-text-range
  "Buffer kind = :text → overlay-as-wire-layer 吐 :type \"text-range\"。"
  (with-overlay-buf (b :id "bk1" :text "hello world")
    (let ((kind-fn (lambda (bid) (when (equal bid "bk1") :text))))
      (progv (list (find-symbol "*BUFFER-KIND-FN*" '#:limn/overlays))
             (list kind-fn)
        (let* ((ov    (limn/overlays:make-overlay 0 5 "bk1"))
               (layer (limn/overlays:overlay-as-wire-layer ov)))
          (assert-equal "text-range" (getf layer :|type|)
                        "text buffer → type:\"text-range\"")
          (assert-equal "bk1"  (getf layer :|buf-id|) "buf-id 透傳")
          (assert-equal 0      (getf layer :|start|)  "start 透傳")
          (assert-equal 5      (getf layer :|end|)    "end 透傳"))))))

(deftest overlays-v033b-c2-pdf-buffer-emits-rect
  "Buffer kind = :pdf → overlay-as-wire-layer 不動 v0.33a 行為（type \"rect\"
   或 \"overlay\"，依 overlay 是否帶 'type 屬性而定）。"
  (with-overlay-buf (b :id "bk2" :text "")
    (let ((kind-fn (lambda (bid) (when (equal bid "bk2") :pdf))))
      (progv (list (find-symbol "*BUFFER-KIND-FN*" '#:limn/overlays))
             (list kind-fn)
        (let ((ov (limn/overlays:make-overlay 0 0 "bk2")))
          ;; PDF overlay：caller 必須給 type rect + page + rect
          (limn/overlays:overlay-put ov 'type "rect")
          (limn/overlays:overlay-put ov 'page 0)
          (limn/overlays:overlay-put ov 'rect '(0.1 0.1 0.5 0.5))
          (let ((layer (limn/overlays:overlay-as-wire-layer ov)))
            (assert-equal "rect" (getf layer :|type|)
                          "PDF buffer + explicit type rect → \"rect\"")))))))

(deftest overlays-v033b-c3-unknown-kind-fallback
  "Buffer kind = nil → 回 v0.33a 預設 \"overlay\" type（向後相容）。"
  (with-overlay-buf (b :id "bk3" :text "hello")
    (let ((kind-fn (lambda (bid) (declare (ignore bid)) nil)))
      (progv (list (find-symbol "*BUFFER-KIND-FN*" '#:limn/overlays))
             (list kind-fn)
        (let* ((ov    (limn/overlays:make-overlay 0 3 "bk3"))
               (layer (limn/overlays:overlay-as-wire-layer ov)))
          (assert-equal "overlay" (getf layer :|type|)
                        "unknown kind → fallback \"overlay\""))))))

(deftest overlays-v033b-c4-explicit-type-overrides-kind
  "Overlay 帶 'type property → 即使 buffer kind = :text 也照 caller 給的。"
  (with-overlay-buf (b :id "bk4" :text "hello")
    (let ((kind-fn (lambda (bid) (when (equal bid "bk4") :text))))
      (progv (list (find-symbol "*BUFFER-KIND-FN*" '#:limn/overlays))
             (list kind-fn)
        (let ((ov (limn/overlays:make-overlay 0 5 "bk4")))
          (limn/overlays:overlay-put ov 'type "rect")
          (limn/overlays:overlay-put ov 'page 0)
          (limn/overlays:overlay-put ov 'rect '(0.0 0.0 1.0 1.0))
          (let ((layer (limn/overlays:overlay-as-wire-layer ov)))
            (assert-equal "rect" (getf layer :|type|)
                          "explicit 'type 屬性壓過 buffer-kind dispatch")))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; §E text-range layer payload shape (C5-C8)
;;; ════════════════════════════════════════════════════════════════════════

(deftest overlays-v033b-c5-text-range-required-fields
  "text-range layer 必含 :type :buf-id :start :end 四欄。"
  (with-overlay-buf (b :id "bk5" :text "hello world")
    (let ((kind-fn (lambda (bid) (when (equal bid "bk5") :text))))
      (progv (list (find-symbol "*BUFFER-KIND-FN*" '#:limn/overlays))
             (list kind-fn)
        (let* ((ov    (limn/overlays:make-overlay 2 7 "bk5"))
               (layer (limn/overlays:overlay-as-wire-layer ov)))
          (assert-equal "text-range" (getf layer :|type|))
          (assert-equal "bk5"        (getf layer :|buf-id|))
          (assert-equal 2            (getf layer :|start|))
          (assert-equal 7            (getf layer :|end|)))))))

(deftest overlays-v033b-c6-text-range-properties-passthrough
  "text-range 也應透傳 :face :color :opacity :priority :win-id :before-string。"
  (with-overlay-buf (b :id "bk6" :text "hello world")
    (let ((kind-fn (lambda (bid) (when (equal bid "bk6") :text))))
      (progv (list (find-symbol "*BUFFER-KIND-FN*" '#:limn/overlays))
             (list kind-fn)
        (let ((ov (limn/overlays:make-overlay 0 5 "bk6")))
          (limn/overlays:overlay-put ov 'face          'region)
          (limn/overlays:overlay-put ov 'color         "#3366ff")
          (limn/overlays:overlay-put ov 'opacity       0.4)
          (limn/overlays:overlay-put ov 'priority      -10)
          (limn/overlays:overlay-put ov 'window        "w1")
          (limn/overlays:overlay-put ov 'before-string "▶ ")
          (let ((layer (limn/overlays:overlay-as-wire-layer ov)))
            (assert-equal "region"  (getf layer :|face|))
            (assert-equal "#3366ff" (getf layer :|color|))
            (assert-equal 0.4       (getf layer :|opacity|))
            (assert-equal -10       (getf layer :|priority|))
            (assert-equal "w1"      (getf layer :|win-id|))
            (assert-equal "▶ "      (getf layer :|before-string|))))))))

(deftest overlays-v033b-c7-text-range-priority-sort-preserved
  "overlays-to-wire-layers 在 text buffer 上仍按 priority 由低到高（底→上）
   排序 — text-range layer 跟 rect layer 享同樣行為。"
  (with-overlay-buf (b :id "bk7" :text "AAAAAAAAAA")
    (let ((kind-fn (lambda (bid) (when (equal bid "bk7") :text))))
      (progv (list (find-symbol "*BUFFER-KIND-FN*" '#:limn/overlays))
             (list kind-fn)
        (let ((lo (limn/overlays:make-overlay 0 5 "bk7"))
              (hi (limn/overlays:make-overlay 0 5 "bk7")))
          (limn/overlays:overlay-put lo 'face 'lo-face)
          (limn/overlays:overlay-put lo 'priority 1)
          (limn/overlays:overlay-put hi 'face 'hi-face)
          (limn/overlays:overlay-put hi 'priority 10)
          (let ((layers (limn/overlays:overlays-to-wire-layers 0 5 "bk7")))
            (assert-equal 2 (length layers) "兩個 layer")
            (assert-equal "text-range" (getf (first layers)  :|type|))
            (assert-equal "text-range" (getf (second layers) :|type|))
            (assert-equal "lo-face" (getf (first layers)  :|face|)
                          "低 priority 先（底層）")
            (assert-equal "hi-face" (getf (second layers) :|face|)
                          "高 priority 後（上層）")))))))

(deftest overlays-v033b-c8-text-range-empty-range
  "start == end overlay 在 text buffer 上仍會送一條 zero-width layer，
   讓 C++ 可以用來做 'caret marker / point-overlay (before-string 用)。"
  (with-overlay-buf (b :id "bk8" :text "hello")
    (let ((kind-fn (lambda (bid) (when (equal bid "bk8") :text))))
      (progv (list (find-symbol "*BUFFER-KIND-FN*" '#:limn/overlays))
             (list kind-fn)
        (let ((ov (limn/overlays:make-overlay 3 3 "bk8")))
          (limn/overlays:overlay-put ov 'before-string "★")
          (let ((layer (limn/overlays:overlay-as-wire-layer ov)))
            (assert-equal "text-range" (getf layer :|type|))
            (assert-equal 3 (getf layer :|start|))
            (assert-equal 3 (getf layer :|end|))
            (assert-equal "★" (getf layer :|before-string|)
                          "zero-width overlay 仍保 before-string")))))))

;;; ════════════════════════════════════════════════════════════════════════
;;; §F buffer/codepoint-rects client helper (C9-C12)
;;;
;;; Pure-Lisp request builder + response parser — Wire 實際送 / 收的
;;; socket 動作 live in limn:call, 不在 unit tier 測試範圍。
;;; ════════════════════════════════════════════════════════════════════════

(deftest overlays-v033b-c9-rects-request-builder
  "make-codepoint-rects-request (buf-id win-id start end) → wire plist
   含 :cmd \"buffer/codepoint-rects\" + 四個必填欄。"
  (let ((req (limn/overlays:make-codepoint-rects-request
              "buf1" "w1" 10 25)))
    (assert-equal "buffer/codepoint-rects" (getf req :|cmd|))
    (assert-equal "buf1" (getf req :|buf-id|))
    (assert-equal "w1"   (getf req :|win-id|))
    (assert-equal 10     (getf req :|start|))
    (assert-equal 25     (getf req :|end|))))

(deftest overlays-v033b-c10-rects-response-parser-list-of-plist
  "parse-codepoint-rects-response 拿 {:ok t :data {:rects [...]}} →
   回 list-of-plist，每個 plist 帶 :page :rect。"
  (let* ((resp '(:|ok| t
                 :|data| (:|rects|
                          ((:|page| 0 :|rect| (10 20 30 40))
                           (:|page| 0 :|rect| (10 50 100 70))))))
         (rects (limn/overlays:parse-codepoint-rects-response resp)))
    (assert-equal 2 (length rects))
    (assert-equal 0 (getf (first  rects) :|page|))
    (assert-equal '(10 20 30 40) (getf (first  rects) :|rect|))
    (assert-equal '(10 50 100 70) (getf (second rects) :|rect|))))

(deftest overlays-v033b-c11-rects-response-error-bubbles
  "Response :ok = nil → parse-codepoint-rects-response 回 nil
   （或 raise）— 不可悄悄回 empty list 混淆與「真的沒 rect」場景。"
  (let ((resp '(:|ok| nil :|error| "buf not found")))
    (assert-false (limn/overlays:parse-codepoint-rects-response resp)
                  ":ok false → 不是 empty list，是 nil / error")))

(deftest overlays-v033b-c12-rects-response-empty-rects
  "Response :ok t + data :rects empty → 回 empty list（合法、不是 error）。"
  (let* ((resp '(:|ok| t :|data| (:|rects| ())))
         (rects (limn/overlays:parse-codepoint-rects-response resp)))
    (assert-equal '() rects ":ok true + 空 rects → '() not nil")))
