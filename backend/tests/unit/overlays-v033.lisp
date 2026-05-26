;;;; v0.33 — overlay data layer + view/overlays :face + region 視覺化
;;;; RED tests (~80 個)
;;;;
;;;; 覆蓋：
;;;;
;;;;   §A view/overlays :face wire payload helpers (~15)
;;;;     limn/overlays:layer-with-face / overlays-to-wire-layers
;;;;     verify wire payload shape — :face name 出現、與 :color 並存時行為對
;;;;     （C++ 端的 face registry lookup 屬 Qt-tier，這層只測 payload 構造）
;;;;
;;;;   §B overlay 資料層 (~45)
;;;;     limn/overlays:
;;;;       make-overlay / move-overlay / delete-overlay
;;;;       overlay-put / overlay-get / overlay-properties
;;;;       overlay-start / overlay-end / overlay-buffer
;;;;       overlays-in / overlays-at
;;;;       FRONT-ADVANCE / REAR-ADVANCE 透過 v0.30 marker insertion-type
;;;;     性質：start/end 是 marker (auto-fixup)、per-buffer sorted、O(log n) 查找
;;;;
;;;;   §C transient-mark-mode + region 視覺化 (~20)
;;;;     limn/mark:
;;;;       *transient-mark-mode* / *mark-active* / use-region-p
;;;;       *motion-commands* / *edit-commands*
;;;;       region-deactivate-on-edit / region-keep-active-on-motion hooks
;;;;     limn/region (新):
;;;;       *region-overlay* / update-region-overlay / clear-region-overlay
;;;;
;;;; 全部 RED — limn/overlays + transient-mark 擴充 未實作前都會 fail。

