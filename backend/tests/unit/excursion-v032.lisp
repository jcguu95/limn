;;;; v0.32 — current-buffer / with-current-buffer / save-excursion /
;;;; save-restriction + narrow-to-region + widen / buffer lifecycle
;;;; RED tests (~60 tests).
;;;;
;;;; 覆蓋（SPEC §12.v0.32 A–E）：
;;;;   §A *current-buffer* dyn var + current-buffer / current-buffer-id /
;;;;      buffer-name / set-buffer / resolve-buffer
;;;;   §B with-current-buffer macro
;;;;   §C save-excursion macro（用 marker 存 point + mark、unwind-protect）
;;;;   §D narrow-to-region / widen / save-restriction + point-min / point-max
;;;;      clipping（narrow markers 是 buffer-local var）
;;;;   §E buffer lifecycle: buffer-list / get-buffer / get-buffer-create /
;;;;      kill-buffer / rename-buffer
;;;;
;;;; 依賴：v0.30 markers (limn/marker) + buffer-local vars (limn/local)。
;;;;
;;;; 全部 RED — 在 limn-excursion.lisp 實作前都會 fail。

;; ── package stub ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/excursion)
    (make-package '#:limn/excursion :use '(#:cl)))
  (dolist (sym '(;; §A current-buffer
                 "*CURRENT-BUFFER*"
                 "CURRENT-BUFFER"
                 "CURRENT-BUFFER-ID"
                 "BUFFER-NAME"
                 "SET-BUFFER"
                 "RESOLVE-BUFFER"
                 ;; §B with-current-buffer
                 "WITH-CURRENT-BUFFER"
                 ;; §C save-excursion
                 "SAVE-EXCURSION"
                 ;; §D narrow-to-region
                 "NARROW-TO-REGION"
                 "WIDEN"
                 "SAVE-RESTRICTION"
                 "POINT-MIN"
                 "POINT-MAX"
                 "NARROWED-P"
                 ;; §E buffer lifecycle
                 "BUFFER-LIST"
                 "GET-BUFFER"
                 "GET-BUFFER-CREATE"
                 "KILL-BUFFER"
                 "RENAME-BUFFER"
                 ;; point / goto-char (re-exported convenience; may live
                 ;; elsewhere in impl but tests call through this package)
                 "POINT"
                 "GOTO-CHAR"
                 ;; vtable hooks (mock wires in here so impl can be
                 ;; dependency-injected for tests)
                 "*POINT-FN*"
                 "*SET-POINT-FN*"
                 "*MARK-FN*"
                 "*SET-MARK-FN*"
                 "*MARK-ACTIVE-FN*"
                 "*SET-MARK-ACTIVE-FN*"
                 "*BUFFER-TEXT-LEN-FN*"
                 "*BUFFER-NAME-FN*"
                 "*BUFFER-INSERT-FN*"
                 "*BUFFER-DELETE-FN*"
                 ;; test helpers
                 "RESET-EXCURSION-STATE"))
    (export (intern sym '#:limn/excursion) '#:limn/excursion)))

(in-package #:limn/unit-test)

;;; ── mock buffer infrastructure ────────────────────────────────────────────
;;;
;;; v0.32 needs richer mocks than v0.30 — we model buffers with point,
;;; mark, mark-active, and text. The mock fires limn/marker:process-insert
;;; / process-delete on edits so save-excursion's markers fix up.
;;;
;;; *excursion-buffers* : buf-id → mmbuf32 (mock buffer)
;;; The vtable functions read/write these.

(defstruct (mmbuf32
             (:conc-name mmbuf32-)
             (:constructor make-mmbuf32 (&key (id "b") (name nil)
                                              (text "") (point 0)
                                              (mark nil) (mark-active nil))))
  id
  name                    ; display name; defaults to id when nil
  (text "" :type string)
  (point 0 :type integer)
  mark                    ; integer offset or nil
  mark-active)            ; boolean

(defun mmbuf32-len (b) (length (mmbuf32-text b)))
(defun mmbuf32-display-name (b) (or (mmbuf32-name b) (mmbuf32-id b)))

(defvar *excursion-buffers* (make-hash-table :test 'equal))

(defun mmbuf32-get (bid) (gethash bid *excursion-buffers*))

;;; Vtable adapters — read state from the mock map.
(defun mmbuf32-point-fn (bid)
  (let ((b (mmbuf32-get bid))) (if b (mmbuf32-point b) 0)))

(defun mmbuf32-set-point-fn (bid off)
  (let ((b (mmbuf32-get bid)))
    (when b (setf (mmbuf32-point b) off))))

(defun mmbuf32-mark-fn (bid)
  (let ((b (mmbuf32-get bid))) (when b (mmbuf32-mark b))))

(defun mmbuf32-set-mark-fn (bid off)
  (let ((b (mmbuf32-get bid)))
    (when b (setf (mmbuf32-mark b) off))))

(defun mmbuf32-mark-active-fn (bid)
  (let ((b (mmbuf32-get bid))) (when b (mmbuf32-mark-active b))))

(defun mmbuf32-set-mark-active-fn (bid v)
  (let ((b (mmbuf32-get bid)))
    (when b (setf (mmbuf32-mark-active b) v))))

(defun mmbuf32-text-len-fn (bid)
  (let ((b (mmbuf32-get bid))) (if b (mmbuf32-len b) 0)))

(defun mmbuf32-name-fn (bid)
  (let ((b (mmbuf32-get bid))) (when b (mmbuf32-display-name b))))

(defun mmbuf32-insert-fn (bid pos str)
  "Insert STR at POS in mmbuf32 BID; fire marker fixup."
  (let ((b (mmbuf32-get bid)))
    (when b
      (let ((txt (mmbuf32-text b)))
        (setf (mmbuf32-text b)
              (concatenate 'string
                           (subseq txt 0 pos) str (subseq txt pos))))
      ;; advance point if at/after insert
      (when (>= (mmbuf32-point b) pos)
        (incf (mmbuf32-point b) (length str)))
      ;; fire marker fixup so v0.30 markers / v0.32 narrow markers track
      (when (find-package '#:limn/marker)
        (funcall (find-symbol "PROCESS-INSERT" '#:limn/marker)
                 bid pos (length str))))))

(defun mmbuf32-delete-fn (bid from to)
  "Delete [FROM,TO) from mmbuf32 BID; fire marker fixup."
  (let ((b (mmbuf32-get bid)))
    (when b
      (let ((txt (mmbuf32-text b)))
        (setf (mmbuf32-text b)
              (concatenate 'string (subseq txt 0 from) (subseq txt to))))
      ;; clamp point
      (let ((p (mmbuf32-point b)))
        (cond ((<= p from) nil)
              ((< p to)    (setf (mmbuf32-point b) from))
              (t           (decf (mmbuf32-point b) (- to from)))))
      (when (find-package '#:limn/marker)
        (funcall (find-symbol "PROCESS-DELETE" '#:limn/marker)
                 bid from to)))))

;;; Macro: with-excursion-ctx — register one or more mock buffers, wire
;;; vtable. Cleanup removes them from the map and resets marker / local
;;; state.

(defmacro with-excursion-ctx ((&rest buf-specs) &body body)
  "Each BUF-SPEC: (VAR &key id name text point mark mark-active).
   Inside BODY, *current-buffer* (the v0.32 dyn var) is bound to the
   first buffer's mmbuf32."
  (let* ((first-spec (car buf-specs))
         (first-var (car first-spec))
         (vars  (mapcar #'car buf-specs))
         (kwargs (mapcar #'cdr buf-specs))
         (ids   (gensym "IDS"))
         (xpkg  (gensym "XPKG"))
         (mpkg  (gensym "MPKG"))
         (lpkg  (gensym "LPKG"))
         (pairs (gensym "PAIRS"))
         (live  (gensym "LIVE"))
         (sym-current (gensym "SCB")))
    (declare (ignorable first-var))
    `(let* (,@(loop for v in vars
                    for kw in kwargs
                    collect `(,v (make-mmbuf32 ,@kw)))
            (,ids (list ,@(loop for v in vars collect `(mmbuf32-id ,v))))
            (,xpkg (find-package '#:limn/excursion))
            (,mpkg (find-package '#:limn/marker))
            (,lpkg (find-package '#:limn/local)))
       ;; register all mocks in our local id-keyed map (for vtable lookups)
       (dolist (b (list ,@vars))
         (setf (gethash (mmbuf32-id b) *excursion-buffers*) b))
       ;; also register in limn/excursion's registry (buffer-list /
       ;; get-buffer / current-buffer-id reverse lookup all consult it)
       (when ,xpkg
         (let ((reg (find-symbol "REGISTER-BUFFER" ,xpkg)))
           (when reg
             (dolist (b (list ,@vars))
               (funcall reg b (mmbuf32-id b) :name (mmbuf32-name b))))))
       ;; reset v0.30 marker / local state for these buf-ids
       (when ,mpkg
         (let ((reset (find-symbol "RESET-MARKERS" ,mpkg)))
           (when reset (dolist (id ,ids) (funcall reset id)))))
       (when ,lpkg
         (let ((reset (find-symbol "RESET-BUFFER-LOCALS" ,lpkg)))
           (when reset (dolist (id ,ids) (funcall reset id)))))
       (unwind-protect
            (let* ((,pairs
                     (when ,xpkg
                       (list
                        (cons (find-symbol "*POINT-FN*"             ,xpkg)
                              #'mmbuf32-point-fn)
                        (cons (find-symbol "*SET-POINT-FN*"         ,xpkg)
                              #'mmbuf32-set-point-fn)
                        (cons (find-symbol "*MARK-FN*"              ,xpkg)
                              #'mmbuf32-mark-fn)
                        (cons (find-symbol "*SET-MARK-FN*"          ,xpkg)
                              #'mmbuf32-set-mark-fn)
                        (cons (find-symbol "*MARK-ACTIVE-FN*"       ,xpkg)
                              #'mmbuf32-mark-active-fn)
                        (cons (find-symbol "*SET-MARK-ACTIVE-FN*"   ,xpkg)
                              #'mmbuf32-set-mark-active-fn)
                        (cons (find-symbol "*BUFFER-TEXT-LEN-FN*"   ,xpkg)
                              #'mmbuf32-text-len-fn)
                        (cons (find-symbol "*BUFFER-NAME-FN*"       ,xpkg)
                              #'mmbuf32-name-fn)
                        (cons (find-symbol "*BUFFER-INSERT-FN*"     ,xpkg)
                              #'mmbuf32-insert-fn)
                        (cons (find-symbol "*BUFFER-DELETE-FN*"     ,xpkg)
                              #'mmbuf32-delete-fn)
                        (cons (find-symbol "*CURRENT-BUFFER*"       ,xpkg)
                              ,first-var))))
                   ;; also bind limn/marker's vtable so markers in
                   ;; save-excursion track the mock buffers' text-len
                   (mpairs
                     (when ,mpkg
                       (list
                        (cons (find-symbol "*BUFFER-CURSOR-FN*"   ,mpkg)
                              #'mmbuf32-point-fn)
                        (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,mpkg)
                              #'mmbuf32-text-len-fn)
                        (cons (find-symbol "*CURRENT-BUFFER-ID*"  ,mpkg)
                              (mmbuf32-id ,first-var)))))
                   ;; bind limn/local current-buffer-id too (for narrow
                   ;; markers that live as buffer-local vars)
                   (lpairs
                     (when ,lpkg
                       (list
                        (cons (find-symbol "*CURRENT-BUFFER-ID*" ,lpkg)
                              (mmbuf32-id ,first-var)))))
                   (,live (remove-if (lambda (p) (null (car p)))
                                     (append ,pairs mpairs lpairs))))
              (declare (ignorable ,sym-current))
              (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
                ,@body))
         ;; cleanup
         (dolist (id ,ids) (remhash id *excursion-buffers*))
         (when ,xpkg
           (let ((unreg (find-symbol "UNREGISTER-BUFFER" ,xpkg)))
             (when unreg (dolist (id ,ids) (funcall unreg id)))))
         (when ,mpkg
           (let ((reset (find-symbol "RESET-MARKERS" ,mpkg)))
             (when reset (dolist (id ,ids) (funcall reset id)))))
         (when ,lpkg
           (let ((reset (find-symbol "RESET-BUFFER-LOCALS" ,lpkg)))
             (when reset (dolist (id ,ids) (funcall reset id)))))))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §A. current-buffer / set-buffer / buffer-name / current-buffer-id
;;; ─────────────────────────────────────────────────────────────────────────

(deftest excursion-a1-current-buffer-returns-bound-value
  "*current-buffer* 綁定後 (current-buffer) 回那個 buffer。"
  (with-excursion-ctx ((b :id "a1a" :text "hello"))
    (assert-eq b (limn/excursion:current-buffer)
               "current-buffer returns bound value")))

(deftest excursion-a1-current-buffer-id-returns-string
  "current-buffer-id 回 wire-level buffer-id 字串。"
  (with-excursion-ctx ((b :id "a1b" :text "hi"))
    (assert-equal "a1b" (limn/excursion:current-buffer-id)
                  "current-buffer-id = mmbuf32-id")))

(deftest excursion-a1-set-buffer-changes-current
  "set-buffer 把 *current-buffer* 改成新值。"
  (with-excursion-ctx ((b1 :id "a1c-A" :text "A")
                       (b2 :id "a1c-B" :text "B"))
    (assert-eq b1 (limn/excursion:current-buffer)
               "initial current = b1")
    (limn/excursion:set-buffer b2)
    (assert-eq b2 (limn/excursion:current-buffer)
               "after set-buffer: current = b2")))

(deftest excursion-a1-set-buffer-updates-current-buffer-id
  "set-buffer 也同步更新 current-buffer-id。"
  (with-excursion-ctx ((b1 :id "a1d-A") (b2 :id "a1d-B"))
    (limn/excursion:set-buffer b2)
    (assert-equal "a1d-B" (limn/excursion:current-buffer-id)
                  "current-buffer-id reflects set-buffer")))

(deftest excursion-a1-set-buffer-nonexistent-errors
  "set-buffer 給不存在的 buffer-id → signal error。"
  (with-excursion-ctx ((b :id "a1e"))
    (assert-error error
                  (limn/excursion:set-buffer "does-not-exist-a1e")
                  "set-buffer on missing id: error")))

(deftest excursion-a1-buffer-name-default-uses-current
  "buffer-name 沒傳參數 → 用 current-buffer。"
  (with-excursion-ctx ((b :id "a1f" :name "My Doc.pdf" :text "x"))
    (assert-equal "My Doc.pdf" (limn/excursion:buffer-name)
                  "buffer-name uses current-buffer when omitted")))

(deftest excursion-a1-buffer-name-explicit-buffer
  "buffer-name 傳 buffer object → 該 buffer 的 name。"
  (with-excursion-ctx ((b1 :id "a1g-A" :name "Alpha")
                       (b2 :id "a1g-B" :name "Beta"))
    (assert-equal "Beta" (limn/excursion:buffer-name b2)
                  "buffer-name b2 = 'Beta'")))

(deftest excursion-a1-buffer-name-falls-back-to-id
  "buffer-name 對沒設 name 的 buffer → 回 buffer-id。"
  (with-excursion-ctx ((b :id "a1h-noname" :text "x"))
    (assert-equal "a1h-noname" (limn/excursion:buffer-name b)
                  "no explicit name → falls back to id")))

(deftest excursion-a1-current-buffer-nested-set
  "巢狀 set-buffer：外層改→內層再改→兩層讀都對。"
  (with-excursion-ctx ((b1 :id "a1i-A") (b2 :id "a1i-B") (b3 :id "a1i-C"))
    (limn/excursion:set-buffer b2)
    (assert-eq b2 (limn/excursion:current-buffer) "outer set: b2")
    (let ((limn/excursion:*current-buffer* b3))
      (assert-eq b3 (limn/excursion:current-buffer) "inner let: b3"))
    (assert-eq b2 (limn/excursion:current-buffer) "after inner: back to b2")))

(deftest excursion-a1-current-buffer-id-without-current-is-nil
  "*current-buffer* = nil → current-buffer-id 回 nil（不 crash）。"
  (let ((limn/excursion:*current-buffer* nil))
    (assert-false (limn/excursion:current-buffer-id)
                  "no current buffer → id = nil")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §B. with-current-buffer
;;; ─────────────────────────────────────────────────────────────────────────

(deftest excursion-b1-with-current-buffer-dynamic-restore
  "body 結束後 *current-buffer* 回復原值。"
  (with-excursion-ctx ((b1 :id "b1a-A") (b2 :id "b1a-B"))
    (assert-eq b1 (limn/excursion:current-buffer) "init b1")
    (limn/excursion:with-current-buffer b2
      (assert-eq b2 (limn/excursion:current-buffer) "in body: b2"))
    (assert-eq b1 (limn/excursion:current-buffer) "after body: restored to b1")))

(deftest excursion-b1-with-current-buffer-takes-mode-buffer
  "with-current-buffer 吃 buffer object 直接用。"
  (with-excursion-ctx ((b1 :id "b1b-A") (b2 :id "b1b-B"))
    (limn/excursion:with-current-buffer b2
      (assert-equal "b1b-B" (limn/excursion:current-buffer-id)
                    "passing buffer object works"))))

(deftest excursion-b1-with-current-buffer-takes-string-id
  "with-current-buffer 吃 buffer-id 字串 → resolve-buffer 找到 mode-buffer。"
  (with-excursion-ctx ((b1 :id "b1c-A") (b2 :id "b1c-B"))
    (limn/excursion:with-current-buffer "b1c-B"
      (assert-equal "b1c-B" (limn/excursion:current-buffer-id)
                    "string id resolves correctly"))))

(deftest excursion-b1-with-current-buffer-takes-name
  "with-current-buffer 吃 buffer-name 字串 → 名字 lookup 也要 work。"
  (with-excursion-ctx ((b1 :id "b1d-A" :name "alpha")
                       (b2 :id "b1d-B" :name "beta"))
    (limn/excursion:with-current-buffer "beta"
      (assert-equal "b1d-B" (limn/excursion:current-buffer-id)
                    "name 'beta' resolves to b1d-B"))))

(deftest excursion-b1-with-current-buffer-nested
  "巢狀 with-current-buffer 各層 current 對、最外層 restore 對。"
  (with-excursion-ctx ((b1 :id "b1e-A") (b2 :id "b1e-B") (b3 :id "b1e-C"))
    (limn/excursion:with-current-buffer b2
      (assert-equal "b1e-B" (limn/excursion:current-buffer-id) "outer = B")
      (limn/excursion:with-current-buffer b3
        (assert-equal "b1e-C" (limn/excursion:current-buffer-id) "inner = C"))
      (assert-equal "b1e-B" (limn/excursion:current-buffer-id) "after inner = B"))
    (assert-equal "b1e-A" (limn/excursion:current-buffer-id) "after outer = A")))

(deftest excursion-b1-with-current-buffer-body-error-still-restores
  "body 拋 error → *current-buffer* 仍 restore（unwind-protect）。"
  (with-excursion-ctx ((b1 :id "b1f-A") (b2 :id "b1f-B"))
    (handler-case
        (limn/excursion:with-current-buffer b2
          (error "intentional in b1f"))
      (error () nil))
    (assert-eq b1 (limn/excursion:current-buffer)
               "current restored after error in body")))

(deftest excursion-b1-with-current-buffer-invalid-errors
  "with-current-buffer 給不存在的 buffer → error。"
  (with-excursion-ctx ((b :id "b1g"))
    (assert-error error
                  (limn/excursion:with-current-buffer "does-not-exist-b1g"
                    nil)
                  "unknown buffer: error")))

(deftest excursion-b1-with-current-buffer-body-return-value
  "with-current-buffer 回傳 body 最後一個 form 的值。"
  (with-excursion-ctx ((b1 :id "b1h-A") (b2 :id "b1h-B"))
    (let ((r (limn/excursion:with-current-buffer b2 42)))
      (assert-eql 42 r "body returns 42"))))

(deftest excursion-b1-resolve-buffer-by-id
  "resolve-buffer 給 buffer-id 字串 → 回 mode-buffer。"
  (with-excursion-ctx ((b :id "b1i" :name "n"))
    (assert-eq b (limn/excursion:resolve-buffer "b1i")
               "resolve-buffer by id")))

(deftest excursion-b1-resolve-buffer-by-name
  "resolve-buffer 給 buffer-name → 回 mode-buffer。"
  (with-excursion-ctx ((b :id "b1j-id" :name "by-name"))
    (assert-eq b (limn/excursion:resolve-buffer "by-name")
               "resolve-buffer by display name")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §C. save-excursion
;;; ─────────────────────────────────────────────────────────────────────────

(deftest excursion-c1-save-excursion-restores-point
  "body 改 point → 結束後 point 還原。"
  (with-excursion-ctx ((b :id "c1a" :text "abcdef" :point 3))
    (limn/excursion:save-excursion
      (limn/excursion:goto-char 0))
    (assert-eql 3 (limn/excursion:point) "point restored to 3")))

(deftest excursion-c1-save-excursion-restores-after-error
  "body 拋 error → point 仍 restore（unwind-protect）。"
  (with-excursion-ctx ((b :id "c1b" :text "abcdef" :point 4))
    (handler-case
        (limn/excursion:save-excursion
          (limn/excursion:goto-char 0)
          (error "boom"))
      (error () nil))
    (assert-eql 4 (limn/excursion:point) "point restored after error")))

(deftest excursion-c1-save-excursion-restores-with-insert-after-point
  "body 在 point 後插字 → restore 後 point 不變（marker rear-sticky）。"
  (with-excursion-ctx ((b :id "c1c" :text "abcdef" :point 2))
    (limn/excursion:save-excursion
      (limn/excursion:goto-char 4)
      (funcall limn/excursion:*buffer-insert-fn* "c1c" 4 "XX"))
    (assert-eql 2 (limn/excursion:point)
                "insert after point: marker unchanged at 2")))

(deftest excursion-c1-save-excursion-fixup-on-insert-before
  "body 在 point 前插字 → restore 後 point 跟著 +len（marker fixup）。"
  (with-excursion-ctx ((b :id "c1d" :text "abcdef" :point 4))
    (limn/excursion:save-excursion
      (limn/excursion:goto-char 0)
      (funcall limn/excursion:*buffer-insert-fn* "c1d" 0 "XYZ"))
    (assert-eql 7 (limn/excursion:point)
                "insert 3 chars before: 4 → 7")))

(deftest excursion-c1-save-excursion-fixup-on-delete-before
  "body 在 point 前刪字 → restore 後 point 跟著 -len。"
  (with-excursion-ctx ((b :id "c1e" :text "abcdef" :point 5))
    (limn/excursion:save-excursion
      (funcall limn/excursion:*buffer-delete-fn* "c1e" 0 2))
    (assert-eql 3 (limn/excursion:point)
                "delete 2 chars before point: 5 → 3")))

(deftest excursion-c1-save-excursion-delete-covering-point-clamps
  "body delete 跨 point → point clamp 到 from。"
  (with-excursion-ctx ((b :id "c1f" :text "abcdef" :point 3))
    (limn/excursion:save-excursion
      (funcall limn/excursion:*buffer-delete-fn* "c1f" 1 5))
    (assert-eql 1 (limn/excursion:point)
                "delete [1,5) covers point 3 → clamp to 1")))

(deftest excursion-c1-save-excursion-restores-mark
  "body 改 mark → restore 後 mark 還原。"
  (with-excursion-ctx ((b :id "c1g" :text "abcdef" :point 0 :mark 2))
    (limn/excursion:save-excursion
      (funcall limn/excursion:*set-mark-fn* "c1g" 5))
    (assert-eql 2 (funcall limn/excursion:*mark-fn* "c1g")
                "mark restored to 2")))

(deftest excursion-c1-save-excursion-restores-mark-active
  "body 改 mark-active → restore 後 mark-active 還原。"
  (with-excursion-ctx ((b :id "c1h" :text "abc" :mark 1 :mark-active t))
    (limn/excursion:save-excursion
      (funcall limn/excursion:*set-mark-active-fn* "c1h" nil))
    (assert-true (funcall limn/excursion:*mark-active-fn* "c1h")
                 "mark-active restored to t")))

(deftest excursion-c1-save-excursion-nested
  "巢狀 save-excursion 各層獨立 restore。"
  (with-excursion-ctx ((b :id "c1i" :text "abcdef" :point 2))
    (limn/excursion:save-excursion
      (limn/excursion:goto-char 5)
      (limn/excursion:save-excursion
        (limn/excursion:goto-char 1))
      (assert-eql 5 (limn/excursion:point) "inner restored to 5"))
    (assert-eql 2 (limn/excursion:point) "outer restored to 2")))

(deftest excursion-c1-save-excursion-marker-released
  "save-excursion 結束後內部 marker 被釋放（marker-count-for 不單調增長）。"
  (with-excursion-ctx ((b :id "c1j" :text "hello" :point 2))
    (let ((before (when (find-package '#:limn/marker)
                    (funcall (find-symbol "MARKER-COUNT-FOR" '#:limn/marker)
                             "c1j"))))
      (dotimes (_ 5)
        (limn/excursion:save-excursion
          (limn/excursion:goto-char 0)))
      (let ((after (when (find-package '#:limn/marker)
                     (funcall (find-symbol "MARKER-COUNT-FOR" '#:limn/marker)
                              "c1j"))))
        (assert-eql before after
                    "marker count back to baseline after 5 save-excursion calls")))))

(deftest excursion-c1-save-excursion-empty-body
  "空 body → 不 crash，point 不變。"
  (with-excursion-ctx ((b :id "c1k" :text "x" :point 0))
    (assert-no-error (limn/excursion:save-excursion)
                     "empty save-excursion body")
    (assert-eql 0 (limn/excursion:point) "point unchanged")))

(deftest excursion-c1-save-excursion-returns-body-value
  "save-excursion 回傳 body 最後一個 form 的值。"
  (with-excursion-ctx ((b :id "c1l" :text "abc"))
    (let ((r (limn/excursion:save-excursion 42)))
      (assert-eql 42 r "save-excursion returns body value"))))

(deftest excursion-c1-save-excursion-multiple-goto
  "body 多次 goto-char → 最後 restore 到原 point。"
  (with-excursion-ctx ((b :id "c1m" :text "hello world" :point 6))
    (limn/excursion:save-excursion
      (limn/excursion:goto-char 0)
      (limn/excursion:goto-char 5)
      (limn/excursion:goto-char 9))
    (assert-eql 6 (limn/excursion:point) "point still 6")))

(deftest excursion-c1-save-excursion-cross-buffer-isolation
  "save-excursion 在 buffer A、body 切到 buffer B 編輯不影響 A 的 point restore。"
  (with-excursion-ctx ((b1 :id "c1n-A" :text "aaaaa" :point 3)
                       (b2 :id "c1n-B" :text "bbbbb" :point 1))
    (limn/excursion:save-excursion
      (limn/excursion:with-current-buffer b2
        (funcall limn/excursion:*buffer-insert-fn* "c1n-B" 0 "ZZZ")))
    (assert-eql 3 (limn/excursion:point)
                "b1 point unaffected by b2 edits")))

(deftest excursion-c1-save-excursion-point-at-zero
  "point 在 0 → save-excursion 後仍在 0。"
  (with-excursion-ctx ((b :id "c1o" :text "abc" :point 0))
    (limn/excursion:save-excursion
      (limn/excursion:goto-char 3))
    (assert-eql 0 (limn/excursion:point) "point at 0 restored")))

(deftest excursion-c1-save-excursion-point-at-end
  "point 在 text-len → save-excursion 後仍在末端。"
  (with-excursion-ctx ((b :id "c1p" :text "hello" :point 5))
    (limn/excursion:save-excursion
      (limn/excursion:goto-char 0))
    (assert-eql 5 (limn/excursion:point) "point at end (5) restored")))

(deftest excursion-c1-save-excursion-unicode-fixup
  "body 在 point 前插 emoji（1 codepoint）→ point 仍 +1。"
  (with-excursion-ctx ((b :id "c1q"
                        :text (coerce '(#\A #\B #\C) 'string) :point 2))
    (limn/excursion:save-excursion
      (funcall limn/excursion:*buffer-insert-fn* "c1q" 0
               (coerce '(#\U0001F600) 'string)))
    (assert-eql 3 (limn/excursion:point)
                "codepoint unit: 2+1=3 after emoji insert")))

(deftest excursion-c1-save-excursion-many-edits-marker-stable
  "body 內 50 次 insert at 0 → restore 後 point 為 orig + 50。"
  (with-excursion-ctx ((b :id "c1r" :text "hello" :point 5))
    (limn/excursion:save-excursion
      (dotimes (_ 50)
        (funcall limn/excursion:*buffer-insert-fn* "c1r" 0 "x")))
    (assert-eql 55 (limn/excursion:point)
                "50 inserts before point: 5 → 55")))

(deftest excursion-c1-save-excursion-restores-even-with-set-buffer
  "body 內 set-buffer → save-excursion 仍 restore 原本 current。"
  (with-excursion-ctx ((b1 :id "c1s-A" :point 2) (b2 :id "c1s-B" :point 0))
    (limn/excursion:save-excursion
      (limn/excursion:set-buffer b2)
      (limn/excursion:goto-char 1))
    (assert-eq b1 (limn/excursion:current-buffer)
               "current-buffer restored after save-excursion")))

(deftest excursion-c1-save-excursion-multiple-sequential
  "連續 5 個 save-excursion 各自獨立、不互相污染。"
  (with-excursion-ctx ((b :id "c1t" :text "abcdef" :point 2))
    (dolist (target '(0 1 4 5 3))
      (limn/excursion:save-excursion (limn/excursion:goto-char target))
      (assert-eql 2 (limn/excursion:point)
                  (format nil "after save-excursion (goto-char ~a) → 2" target)))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §D. narrow-to-region / widen / save-restriction
;;; ─────────────────────────────────────────────────────────────────────────

(deftest excursion-d1-narrow-clips-point-min
  "narrow-to-region 5 10 → (point-min) = 5。"
  (with-excursion-ctx ((b :id "d1a" :text "0123456789ABCDEF"))
    (limn/excursion:narrow-to-region 5 10)
    (assert-eql 5 (limn/excursion:point-min)
                "point-min after narrow = 5")))

(deftest excursion-d1-narrow-clips-point-max
  "narrow-to-region 5 10 → (point-max) = 10。"
  (with-excursion-ctx ((b :id "d1b" :text "0123456789ABCDEF"))
    (limn/excursion:narrow-to-region 5 10)
    (assert-eql 10 (limn/excursion:point-max)
                "point-max after narrow = 10")))

(deftest excursion-d1-widen-clears-narrow
  "widen 後 point-min = 0, point-max = text-len。"
  (with-excursion-ctx ((b :id "d1c" :text "01234567"))
    (limn/excursion:narrow-to-region 2 5)
    (limn/excursion:widen)
    (assert-eql 0 (limn/excursion:point-min) "widen: point-min = 0")
    (assert-eql 8 (limn/excursion:point-max) "widen: point-max = 8")))

(deftest excursion-d1-default-point-min-is-zero
  "沒 narrow 時 point-min = 0。"
  (with-excursion-ctx ((b :id "d1d" :text "abcdef"))
    (assert-eql 0 (limn/excursion:point-min) "no narrow: point-min = 0")))

(deftest excursion-d1-default-point-max-is-text-len
  "沒 narrow 時 point-max = text-len。"
  (with-excursion-ctx ((b :id "d1e" :text "abcdef"))
    (assert-eql 6 (limn/excursion:point-max) "no narrow: point-max = 6")))

(deftest excursion-d1-narrowed-p-true-after-narrow
  "narrowed-p 在 narrow 之後 t、widen 之後 nil。"
  (with-excursion-ctx ((b :id "d1f" :text "01234567"))
    (assert-false (limn/excursion:narrowed-p) "initial: narrowed-p nil")
    (limn/excursion:narrow-to-region 2 5)
    (assert-true (limn/excursion:narrowed-p) "after narrow: t")
    (limn/excursion:widen)
    (assert-false (limn/excursion:narrowed-p) "after widen: nil")))

(deftest excursion-d1-save-restriction-restores-widen
  "save-restriction 包住 narrow → 結束後仍 widened。"
  (with-excursion-ctx ((b :id "d1g" :text "01234567"))
    (limn/excursion:save-restriction
      (limn/excursion:narrow-to-region 2 5)
      (assert-true (limn/excursion:narrowed-p) "inside body: narrowed"))
    (assert-false (limn/excursion:narrowed-p) "after body: widened restored")))

(deftest excursion-d1-save-restriction-restores-prior-narrow
  "已 narrow 狀態下 save-restriction → 內層改 narrow → 結束回原 narrow。"
  (with-excursion-ctx ((b :id "d1h" :text "0123456789ABCDEF"))
    (limn/excursion:narrow-to-region 2 10)   ; outer narrow [2,10)
    (limn/excursion:save-restriction
      (limn/excursion:narrow-to-region 5 7)
      (assert-eql 5 (limn/excursion:point-min) "inner: 5")
      (assert-eql 7 (limn/excursion:point-max) "inner: 7"))
    (assert-eql 2 (limn/excursion:point-min) "outer restored: 2")
    (assert-eql 10 (limn/excursion:point-max) "outer restored: 10")))

(deftest excursion-d1-save-restriction-nested
  "雙層 save-restriction → 各自 restore。"
  (with-excursion-ctx ((b :id "d1i" :text "0123456789ABCDEF"))
    (limn/excursion:save-restriction
      (limn/excursion:narrow-to-region 1 12)
      (limn/excursion:save-restriction
        (limn/excursion:narrow-to-region 5 8)
        (assert-eql 5 (limn/excursion:point-min) "innermost: 5"))
      (assert-eql 1 (limn/excursion:point-min) "middle restored: 1"))
    (assert-eql 0 (limn/excursion:point-min) "outermost: widened")))

(deftest excursion-d1-narrow-is-buffer-local
  "narrow-to-region 在 buffer A，buffer B 不受影響。"
  (with-excursion-ctx ((b1 :id "d1j-A" :text "abcdefgh")
                       (b2 :id "d1j-B" :text "01234567"))
    (limn/excursion:narrow-to-region 2 5)        ; narrow in current = b1
    (limn/excursion:with-current-buffer b2
      (assert-eql 0 (limn/excursion:point-min) "b2: not narrowed")
      (assert-eql 8 (limn/excursion:point-max) "b2: point-max = 8"))
    (assert-eql 2 (limn/excursion:point-min) "b1: still narrowed at 2")))

(deftest excursion-d1-narrow-fixup-on-insert-before
  "narrow-to-region [5,10) 後在 pos 0 插 3 字 → markers fixup [8,13)。"
  (with-excursion-ctx ((b :id "d1k" :text "0123456789ABCDEF"))
    (limn/excursion:narrow-to-region 5 10)
    (funcall limn/excursion:*buffer-insert-fn* "d1k" 0 "XYZ")
    (assert-eql 8 (limn/excursion:point-min) "narrow-start: 5+3=8")
    (assert-eql 13 (limn/excursion:point-max) "narrow-end: 10+3=13")))

(deftest excursion-d1-narrow-fixup-on-delete-inside
  "narrow-to-region [2,10) 後 delete [4,6) → markers fixup [2,8)。"
  (with-excursion-ctx ((b :id "d1l" :text "0123456789ABCDEF"))
    (limn/excursion:narrow-to-region 2 10)
    (funcall limn/excursion:*buffer-delete-fn* "d1l" 4 6)
    (assert-eql 2 (limn/excursion:point-min) "narrow-start unchanged: 2")
    (assert-eql 8 (limn/excursion:point-max) "narrow-end: 10-2=8")))

(deftest excursion-d1-narrow-start-greater-than-end-errors
  "narrow-to-region start > end → error。"
  (with-excursion-ctx ((b :id "d1m" :text "01234567"))
    (assert-error error (limn/excursion:narrow-to-region 6 3)
                  "start > end signals error")))

(deftest excursion-d1-narrow-negative-clamps-to-zero
  "narrow-to-region -3 5 → narrow-start clamp 到 0。"
  (with-excursion-ctx ((b :id "d1n" :text "abcdef"))
    (limn/excursion:narrow-to-region -3 5)
    (assert-eql 0 (limn/excursion:point-min) "negative clamped to 0")))

(deftest excursion-d1-widen-when-not-narrowed-noop
  "沒 narrow 時 widen → no-op、不 error。"
  (with-excursion-ctx ((b :id "d1o" :text "abc"))
    (assert-no-error (limn/excursion:widen) "widen when not narrowed")
    (assert-eql 0 (limn/excursion:point-min) "point-min still 0")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §E. Buffer lifecycle wrappers
;;; ─────────────────────────────────────────────────────────────────────────

(deftest excursion-e1-buffer-list-includes-registered
  "buffer-list 含目前所有註冊 buffer。"
  (with-excursion-ctx ((b1 :id "e1a-A") (b2 :id "e1a-B"))
    (let ((ids (mapcar (lambda (b) (mmbuf32-id b))
                       (limn/excursion:buffer-list))))
      (assert-contains "e1a-A" ids "list contains A")
      (assert-contains "e1a-B" ids "list contains B"))))

(deftest excursion-e1-get-buffer-by-id
  "get-buffer 給 buffer-id → 回 buffer object。"
  (with-excursion-ctx ((b :id "e1b" :name "n"))
    (assert-eq b (limn/excursion:get-buffer "e1b")
               "get-buffer by id")))

(deftest excursion-e1-get-buffer-by-name
  "get-buffer 給 buffer-name → 回 buffer object。"
  (with-excursion-ctx ((b :id "e1c-id" :name "by-name-e1c"))
    (assert-eq b (limn/excursion:get-buffer "by-name-e1c")
               "get-buffer by name")))

(deftest excursion-e1-get-buffer-missing-returns-nil
  "get-buffer 給不存在的 name → 回 nil（不 error）。"
  (assert-false (limn/excursion:get-buffer "never-existed-e1d")
                "missing get-buffer → nil"))

(deftest excursion-e1-get-buffer-create-returns-existing
  "get-buffer-create 同 name 第二次 → 回同一個 buffer（eq 相等）。"
  (with-excursion-ctx ((b :id "e1e-id" :name "scratch-e1e"))
    (let ((b2 (limn/excursion:get-buffer-create "scratch-e1e")))
      (assert-eq b b2
                 "second get-buffer-create returns same buffer"))))

(deftest excursion-e1-kill-buffer-removes-from-list
  "kill-buffer 後 buffer-list 不含它。"
  (with-excursion-ctx ((b1 :id "e1f-A") (b2 :id "e1f-B"))
    (limn/excursion:kill-buffer b2)
    (let ((ids (mapcar (lambda (b) (mmbuf32-id b))
                       (limn/excursion:buffer-list))))
      (assert-contains "e1f-A" ids "A still present")
      (assert-false (find "e1f-B" ids :test #'equal)
                    "B removed from list"))))

(deftest excursion-e1-kill-buffer-followed-by-get-returns-nil
  "kill-buffer 後 get-buffer 回 nil。"
  (with-excursion-ctx ((b :id "e1g"))
    (limn/excursion:kill-buffer b)
    (assert-false (limn/excursion:get-buffer "e1g")
                  "after kill: get-buffer = nil")))

(deftest excursion-e1-rename-buffer-changes-name
  "rename-buffer 後 buffer-name 回新名字、get-buffer 用新名字找得到。"
  (with-excursion-ctx ((b :id "e1h-id" :name "old-e1h"))
    (limn/excursion:with-current-buffer b
      (limn/excursion:rename-buffer "new-e1h"))
    (assert-equal "new-e1h" (limn/excursion:buffer-name b)
                  "name updated")
    (assert-eq b (limn/excursion:get-buffer "new-e1h")
               "lookup by new name works")
    (assert-false (limn/excursion:get-buffer "old-e1h")
                  "old name no longer resolves")))