;; ── package stubs ──────────────────────────────────────────────────────────
;;
;; 三組 stub：limn/overlays（全新模組）、limn/region（全新模組）、
;; limn/mark 既有但要加 transient-mark 相關 symbol。

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; limn/overlays — 整個新模組
  (unless (find-package '#:limn/overlays)
    (make-package '#:limn/overlays :use '(#:cl)))
  (dolist (sym '(;; constructors / mutators
                 "MAKE-OVERLAY"
                 "DELETE-OVERLAY"
                 "MOVE-OVERLAY"
                 ;; property accessors
                 "OVERLAY-PUT"
                 "OVERLAY-GET"
                 "OVERLAY-PROPERTIES"
                 "OVERLAY-START"
                 "OVERLAY-END"
                 "OVERLAY-BUFFER"
                 ;; queries
                 "OVERLAYS-IN"
                 "OVERLAYS-AT"
                 ;; introspection / test helpers
                 "OVERLAY-P"
                 "RESET-OVERLAYS"
                 "OVERLAY-COUNT-FOR"
                 ;; wire-payload helpers (§A)
                 "OVERLAY-AS-WIRE-LAYER"
                 "OVERLAYS-TO-WIRE-LAYERS"
                 "LAYER-WITH-FACE"
                 ;; vtable
                 "*CURRENT-BUFFER-ID*"
                 "*BUFFER-TEXT-LEN-FN*"))
    (export (intern sym '#:limn/overlays) '#:limn/overlays))

  ;; limn/region — 新模組（region overlay state holder）
  (unless (find-package '#:limn/region)
    (make-package '#:limn/region :use '(#:cl)))
  (dolist (sym '("*REGION-OVERLAY*"
                 "UPDATE-REGION-OVERLAY"
                 "CLEAR-REGION-OVERLAY"
                 "REGION-OVERLAY-FOR"
                 ;; vtable
                 "*BUFFER-CURSOR-FN*"))
    (export (intern sym '#:limn/region) '#:limn/region))

  ;; limn/mark — 既有，補 transient-mark 相關 symbol
  (unless (find-package '#:limn/mark)
    (make-package '#:limn/mark :use '(#:cl)))
  (dolist (sym '("*TRANSIENT-MARK-MODE*"
                 "*MARK-ACTIVE*"
                 "USE-REGION-P"
                 "DEACTIVATE-MARK"
                 "ACTIVATE-MARK"
                 "*MOTION-COMMANDS*"
                 "*EDIT-COMMANDS*"
                 "NOTE-COMMAND"
                 "MARK-ACTIVE-P"))
    (export (intern sym '#:limn/mark) '#:limn/mark)))

(in-package #:limn/unit-test)

;;; ── 工具：mock buffer（沿用 v0.24 mock-buf24 模式） ───────────────────────
;;;
;;; Overlay 資料層需要兩件事：(a) 用 marker 做 start/end → 需 buffer-text-len
;;; vtable 給 limn/marker；(b) per-buffer 隔離 → 需 buf-id。我們直接重用
;;; v024-helpers 的 mock-buf24（已含 cursor 與 text）並掛 marker vtable。
;;;
;;; 為了讓 overlay 模組能呼叫 limn/marker 做 fixup 模擬，我們也得把 marker
;;; 的 buffer-text-len-fn / current-buffer-id 切到測試 buffer。

(defvar *ov-mock-buffers* (make-hash-table :test 'equal)
  "buf-id → mock-buf24 (for overlay tests).")

(defun %ov-vtable-text-len (bid)
  (let ((b (gethash bid *ov-mock-buffers*)))
    (if b (length (limn/v024-helpers:mbuf-text b)) 0)))

(defmacro with-overlay-buf ((var &key (id "ob") (text "") (cursor 0))
                            &body body)
  "Fresh mock buffer + register in *ov-mock-buffers* + install marker /
   overlay vtables targeting it. Reset overlay state before & after."
  (let ((pkg-mk (gensym "PKGMK"))
        (pkg-ov (gensym "PKGOV"))
        (pairs  (gensym "PAIRS"))
        (live   (gensym "LIVE")))
    `(let* ((,var   (limn/v024-helpers:make-mock-buf24
                     :id ,id :text ,text :cursor ,cursor))
            (,pkg-mk (find-package '#:limn/marker))
            (,pkg-ov (find-package '#:limn/overlays))
            (pkg-rg  (find-package '#:limn/region))
            (pkg-mk2 (find-package '#:limn/mark)))
       (setf (gethash ,id *ov-mock-buffers*) ,var)
       ;; reset overlay state for this buf-id (idempotent, ignored if module missing)
       (when ,pkg-ov
         (let ((reset (find-symbol "RESET-OVERLAYS" ,pkg-ov)))
           (when (and reset (fboundp reset)) (funcall reset ,id))))
       ;; reset marker state for this buf-id
       (when ,pkg-mk
         (let ((reset (find-symbol "RESET-MARKERS" ,pkg-mk)))
           (when (and reset (fboundp reset)) (funcall reset ,id))))
       (let* ((,pairs
                (remove
                 nil
                 (list
                  (when ,pkg-mk
                    (cons (find-symbol "*CURRENT-BUFFER-ID*"  ,pkg-mk) ,id))
                  (when ,pkg-mk
                    (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,pkg-mk)
                          #'%ov-vtable-text-len))
                  (when ,pkg-mk
                    (cons (find-symbol "*BUFFER-CURSOR-FN*"   ,pkg-mk)
                          (lambda (bid)
                            (let ((b (gethash bid *ov-mock-buffers*)))
                              (if b (limn/v024-helpers:mbuf-cursor b) 0)))))
                  (when ,pkg-ov
                    (cons (find-symbol "*CURRENT-BUFFER-ID*"  ,pkg-ov) ,id))
                  (when ,pkg-ov
                    (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,pkg-ov)
                          #'%ov-vtable-text-len))
                  ;; limn/region reads cursor through its own vtable so
                  ;; update-region-overlay can find point relative to mark.
                  (when pkg-rg
                    (cons (find-symbol "*BUFFER-CURSOR-FN*" pkg-rg)
                          (lambda (bid)
                            (let ((b (gethash bid *ov-mock-buffers*)))
                              (if b (limn/v024-helpers:mbuf-cursor b) 0)))))
                  ;; limn/mark's cursor-fn vtable (for set-mark/exchange).
                  (when pkg-mk2
                    (cons (find-symbol "*BUFFER-CURSOR-FN*" pkg-mk2)
                          (lambda (bid)
                            (let ((b (gethash bid *ov-mock-buffers*)))
                              (if b (limn/v024-helpers:mbuf-cursor b) 0)))))
                  (when pkg-mk2
                    (cons (find-symbol "*BUFFER-SET-CURSOR-FN*" pkg-mk2)
                          (lambda (bid off)
                            (let ((b (gethash bid *ov-mock-buffers*)))
                              (when b
                                (setf (limn/v024-helpers:mbuf-cursor b) off)))))))))
              (,live (remove nil ,pairs :key #'car)))
         (unwind-protect
              (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
                ,@body)
           (progn
             (when ,pkg-ov
               (let ((reset (find-symbol "RESET-OVERLAYS" ,pkg-ov)))
                 (when (and reset (fboundp reset)) (funcall reset ,id))))
             (when ,pkg-mk
               (let ((reset (find-symbol "RESET-MARKERS" ,pkg-mk)))
                 (when (and reset (fboundp reset)) (funcall reset ,id))))
             (remhash ,id *ov-mock-buffers*)))))))

(defun %ov-mb-insert! (buf pos str)
  "Mutate mock buffer + fire marker fixup so overlay start/end follow."
  (limn/v024-helpers:mbuf-insert-at! buf pos str)
  (when (find-package '#:limn/marker)
    (funcall (find-symbol "PROCESS-INSERT" '#:limn/marker)
             (limn/v024-helpers:mbuf-id buf) pos (length str))))

(defun %ov-mb-delete! (buf from to)
  "Mutate mock buffer + fire marker fixup."
  (limn/v024-helpers:mbuf-delete! buf from (- to from))
  (when (find-package '#:limn/marker)
    (funcall (find-symbol "PROCESS-DELETE" '#:limn/marker)
             (limn/v024-helpers:mbuf-id buf) from to)))

;;; ════════════════════════════════════════════════════════════════════════
;;; §A. view/overlays :face wire payload helpers (~15 tests)
;;;
;;; limn/overlays:layer-with-face 把 overlay 加 :face 屬性 → 序列化成 wire
;;; layer plist 時 :face 欄位帶 face name；既有 :color 不衝突；overlay 上
;;; 同時有 face property 跟 color property → wire 帶 :face、不刪 :color。
;;; ════════════════════════════════════════════════════════════════════════

(deftest overlays-a1-layer-with-face-includes-face-field
  "layer-with-face 接 rect plist + face name → 回傳 plist 多 :face 欄位。"
  (let ((layer (limn/overlays:layer-with-face
                '(:|type| "rect" :|page| 0 :|rect| (0.0 0.0 0.5 0.5)
                  :|color| "#FFD700" :|opacity| 0.5)
                "isearch-match")))
    (assert-equal "isearch-match" (getf layer :|face|)
                  ":face 欄位帶 face name")))

(deftest overlays-a1-layer-with-face-preserves-color
  "layer-with-face 不刪 :color（C++ 端負責 face 優先選色，color 是 fallback）。"
  (let ((layer (limn/overlays:layer-with-face
                '(:|type| "rect" :|page| 0 :|rect| (0.0 0.0 0.5 0.5)
                  :|color| "#FFD700" :|opacity| 0.5)
                "isearch-match")))
    (assert-equal "#FFD700" (getf layer :|color|)
                  ":color 保留作 fallback")))

(deftest overlays-a1-layer-with-face-accepts-symbol
  "face name 可以是 symbol（會被序列化成小寫 string）。"
  (let ((layer (limn/overlays:layer-with-face
                '(:|type| "rect" :|page| 0 :|rect| (0.0 0.0 0.5 0.5)
                  :|color| "#FFD700" :|opacity| 0.5)
                'isearch-match)))
    (assert-equal "isearch-match" (getf layer :|face|)
                  "symbol 'isearch-match → \"isearch-match\"")))

(deftest overlays-a1-layer-with-face-line-type
  "line 型 layer 也接 :face。"
  (let ((layer (limn/overlays:layer-with-face
                '(:|type| "line" :|page| 0 :|from| (0.0 0.0) :|to| (1.0 1.0)
                  :|color| "#000000" :|width| 2 :|opacity| 1.0)
                "lazy-highlight")))
    (assert-equal "line" (getf layer :|type|))
    (assert-equal "lazy-highlight" (getf layer :|face|))))

(deftest overlays-a1-layer-with-face-text-type
  "text 型 layer 也接 :face。"
  (let ((layer (limn/overlays:layer-with-face
                '(:|type| "text" :|page| 0 :|pos| (10.0 10.0)
                  :|text| "Hi" :|color| "#000000" :|size| 12.0 :|opacity| 1.0)
                "mode-line")))
    (assert-equal "text" (getf layer :|type|))
    (assert-equal "mode-line" (getf layer :|face|))))

(deftest overlays-a1-layer-with-face-no-color-ok
  "input plist 沒 :color、只給 :face → 接受、出 layer 無 :color 欄位。"
  (let ((layer (limn/overlays:layer-with-face
                '(:|type| "rect" :|page| 0 :|rect| (0.0 0.0 0.5 0.5)
                  :|opacity| 0.5)
                "isearch-match")))
    (assert-equal "isearch-match" (getf layer :|face|))
    (assert-false (getf layer :|color|)
                  "input 無 :color → 輸出也無")))

;;; — overlay-as-wire-layer：給 overlay 物件，輸出 wire layer plist

(deftest overlays-a2-overlay-as-wire-layer-uses-face-prop
  "overlay-put 'face 'X 後 overlay-as-wire-layer 把 X 放 :face 欄位。"
  (with-overlay-buf (b :id "wb1" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "wb1")))
      (limn/overlays:overlay-put ov 'face 'isearch-match)
      (let ((layer (limn/overlays:overlay-as-wire-layer ov)))
        (assert-equal "isearch-match" (getf layer :|face|))))))

(deftest overlays-a2-overlay-as-wire-layer-no-face-no-field
  "overlay 沒 face property → wire layer 無 :face 欄位。"
  (with-overlay-buf (b :id "wb2" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "wb2")))
      (let ((layer (limn/overlays:overlay-as-wire-layer ov)))
        (assert-false (getf layer :|face|)
                      "no face prop → no :face field")))))

(deftest overlays-a2-overlay-as-wire-layer-carries-window
  "overlay 有 'window property → wire layer :win-id 帶該 window。"
  (with-overlay-buf (b :id "wb3" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "wb3")))
      (limn/overlays:overlay-put ov 'face 'region)
      (limn/overlays:overlay-put ov 'window "w2")
      (let ((layer (limn/overlays:overlay-as-wire-layer ov)))
        (assert-equal "w2" (getf layer :|win-id|))))))

(deftest overlays-a2-overlay-as-wire-layer-priority-carried
  "priority property → wire layer :priority 數字傳對。"
  (with-overlay-buf (b :id "wb4" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "wb4")))
      (limn/overlays:overlay-put ov 'face 'region)
      (limn/overlays:overlay-put ov 'priority 100)
      (let ((layer (limn/overlays:overlay-as-wire-layer ov)))
        (assert-equal 100 (getf layer :|priority|))))))

;;; — overlays-to-wire-layers：給 (buf, range) 把 overlays-in 結果序列化

(deftest overlays-a3-overlays-to-wire-layers-emits-list
  "overlays-to-wire-layers 對一個 buf 內 [0,10) 的 overlays 全部序列化。"
  (with-overlay-buf (b :id "wb5" :text "hello world")
    (let ((o1 (limn/overlays:make-overlay 0 5 "wb5"))
          (o2 (limn/overlays:make-overlay 6 11 "wb5")))
      (limn/overlays:overlay-put o1 'face 'isearch-match)
      (limn/overlays:overlay-put o2 'face 'lazy-highlight))
    (let ((layers (limn/overlays:overlays-to-wire-layers 0 11 "wb5")))
      (assert-equal 2 (length layers) "2 個 overlay → 2 個 layer")
      (assert-true (find "isearch-match" layers :key (lambda (l) (getf l :|face|)) :test #'equal))
      (assert-true (find "lazy-highlight" layers :key (lambda (l) (getf l :|face|)) :test #'equal)))))

(deftest overlays-a3-overlays-to-wire-layers-empty-range
  "範圍內無 overlay → 回空 list。"
  (with-overlay-buf (b :id "wb6" :text "hello")
    (assert-equal '() (limn/overlays:overlays-to-wire-layers 0 5 "wb6"))))

(deftest overlays-a3-overlays-to-wire-layers-skips-other-buffer
  "其他 buffer 的 overlay 不出現在這個 buf 的 wire layers。"
  (with-overlay-buf (b1 :id "wb7a" :text "hello")
    (with-overlay-buf (b2 :id "wb7b" :text "world")
      (let ((o (limn/overlays:make-overlay 0 5 "wb7a")))
        (limn/overlays:overlay-put o 'face 'isearch-match))
      (assert-equal '() (limn/overlays:overlays-to-wire-layers 0 5 "wb7b")))))

(deftest overlays-a3-overlays-to-wire-layers-sorted-by-priority
  "priority 低 → 先出（先畫、底層）；高 → 後出（後畫、上層）。"
  (with-overlay-buf (b :id "wb8" :text "hello world")
    (let ((lo (limn/overlays:make-overlay 0 5 "wb8"))
          (hi (limn/overlays:make-overlay 0 5 "wb8")))
      (limn/overlays:overlay-put lo 'face 'lazy-highlight)
      (limn/overlays:overlay-put lo 'priority 1)
      (limn/overlays:overlay-put hi 'face 'isearch-match)
      (limn/overlays:overlay-put hi 'priority 10))
    (let ((layers (limn/overlays:overlays-to-wire-layers 0 5 "wb8")))
      (assert-equal "lazy-highlight" (getf (first  layers) :|face|))
      (assert-equal "isearch-match"  (getf (second layers) :|face|)))))

(deftest overlays-a3-overlays-to-wire-layers-filters-by-window
  "overlay 設 'window \"w2\" → 只在傳入 :window \"w2\" 時出現。"
  (with-overlay-buf (b :id "wb9" :text "hello world")
    (let ((ow1 (limn/overlays:make-overlay 0 5 "wb9"))
          (ow2 (limn/overlays:make-overlay 0 5 "wb9")))
      (limn/overlays:overlay-put ow1 'face 'isearch-match)
      (limn/overlays:overlay-put ow1 'window "w1")
      (limn/overlays:overlay-put ow2 'face 'lazy-highlight)
      (limn/overlays:overlay-put ow2 'window "w2"))
    (let ((w1-layers (limn/overlays:overlays-to-wire-layers 0 5 "wb9" :window "w1"))
          (w2-layers (limn/overlays:overlays-to-wire-layers 0 5 "wb9" :window "w2")))
      (assert-equal 1 (length w1-layers))
      (assert-equal 1 (length w2-layers))
      (assert-equal "isearch-match"  (getf (first w1-layers) :|face|))
      (assert-equal "lazy-highlight" (getf (first w2-layers) :|face|)))))

;;; ════════════════════════════════════════════════════════════════════════
;;; §B. Overlay 資料層 (~45 tests)
;;;
;;; 三個子節：
;;;   B1 constructor / accessor 基本（~12）
;;;   B2 properties（~10）
;;;   B3 marker auto-fixup + advance flags（~10）
;;;   B4 overlays-in / overlays-at 查找 + 邊界（~13）
;;; ════════════════════════════════════════════════════════════════════════

;;; ── B1 constructor / accessor 基本 ──────────────────────────────────────

(deftest overlays-b1-make-overlay-returns-overlay
  "make-overlay 回 overlay 物件、overlay-p 真。"
  (with-overlay-buf (b :id "o1" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "o1")))
      (assert-true (limn/overlays:overlay-p ov)
                   "overlay-p 對 make-overlay 結果為真"))))

(deftest overlays-b1-overlay-start-end-readback
  "overlay-start / overlay-end 回 (start, end) integer。"
  (with-overlay-buf (b :id "o2" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 3 7 "o2")))
      (assert-eql 3 (limn/overlays:overlay-start ov))
      (assert-eql 7 (limn/overlays:overlay-end   ov)))))

(deftest overlays-b1-overlay-buffer-readback
  "overlay-buffer 回 buf-id。"
  (with-overlay-buf (b :id "o3" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 3 "o3")))
      (assert-equal "o3" (limn/overlays:overlay-buffer ov)))))

(deftest overlays-b1-make-overlay-uses-current-buffer
  "make-overlay 省略 buf 時用 *current-buffer-id*。"
  (with-overlay-buf (b :id "o4" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 3)))
      (assert-equal "o4" (limn/overlays:overlay-buffer ov)))))

(deftest overlays-b1-delete-overlay-removes-from-buffer
  "delete-overlay 後 overlays-in 查不到。"
  (with-overlay-buf (b :id "o5" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "o5")))
      (limn/overlays:delete-overlay ov)
      (assert-equal '() (limn/overlays:overlays-in 0 5 "o5")))))

(deftest overlays-b1-delete-overlay-idempotent
  "重複 delete-overlay 不 error。"
  (with-overlay-buf (b :id "o6" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 3 "o6")))
      (limn/overlays:delete-overlay ov)
      (assert-no-error (limn/overlays:delete-overlay ov)))))

(deftest overlays-b1-move-overlay-changes-start-end
  "move-overlay 後 overlay-start / overlay-end 反映新值。"
  (with-overlay-buf (b :id "o7" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "o7")))
      (limn/overlays:move-overlay ov 3 9)
      (assert-eql 3 (limn/overlays:overlay-start ov))
      (assert-eql 9 (limn/overlays:overlay-end   ov)))))

(deftest overlays-b1-move-overlay-cross-buffer
  "move-overlay 帶 new-buf → overlay-buffer 更新、且舊 buf overlays-in 查不到。"
  (with-overlay-buf (b1 :id "o8a" :text "hello world")
    (with-overlay-buf (b2 :id "o8b" :text "lorem ipsum")
      (let ((ov (limn/overlays:make-overlay 0 5 "o8a")))
        (limn/overlays:move-overlay ov 0 5 "o8b")
        (assert-equal "o8b" (limn/overlays:overlay-buffer ov))
        (assert-equal '() (limn/overlays:overlays-in 0 5 "o8a")
                      "舊 buf 不再含此 overlay")
        (assert-equal 1 (length (limn/overlays:overlays-in 0 5 "o8b"))
                      "新 buf 含此 overlay")))))

(deftest overlays-b1-overlay-count-for-tracks-creates
  "overlay-count-for 隨 make-overlay 上升、隨 delete-overlay 下降。"
  (with-overlay-buf (b :id "o9" :text "hello world")
    (assert-eql 0 (limn/overlays:overlay-count-for "o9"))
    (let ((o1 (limn/overlays:make-overlay 0 5 "o9")))
      (assert-eql 1 (limn/overlays:overlay-count-for "o9"))
      (limn/overlays:make-overlay 6 11 "o9")
      (assert-eql 2 (limn/overlays:overlay-count-for "o9"))
      (limn/overlays:delete-overlay o1)
      (assert-eql 1 (limn/overlays:overlay-count-for "o9")))))

(deftest overlays-b1-make-overlay-rejects-negative-start
  "start 負數 → error（Emacs 兼容語義）。"
  (with-overlay-buf (b :id "o10" :text "hello")
    (assert-error error (limn/overlays:make-overlay -1 3 "o10"))))

(deftest overlays-b1-make-overlay-rejects-start-after-end
  "start > end → error。"
  (with-overlay-buf (b :id "o11" :text "hello")
    (assert-error error (limn/overlays:make-overlay 5 2 "o11"))))

(deftest overlays-b1-make-overlay-allows-empty-range
  "start == end 是合法空 overlay（zero-length, e.g. cursor marker）。"
  (with-overlay-buf (b :id "o12" :text "hello")
    (assert-no-error (limn/overlays:make-overlay 3 3 "o12"))))

;;; ── B2 properties ───────────────────────────────────────────────────────

(deftest overlays-b2-put-get-roundtrip
  "overlay-put → overlay-get 拿回同值。"
  (with-overlay-buf (b :id "p1" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 5 "p1")))
      (limn/overlays:overlay-put ov 'face 'isearch-match)
      (assert-eq 'isearch-match (limn/overlays:overlay-get ov 'face)))))

(deftest overlays-b2-get-nil-when-no-prop
  "未設 property → overlay-get 回 nil。"
  (with-overlay-buf (b :id "p2" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 5 "p2")))
      (assert-false (limn/overlays:overlay-get ov 'face)))))

(deftest overlays-b2-put-overwrites
  "重複 overlay-put 覆蓋前值（不累積）。"
  (with-overlay-buf (b :id "p3" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 5 "p3")))
      (limn/overlays:overlay-put ov 'face 'one)
      (limn/overlays:overlay-put ov 'face 'two)
      (assert-eq 'two (limn/overlays:overlay-get ov 'face)))))

(deftest overlays-b2-properties-returns-plist
  "overlay-properties 回 plist 含所有 key-value。"
  (with-overlay-buf (b :id "p4" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 5 "p4")))
      (limn/overlays:overlay-put ov 'face 'region)
      (limn/overlays:overlay-put ov 'priority 5)
      (let ((plist (limn/overlays:overlay-properties ov)))
        (assert-eq 'region (getf plist 'face))
        (assert-eql 5      (getf plist 'priority))))))

(deftest overlays-b2-put-before-string
  "before-string 屬性可存可取。"
  (with-overlay-buf (b :id "p5" :text "hello")
    (let ((ov (limn/overlays:make-overlay 3 3 "p5")))
      (limn/overlays:overlay-put ov 'before-string "→ ")
      (assert-equal "→ " (limn/overlays:overlay-get ov 'before-string)))))

(deftest overlays-b2-put-after-string
  "after-string 屬性可存可取。"
  (with-overlay-buf (b :id "p6" :text "hello")
    (let ((ov (limn/overlays:make-overlay 3 3 "p6")))
      (limn/overlays:overlay-put ov 'after-string "←")
      (assert-equal "←" (limn/overlays:overlay-get ov 'after-string)))))

(deftest overlays-b2-put-display
  "display 屬性可存（display 替換顯示）。"
  (with-overlay-buf (b :id "p7" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 5 "p7")))
      (limn/overlays:overlay-put ov 'display "[redacted]")
      (assert-equal "[redacted]" (limn/overlays:overlay-get ov 'display)))))

(deftest overlays-b2-put-keymap
  "keymap 屬性可存（key 走 overlay 內 local keymap）。"
  (with-overlay-buf (b :id "p8" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 5 "p8"))
          (km '((:|key| "RET" :|cmd| "follow-link"))))
      (limn/overlays:overlay-put ov 'keymap km)
      (assert-equal km (limn/overlays:overlay-get ov 'keymap)))))

(deftest overlays-b2-put-mouse-face
  "mouse-face 屬性可存。"
  (with-overlay-buf (b :id "p9" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 5 "p9")))
      (limn/overlays:overlay-put ov 'mouse-face 'highlight)
      (assert-eq 'highlight (limn/overlays:overlay-get ov 'mouse-face)))))

(deftest overlays-b2-properties-empty-overlay
  "剛 make-overlay 沒設任何 prop → overlay-properties 回 () 或不含設過的 key。"
  (with-overlay-buf (b :id "p10" :text "hello")
    (let ((ov (limn/overlays:make-overlay 0 5 "p10")))
      (let ((plist (limn/overlays:overlay-properties ov)))
        (assert-false (getf plist 'face))
        (assert-false (getf plist 'priority))))))

;;; ── B3 marker auto-fixup + advance flags ──────────────────────────────

(deftest overlays-b3-insert-before-start-shifts-overlay
  "在 start 之前 insert → start/end 都 +len（marker fixup）。"
  (with-overlay-buf (b :id "f1" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 6 11 "f1")))
      (%ov-mb-insert! b 0 "XY")
      (assert-eql 8  (limn/overlays:overlay-start ov))
      (assert-eql 13 (limn/overlays:overlay-end   ov)))))

(deftest overlays-b3-insert-after-end-no-shift
  "在 end 之後 insert → start/end 不動。"
  (with-overlay-buf (b :id "f2" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "f2")))
      (%ov-mb-insert! b 8 "ZZ")
      (assert-eql 0 (limn/overlays:overlay-start ov))
      (assert-eql 5 (limn/overlays:overlay-end   ov)))))

(deftest overlays-b3-insert-inside-extends-end
  "在 overlay 中段 insert → start 不動、end += len。"
  (with-overlay-buf (b :id "f3" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "f3")))
      (%ov-mb-insert! b 2 "XX")
      (assert-eql 0 (limn/overlays:overlay-start ov))
      (assert-eql 7 (limn/overlays:overlay-end   ov)))))

(deftest overlays-b3-front-advance-nil-insert-at-start
  "FRONT-ADVANCE nil（預設）：在 start 位置 insert → start 不動（sticky right）。
   Marker :before 語義。Overlay end :after 不動。"
  (with-overlay-buf (b :id "f4" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 5 9 "f4" nil nil)))
      (%ov-mb-insert! b 5 "X")
      (assert-eql 5 (limn/overlays:overlay-start ov)
                 "front-advance nil → start 不跟著新字走")
      (assert-eql 10 (limn/overlays:overlay-end ov)
                 "end 因 insert 在其前所以 +1"))))

(deftest overlays-b3-front-advance-t-insert-at-start
  "FRONT-ADVANCE t：在 start 位置 insert → start += len（sticky left）。"
  (with-overlay-buf (b :id "f5" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 5 9 "f5" t nil)))
      (%ov-mb-insert! b 5 "X")
      (assert-eql 6 (limn/overlays:overlay-start ov))
      (assert-eql 10 (limn/overlays:overlay-end ov)))))

(deftest overlays-b3-rear-advance-nil-insert-at-end
  "REAR-ADVANCE nil（預設）：在 end 位置 insert → end 不動（不擴張）。"
  (with-overlay-buf (b :id "f6" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "f6" nil nil)))
      (%ov-mb-insert! b 5 "X")
      (assert-eql 0 (limn/overlays:overlay-start ov))
      (assert-eql 5 (limn/overlays:overlay-end ov)
                 "rear-advance nil → end 不跟著新字走"))))

(deftest overlays-b3-rear-advance-t-insert-at-end
  "REAR-ADVANCE t：在 end 位置 insert → end += len（擴張涵蓋新字）。"
  (with-overlay-buf (b :id "f7" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "f7" nil t)))
      (%ov-mb-insert! b 5 "X")
      (assert-eql 0 (limn/overlays:overlay-start ov))
      (assert-eql 6 (limn/overlays:overlay-end ov)))))

(deftest overlays-b3-delete-inside-shrinks
  "在 overlay 內 delete → end 縮。"
  (with-overlay-buf (b :id "f8" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 8 "f8")))
      (%ov-mb-delete! b 2 4)
      (assert-eql 0 (limn/overlays:overlay-start ov))
      (assert-eql 6 (limn/overlays:overlay-end ov)))))

(deftest overlays-b3-delete-covers-overlay
  "delete 完全蓋過 overlay → start/end 收斂到 delete from。"
  (with-overlay-buf (b :id "f9" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 3 6 "f9")))
      (%ov-mb-delete! b 0 8)
      (assert-eql 0 (limn/overlays:overlay-start ov))
      (assert-eql 0 (limn/overlays:overlay-end ov)))))

(deftest overlays-b3-delete-before-overlay-shifts
  "delete 完全在 overlay 之前 → start/end 同步 -len。"
  (with-overlay-buf (b :id "f10" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 6 11 "f10")))
      (%ov-mb-delete! b 0 3)
      (assert-eql 3 (limn/overlays:overlay-start ov))
      (assert-eql 8 (limn/overlays:overlay-end   ov)))))

;;; ── B4 overlays-in / overlays-at 查找 + 邊界 ───────────────────────────

(deftest overlays-b4-overlays-in-finds-contained
  "完全包在 [a,b) 內 → 找得到。"
  (with-overlay-buf (b :id "q1" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 3 6 "q1")))
      (assert-equal (list ov) (limn/overlays:overlays-in 0 10 "q1")))))

(deftest overlays-b4-overlays-in-finds-partial-overlap-left
  "[ov-start, ov-end) 的 ov-start < range-end 但 ov-end > range-start → 找得到。"
  (with-overlay-buf (b :id "q2" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 5 10 "q2")))
      (assert-equal (list ov) (limn/overlays:overlays-in 0 7 "q2")))))

(deftest overlays-b4-overlays-in-finds-partial-overlap-right
  (with-overlay-buf (b :id "q3" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 2 8 "q3")))
      (assert-equal (list ov) (limn/overlays:overlays-in 5 10 "q3")))))

(deftest overlays-b4-overlays-in-finds-contains-range
  "overlay 比 range 大、把 range 包進去 → 也算 overlap → 找得到。"
  (with-overlay-buf (b :id "q4" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 11 "q4")))
      (assert-equal (list ov) (limn/overlays:overlays-in 3 7 "q4")))))

(deftest overlays-b4-overlays-in-skips-disjoint
  "完全不重疊 → 找不到。"
  (with-overlay-buf (b :id "q5" :text "hello world")
    (limn/overlays:make-overlay 0 3 "q5")
    (assert-equal '() (limn/overlays:overlays-in 5 10 "q5"))))

(deftest overlays-b4-overlays-in-boundary-overlay-end-equals-range-start
  "ov-end == range-start → 視為不重疊（半開區間 [start, end)）。"
  (with-overlay-buf (b :id "q6" :text "hello world")
    (limn/overlays:make-overlay 0 5 "q6")
    (assert-equal '() (limn/overlays:overlays-in 5 10 "q6"))))

(deftest overlays-b4-overlays-in-boundary-overlay-start-equals-range-end
  "ov-start == range-end → 不重疊。"
  (with-overlay-buf (b :id "q7" :text "hello world")
    (limn/overlays:make-overlay 5 10 "q7")
    (assert-equal '() (limn/overlays:overlays-in 0 5 "q7"))))

(deftest overlays-b4-overlays-in-empty-range
  "range start == end → 結果空 list（even if overlay touches）。"
  (with-overlay-buf (b :id "q8" :text "hello world")
    (limn/overlays:make-overlay 0 5 "q8")
    (assert-equal '() (limn/overlays:overlays-in 3 3 "q8"))))

(deftest overlays-b4-overlays-at-finds-covering
  "overlays-at pos → 回所有涵蓋 pos 的 overlay。"
  (with-overlay-buf (b :id "q9" :text "hello world")
    (let ((ov (limn/overlays:make-overlay 0 5 "q9")))
      (assert-equal (list ov) (limn/overlays:overlays-at 3 "q9")))))

(deftest overlays-b4-overlays-at-skips-noncovering
  (with-overlay-buf (b :id "q10" :text "hello world")
    (limn/overlays:make-overlay 0 5 "q10")
    (assert-equal '() (limn/overlays:overlays-at 7 "q10"))))

(deftest overlays-b4-overlays-at-priority-order
  "多個 overlay 涵蓋同 pos → overlays-at 用 priority 排序（高 priority 排前）。"
  (with-overlay-buf (b :id "q11" :text "hello world")
    (let ((lo (limn/overlays:make-overlay 0 5 "q11"))
          (hi (limn/overlays:make-overlay 0 5 "q11")))
      (limn/overlays:overlay-put lo 'priority 1)
      (limn/overlays:overlay-put hi 'priority 10)
      (let ((found (limn/overlays:overlays-at 2 "q11")))
        (assert-eql 2 (length found))
        (assert-eq hi (first found)
                   "高 priority 在前")))))

(deftest overlays-b4-overlays-isolated-per-buffer
  "b1 的 overlay 不出現在 b2 的 overlays-in。"
  (with-overlay-buf (b1 :id "q12a" :text "hello")
    (with-overlay-buf (b2 :id "q12b" :text "world")
      (limn/overlays:make-overlay 0 5 "q12a")
      (assert-equal '() (limn/overlays:overlays-in 0 5 "q12b")))))

(deftest overlays-b4-overlays-in-many-overlays-correct
  "建 100 個 overlay、overlays-in 找到的數量對。"
  (with-overlay-buf (b :id "q13" :text (make-string 200 :initial-element #\.))
    (loop for i from 0 below 100
          do (limn/overlays:make-overlay i (1+ i) "q13"))
    (assert-eql 100 (length (limn/overlays:overlays-in 0 200 "q13"))
                "100 個 overlay 全找到")
    (assert-eql 10  (length (limn/overlays:overlays-in 0 10 "q13"))
                "範圍 [0,10) 找到 10 個")))

;;; ════════════════════════════════════════════════════════════════════════
;;; §C. transient-mark-mode + region 視覺化 (~20 tests)
;;;
;;; 三個子節：
;;;   C1 transient-mark-mode flag + use-region-p（~6）
;;;   C2 motion / edit command 行為（~8）
;;;   C3 region overlay 更新（~6）
;;; ════════════════════════════════════════════════════════════════════════

;;; ── C1 transient-mark-mode + use-region-p ──────────────────────────────

(deftest region-c1-transient-mark-default-on
  "transient-mark-mode 預設 t（Emacs 25+ 行為）。"
  (assert-true limn/mark:*transient-mark-mode*
               "預設 on"))

(deftest region-c1-set-mark-activates
  "transient-mark on 時 set-mark → *mark-active* = t。"
  (let ((limn/mark:*transient-mark-mode* t))
    (limn/v024-helpers:with-mark-buf (b :id "rc1a" :text "hello world")
      (limn/mark:reset-marks "rc1a")
      (limn/mark:set-mark 3 "rc1a")
      (assert-true (limn/mark:mark-active-p "rc1a") "set-mark → active"))))

(deftest region-c1-no-mark-not-active
  "沒設過 mark → *mark-active* nil、use-region-p 也 nil。"
  (limn/v024-helpers:with-mark-buf (b :id "rc1b" :text "hello")
    (limn/mark:reset-marks "rc1b")
    (assert-false (limn/mark:mark-active-p "rc1b"))
    (assert-false (limn/mark:use-region-p "rc1b"))))

(deftest region-c1-use-region-p-true-after-set-mark
  "transient-mark on + set-mark → use-region-p t。"
  (let ((limn/mark:*transient-mark-mode* t))
    (limn/v024-helpers:with-mark-buf (b :id "rc1c" :text "hello world" :cursor 7)
      (limn/mark:reset-marks "rc1c")
      (limn/mark:set-mark 3 "rc1c")
      (assert-true (limn/mark:use-region-p "rc1c")
                   "active + cursor != mark → t"))))

(deftest region-c1-transient-off-use-region-p-nil
  "transient-mark-mode off → use-region-p 永遠 nil（即使 set-mark）。"
  (let ((limn/mark:*transient-mark-mode* nil))
    (limn/v024-helpers:with-mark-buf (b :id "rc1d" :text "hello world" :cursor 7)
      (limn/mark:reset-marks "rc1d")
      (limn/mark:set-mark 3 "rc1d")
      (assert-false (limn/mark:use-region-p "rc1d")))))

(deftest region-c1-deactivate-mark-clears-active
  "deactivate-mark → *mark-active* nil；mark 值還在。"
  (let ((limn/mark:*transient-mark-mode* t))
    (limn/v024-helpers:with-mark-buf (b :id "rc1e" :text "hello")
      (limn/mark:reset-marks "rc1e")
      (limn/mark:set-mark 2 "rc1e")
      (limn/mark:deactivate-mark "rc1e")
      (assert-false (limn/mark:mark-active-p "rc1e"))
      (assert-eql 2 (limn/mark:mark "rc1e") "mark 值還在"))))

;;; ── C2 motion / edit command 行為 ──────────────────────────────────────

(deftest region-c2-motion-command-keeps-active
  "transient-mark on + active：note-command 一個 motion → 仍 active。"
  (let ((limn/mark:*transient-mark-mode* t))
    (limn/v024-helpers:with-mark-buf (b :id "rc2a" :text "hello world")
      (limn/mark:reset-marks "rc2a")
      (limn/mark:set-mark 0 "rc2a")
      (limn/mark:note-command 'forward-char "rc2a")
      (assert-true (limn/mark:mark-active-p "rc2a")
                   "motion 後仍 active"))))

(deftest region-c2-edit-command-deactivates
  "transient-mark on + active：note-command 一個 edit → deactivate。"
  (let ((limn/mark:*transient-mark-mode* t))
    (limn/v024-helpers:with-mark-buf (b :id "rc2b" :text "hello world")
      (limn/mark:reset-marks "rc2b")
      (limn/mark:set-mark 0 "rc2b")
      (limn/mark:note-command 'self-insert-command "rc2b")
      (assert-false (limn/mark:mark-active-p "rc2b")
                    "edit 後 deactivate"))))

(defun %cmd-name-match (a b)
  "Cross-package symbol equality for command names (Emacs-style: name only)."
  (and (symbolp a) (symbolp b)
       (string= (symbol-name a) (symbol-name b))))

(deftest region-c2-default-motion-list-contains-basics
  "*motion-commands* 預設含 forward-char/backward-char/next-line/previous-line。"
  (assert-true (find 'forward-char     limn/mark:*motion-commands* :test #'%cmd-name-match))
  (assert-true (find 'backward-char    limn/mark:*motion-commands* :test #'%cmd-name-match))
  (assert-true (find 'next-line        limn/mark:*motion-commands* :test #'%cmd-name-match))
  (assert-true (find 'previous-line    limn/mark:*motion-commands* :test #'%cmd-name-match))
  (assert-true (find 'beginning-of-line limn/mark:*motion-commands* :test #'%cmd-name-match))
  (assert-true (find 'end-of-line       limn/mark:*motion-commands* :test #'%cmd-name-match)))

(deftest region-c2-default-edit-list-contains-basics
  "*edit-commands* 預設含 self-insert-command / delete-char / yank。"
  (assert-true (find 'self-insert-command limn/mark:*edit-commands* :test #'%cmd-name-match))
  (assert-true (find 'delete-char         limn/mark:*edit-commands* :test #'%cmd-name-match))
  (assert-true (find 'yank                limn/mark:*edit-commands* :test #'%cmd-name-match)))

(deftest region-c2-custom-motion-push-keeps-active
  "user push 一個 my-jump 到 *motion-commands* → 觸發後 region 仍 active。"
  (let ((limn/mark:*transient-mark-mode* t)
        (limn/mark:*motion-commands* (cons 'my-jump limn/mark:*motion-commands*)))
    (limn/v024-helpers:with-mark-buf (b :id "rc2e" :text "hello")
      (limn/mark:reset-marks "rc2e")
      (limn/mark:set-mark 0 "rc2e")
      (limn/mark:note-command 'my-jump "rc2e")
      (assert-true (limn/mark:mark-active-p "rc2e")))))

(deftest region-c2-custom-edit-push-deactivates
  (let ((limn/mark:*transient-mark-mode* t)
        (limn/mark:*edit-commands* (cons 'my-zap limn/mark:*edit-commands*)))
    (limn/v024-helpers:with-mark-buf (b :id "rc2f" :text "hello")
      (limn/mark:reset-marks "rc2f")
      (limn/mark:set-mark 0 "rc2f")
      (limn/mark:note-command 'my-zap "rc2f")
      (assert-false (limn/mark:mark-active-p "rc2f")))))

(deftest region-c2-unknown-command-keeps-active
  "command 不在 motion 也不在 edit 清單 → 預設行為 = keep active（保守）。"
  (let ((limn/mark:*transient-mark-mode* t))
    (limn/v024-helpers:with-mark-buf (b :id "rc2g" :text "hello")
      (limn/mark:reset-marks "rc2g")
      (limn/mark:set-mark 0 "rc2g")
      (limn/mark:note-command 'completely-unknown-cmd "rc2g")
      (assert-true (limn/mark:mark-active-p "rc2g")
                   "保守：不認識的 command 不亂 deactivate"))))

(deftest region-c2-edit-command-without-active-mark-noop
  "mark 未 active 時收到 edit command → 不 error、什麼都不變。"
  (let ((limn/mark:*transient-mark-mode* t))
    (limn/v024-helpers:with-mark-buf (b :id "rc2h" :text "hello")
      (limn/mark:reset-marks "rc2h")
      (assert-no-error (limn/mark:note-command 'self-insert-command "rc2h"))
      (assert-false (limn/mark:mark-active-p "rc2h")))))

(deftest region-c2-auto-deactivate-on-buffer-modified
  "v0.37 Phase F regression: install-auto-deactivate-handler subscribes
   to event/buffer-modified.  When the wire fires that event for a
   buffer with an active region and transient-mark-mode on, mark must
   drop automatically — even if no Lisp command ran (xdotool type / IME
   commit / paste bypass the dispatch layer's note-command callback).
   Before this fix the v033b-edit-during-active-region OS test reported
   'mark auto-deactivated after key (active=T)'."
  (let ((limn/mark:*transient-mark-mode* t))
    (limn/v024-helpers:with-mark-buf (b :id "rc2i" :text "hello")
      (limn/mark:reset-marks "rc2i")
      (limn/mark:set-mark 0 "rc2i")
      (limn/mark:activate-mark "rc2i")
      (assert-true (limn/mark:mark-active-p "rc2i") "setup: mark active")
      ;; Force a fresh install for this test by clearing the idempotency
      ;; flag (other tests may have installed it earlier with a different
      ;; hook table state).
      (setf (symbol-value (find-symbol "*AUTO-DEACTIVATE-INSTALLED*" '#:limn/mark)) nil)
      (limn/mark:install-auto-deactivate-handler)
      (limn/hooks:run-hook "event/buffer-modified"
                            (list :|buffer-id| "rc2i"
                                  :|op| "insert"
                                  :|pos| 0
                                  :|len| 1))
      (assert-false (limn/mark:mark-active-p "rc2i")
                    "buffer-modified event auto-deactivated mark"))))

(deftest region-c2-auto-deactivate-idempotent-install
  "install-auto-deactivate-handler is idempotent — multiple calls
   subscribe at most once.  Without this, every limn:start would stack
   another hook and a single edit would fire deactivate twice (harmless
   today, but a footgun for callers that count hook invocations)."
  (let ((limn/mark:*transient-mark-mode* t))
    (limn/v024-helpers:with-mark-buf (b :id "rc2j" :text "hi")
      (setf (symbol-value (find-symbol "*AUTO-DEACTIVATE-INSTALLED*" '#:limn/mark)) nil)
      (limn/mark:install-auto-deactivate-handler)
      (limn/mark:install-auto-deactivate-handler)
      (limn/mark:install-auto-deactivate-handler)
      (let* ((live (gethash "event/buffer-modified"
                            (symbol-value (find-symbol "*HOOKS*" '#:limn/hooks)))))
        ;; Other tests may have also added unrelated handlers — assert
        ;; that *our* deactivate handler appears at most once.  Count
        ;; closures whose printable representation contains "DEACTIVATE-MARK".
        (let ((deact-count
                (count-if (lambda (pair)
                            (search "DEACTIVATE-MARK"
                                    (princ-to-string (car pair))))
                          live)))
          (assert-true (<= deact-count 1)
                       "deactivate hook installed exactly once across 3 install calls"))))))

;;; ── C3 region overlay 更新 ────────────────────────────────────────────

(deftest region-c3-update-creates-overlay-when-active
  "active 且 cursor != mark：update-region-overlay 後 region-overlay-for 回 overlay。"
  (let ((limn/mark:*transient-mark-mode* t))
    (with-overlay-buf (b :id "rc3a" :text "hello world" :cursor 7)
      (limn/mark:reset-marks "rc3a")
      (limn/mark:set-mark 3 "rc3a")
      (limn/region:update-region-overlay "rc3a")
      (let ((ov (limn/region:region-overlay-for "rc3a")))
        (assert-true (limn/overlays:overlay-p ov)
                     "overlay 物件已建立")))))

(deftest region-c3-update-overlay-covers-point-to-mark
  "overlay range = [min(point,mark), max(point,mark))。"
  (let ((limn/mark:*transient-mark-mode* t))
    (with-overlay-buf (b :id "rc3b" :text "hello world" :cursor 8)
      (limn/mark:reset-marks "rc3b")
      (limn/mark:set-mark 3 "rc3b")
      (limn/region:update-region-overlay "rc3b")
      (let ((ov (limn/region:region-overlay-for "rc3b")))
        (assert-eql 3 (limn/overlays:overlay-start ov))
        (assert-eql 8 (limn/overlays:overlay-end ov))))))

(deftest region-c3-update-overlay-cursor-before-mark
  "cursor < mark：min/max 正確、overlay = [cursor, mark)。"
  (let ((limn/mark:*transient-mark-mode* t))
    (with-overlay-buf (b :id "rc3c" :text "hello world" :cursor 2)
      (limn/mark:reset-marks "rc3c")
      (limn/mark:set-mark 7 "rc3c")
      (limn/region:update-region-overlay "rc3c")
      (let ((ov (limn/region:region-overlay-for "rc3c")))
        (assert-eql 2 (limn/overlays:overlay-start ov))
        (assert-eql 7 (limn/overlays:overlay-end ov))))))

(deftest region-c3-update-overlay-uses-region-face
  "建立的 overlay 帶 face = 'region（name-based compare，跨 package）。"
  (let ((limn/mark:*transient-mark-mode* t))
    (with-overlay-buf (b :id "rc3d" :text "hello world" :cursor 7)
      (limn/mark:reset-marks "rc3d")
      (limn/mark:set-mark 3 "rc3d")
      (limn/region:update-region-overlay "rc3d")
      (let* ((ov  (limn/region:region-overlay-for "rc3d"))
             (val (limn/overlays:overlay-get ov 'face)))
        (assert-true (and (symbolp val)
                          (string= "REGION" (symbol-name val)))
                     "face = some package's REGION symbol")))))

(deftest region-c3-clear-removes-overlay
  "clear-region-overlay 後 region-overlay-for 回 nil。"
  (let ((limn/mark:*transient-mark-mode* t))
    (with-overlay-buf (b :id "rc3e" :text "hello world" :cursor 7)
      (limn/mark:reset-marks "rc3e")
      (limn/mark:set-mark 3 "rc3e")
      (limn/region:update-region-overlay "rc3e")
      (limn/region:clear-region-overlay "rc3e")
      (assert-false (limn/region:region-overlay-for "rc3e")))))

(deftest region-c3-update-noop-when-inactive
  "transient-mark off 時 update-region-overlay → 不建 overlay。"
  (let ((limn/mark:*transient-mark-mode* nil))
    (with-overlay-buf (b :id "rc3f" :text "hello world" :cursor 7)
      (limn/mark:reset-marks "rc3f")
      (limn/mark:set-mark 3 "rc3f")
      (limn/region:update-region-overlay "rc3f")
      (assert-false (limn/region:region-overlay-for "rc3f")
                    "transient off → no overlay"))))
