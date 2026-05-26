;;;; v0.36 — Indent system + current-column unit tests (RED)
;;;;
;;;; 覆蓋 SPEC §v0.36 §B (indent 系統) + §C (current-column 字寬 awareness)：
;;;;
;;;;   §B  indent-to / move-to-column / back-to-indentation / indent-region /
;;;;       indent-rigidly / indent-relative / indent-line-function / indent-
;;;;       for-tab-command / newline-and-indent；buffer-local *tab-width*
;;;;       *indent-tabs-mode* *fill-column*.
;;;;
;;;;   §C  char-display-width / current-column。ASCII = 1, TAB = 動態,
;;;;       CJK = 2, emoji = 2, control = 2 (fixed), newline/CR = 0。
;;;;
;;;; 依賴：v0.30 buffer-local vars (透過 limn/local)、v0.32 *current-buffer*
;;;; (透過 limn/excursion，soft-resolved)。實作走 vtable pattern 跟 v0.34
;;;; regex / v0.32 excursion 對齊。
;;;;
;;;; 全部 RED — 在 limn-indent.lisp 實作前都會 fail。

;; ── package stub ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/indent)
    (make-package '#:limn/indent :use '(#:cl)))
  (dolist (sym '(;; §C 字寬
                 "CHAR-DISPLAY-WIDTH"
                 "CURRENT-COLUMN"
                 ;; §B indent core
                 "INDENT-TO"
                 "MOVE-TO-COLUMN"
                 "BACK-TO-INDENTATION"
                 "INDENT-REGION"
                 "INDENT-RIGIDLY"
                 "INDENT-RELATIVE"
                 "INDENT-FOR-TAB-COMMAND"
                 "NEWLINE-AND-INDENT"
                 ;; buffer-local vars (cl-user-interned)
                 "*TAB-WIDTH*"
                 "*INDENT-TABS-MODE*"
                 "*FILL-COLUMN*"
                 "*INDENT-LINE-FUNCTION*"
                 ;; vtable hooks
                 "*BUFFER-TEXT-FN*"
                 "*BUFFER-INSERT-FN*"
                 "*BUFFER-DELETE-FN*"
                 "*POINT-FN*"
                 "*SET-POINT-FN*"
                 "*BUFFER-TEXT-LEN-FN*"))
    (export (intern sym '#:limn/indent) '#:limn/indent)))

(in-package #:limn/unit-test)

;;; ── mock buffer infrastructure ────────────────────────────────────────────
;;;
;;; Same shape as mbuf34: full text + point + length, but mutation runs
;;; through %insert / %delete so indent-to / move-to-column changes show
;;; up in mbuf36-text.

(defstruct (mbuf36
             (:conc-name mbuf36-)
             (:constructor make-mbuf36 (&key (id "ib") (text "") (point 0))))
  id
  (text "" :type string)
  (point 0 :type integer))

(defun mbuf36-len (b) (length (mbuf36-text b)))

(defvar *i36-buffers* (make-hash-table :test 'equal))

(defun mbuf36-get (bid) (gethash bid *i36-buffers*))

;;; Vtable adapters.
(defun i36-text-fn (bid)
  (let ((b (mbuf36-get bid))) (if b (mbuf36-text b) "")))

(defun i36-point-fn (bid)
  (let ((b (mbuf36-get bid))) (if b (mbuf36-point b) 0)))

(defun i36-set-point-fn (bid off)
  (let ((b (mbuf36-get bid)))
    (when b (setf (mbuf36-point b) off))))

(defun i36-text-len-fn (bid)
  (let ((b (mbuf36-get bid))) (if b (mbuf36-len b) 0)))

(defun i36-insert-fn (bid off str)
  (let ((b (mbuf36-get bid)))
    (when b
      (let* ((t0 (mbuf36-text b))
             (pre (subseq t0 0 off))
             (post (subseq t0 off)))
        (setf (mbuf36-text b) (concatenate 'string pre str post))
        ;; If point was at or after off, shift it.
        (when (>= (mbuf36-point b) off)
          (incf (mbuf36-point b) (length str)))))))

(defun i36-delete-fn (bid from to)
  (let ((b (mbuf36-get bid)))
    (when b
      (let* ((t0 (mbuf36-text b))
             (pre (subseq t0 0 from))
             (post (subseq t0 to)))
        (setf (mbuf36-text b) (concatenate 'string pre post))
        (let ((p (mbuf36-point b)))
          (cond ((<= p from) nil)
                ((>= p to) (decf (mbuf36-point b) (- to from)))
                (t (setf (mbuf36-point b) from))))))))

(defmacro with-i36-ctx ((&rest buf-specs) &body body)
  "Each BUF-SPEC: (VAR &key id text point).
   Wires limn/indent vtable, binds *current-buffer* (excursion + local)
   to the first buffer's id when those packages exist."
  (let* ((first-spec (car buf-specs))
         (first-var  (car first-spec))
         (vars  (mapcar #'car buf-specs))
         (kwargs (mapcar #'cdr buf-specs))
         (ids   (gensym "IDS"))
         (ipkg  (gensym "IPKG"))
         (xpkg  (gensym "XPKG"))
         (lpkg  (gensym "LPKG"))
         (pairs (gensym "PAIRS"))
         (xpairs (gensym "XPAIRS"))
         (lpairs (gensym "LPAIRS"))
         (live  (gensym "LIVE")))
    (declare (ignorable first-var))
    `(let* (,@(loop for v in vars
                    for kw in kwargs
                    collect `(,v (make-mbuf36 ,@kw)))
            (,ids (list ,@(loop for v in vars collect `(mbuf36-id ,v))))
            (,ipkg (find-package '#:limn/indent))
            (,xpkg (find-package '#:limn/excursion))
            (,lpkg (find-package '#:limn/local)))
       (dolist (b (list ,@vars))
         (setf (gethash (mbuf36-id b) *i36-buffers*) b))
       (unwind-protect
            (let* ((,pairs
                     (when ,ipkg
                       (list
                        (cons (find-symbol "*BUFFER-TEXT-FN*"     ,ipkg)
                              #'i36-text-fn)
                        (cons (find-symbol "*BUFFER-INSERT-FN*"   ,ipkg)
                              #'i36-insert-fn)
                        (cons (find-symbol "*BUFFER-DELETE-FN*"   ,ipkg)
                              #'i36-delete-fn)
                        (cons (find-symbol "*POINT-FN*"           ,ipkg)
                              #'i36-point-fn)
                        (cons (find-symbol "*SET-POINT-FN*"       ,ipkg)
                              #'i36-set-point-fn)
                        (cons (find-symbol "*BUFFER-TEXT-LEN-FN*" ,ipkg)
                              #'i36-text-len-fn))))
                   (,xpairs
                     (when ,xpkg
                       (list
                        (cons (find-symbol "*CURRENT-BUFFER*" ,xpkg)
                              (mbuf36-id ,first-var)))))
                   (,lpairs
                     (when ,lpkg
                       (list
                        (cons (find-symbol "*CURRENT-BUFFER-ID*" ,lpkg)
                              (mbuf36-id ,first-var)))))
                   (,live (remove-if (lambda (p) (null (car p)))
                                     (append ,pairs ,xpairs ,lpairs))))
              (progv (mapcar #'car ,live) (mapcar #'cdr ,live)
                ,@body))
         (dolist (id ,ids) (remhash id *i36-buffers*))
         ;; Wipe per-buffer locals so the next test starts clean.
         (when (find-package '#:limn/local)
           (let ((reset (find-symbol "RESET-BUFFER-LOCALS" '#:limn/local)))
             (when (and reset (fboundp reset))
               (dolist (id ,ids) (funcall reset id)))))))))

(defun setq-local-via-local (sym value buf-id)
  "Soft-set a buffer-local var; no-op if limn/local missing."
  (let ((pkg (find-package '#:limn/local)))
    (when pkg
      (let ((fn (find-symbol "SET-BUFFER-LOCAL-VALUE" pkg)))
        (when (and fn (fboundp fn))
          (funcall fn sym value buf-id))))))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §C.1 char-display-width (12 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest indent-c-char-width-ascii-letter
  "ASCII printable letter → 1"
  (assert-eql 1 (limn/indent:char-display-width #\a)
              "'a' width = 1"))

(deftest indent-c-char-width-ascii-digit
  "ASCII digit → 1"
  (assert-eql 1 (limn/indent:char-display-width #\0)
              "'0' width = 1"))

(deftest indent-c-char-width-ascii-symbol
  "ASCII printable symbol → 1"
  (assert-eql 1 (limn/indent:char-display-width #\~)
              "'~' width = 1"))

(deftest indent-c-char-width-space
  "Space (' ') → 1 (printable ASCII)"
  (assert-eql 1 (limn/indent:char-display-width #\Space)
              "space width = 1"))

(deftest indent-c-char-width-newline-zero
  "Newline → 0"
  (assert-eql 0 (limn/indent:char-display-width #\Newline)
              "newline width = 0"))

(deftest indent-c-char-width-cr-zero
  "Carriage Return → 0"
  (assert-eql 0 (limn/indent:char-display-width #\Return)
              "CR width = 0"))

(deftest indent-c-char-width-tab-col-0-default
  "TAB at column 0, default tab-width=8 → 8"
  (assert-eql 8 (limn/indent:char-display-width #\Tab 0)
              "TAB at col 0 = 8 spaces to next stop"))

(deftest indent-c-char-width-tab-col-5
  "TAB at column 5, tab-width=8 → 3 (5→8)"
  (assert-eql 3 (limn/indent:char-display-width #\Tab 5)
              "TAB at col 5 = 3 spaces"))

(deftest indent-c-char-width-tab-col-8-edge
  "TAB at column 8, tab-width=8 → 8 (8→16, jump full width)"
  (assert-eql 8 (limn/indent:char-display-width #\Tab 8)
              "TAB at col 8 = 8 (next stop is 16)"))

(deftest indent-c-char-width-cjk-han
  "CJK Han '中' → 2"
  (assert-eql 2 (limn/indent:char-display-width (code-char #x4E2D))
              "中 width = 2"))

(deftest indent-c-char-width-cjk-kana
  "Hiragana 'あ' → 2"
  (assert-eql 2 (limn/indent:char-display-width (code-char #x3042))
              "あ width = 2"))

(deftest indent-c-char-width-control
  "Other control char → 2 (fixed per SPEC §C)"
  (assert-eql 2 (limn/indent:char-display-width (code-char 1))
              "control char (^A) width = 2"))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §C.2 current-column (10 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest indent-c-current-column-empty
  "Empty buffer at point 0 → column 0"
  (with-i36-ctx ((b :id "cc-empty" :text "" :point 0))
    (assert-eql 0 (limn/indent:current-column)
                "empty → 0")))

(deftest indent-c-current-column-ascii-eol
  "Pure ASCII line 'hello|' → 5"
  (with-i36-ctx ((b :id "cc-ascii" :text "hello" :point 5))
    (assert-eql 5 (limn/indent:current-column)
                "after 'hello' = 5")))

(deftest indent-c-current-column-ascii-middle
  "ASCII line 'hello' point at 2 → 2"
  (with-i36-ctx ((b :id "cc-mid" :text "hello" :point 2))
    (assert-eql 2 (limn/indent:current-column)
                "at offset 2 = column 2")))

(deftest indent-c-current-column-after-tab-default
  "Line '\\tabc' with point at offset 1 (after TAB), tab-width=8 → 8"
  (with-i36-ctx ((b :id "cc-tab" :text (format nil "~Cabc" #\Tab) :point 1))
    (assert-eql 8 (limn/indent:current-column)
                "after one TAB at tab-width=8 → col 8")))

(deftest indent-c-current-column-after-tab-mid
  "'\\tabc' point at offset 3 (after TAB + 'ab') → 10"
  (with-i36-ctx ((b :id "cc-tab2" :text (format nil "~Cabc" #\Tab) :point 3))
    (assert-eql 10 (limn/indent:current-column)
                "TAB(8) + 'a'(1) + 'b'(1) = 10")))

(deftest indent-c-current-column-cjk
  "Mixed 'a中b' point at end → 4 (1+2+1)"
  (with-i36-ctx ((b :id "cc-cjk"
                    :text (concatenate 'string "a" (string (code-char #x4E2D)) "b")
                    :point 3))
    (assert-eql 4 (limn/indent:current-column)
                "a + 中(2) + b = column 4")))

(deftest indent-c-current-column-newline-resets
  "Line 2 of 'xx\\nyyy' point at end (offset 6) → 3 (column counts from line start, not buffer)"
  (with-i36-ctx ((b :id "cc-nl"
                    :text (format nil "xx~Cyyy" #\Newline)
                    :point 6))
    (assert-eql 3 (limn/indent:current-column)
                "second line ends at column 3")))

(deftest indent-c-current-column-at-newline-itself
  "Point sitting on the newline: column = chars-on-line-so-far"
  (with-i36-ctx ((b :id "cc-onnl"
                    :text (format nil "abc~Cdef" #\Newline)
                    :point 3))
    (assert-eql 3 (limn/indent:current-column)
                "point at newline offset = col 3")))

(deftest indent-c-current-column-line-start
  "Beginning of a non-first line → 0"
  (with-i36-ctx ((b :id "cc-bol"
                    :text (format nil "abc~Cdef" #\Newline)
                    :point 4))
    (assert-eql 0 (limn/indent:current-column)
                "right after newline = col 0")))

(deftest indent-c-current-column-respects-buffer-local-tab-width
  "Set buffer-local *tab-width*=4, then '\\t|' → 4 (not 8)"
  (with-i36-ctx ((b :id "cc-tw4" :text (string #\Tab) :point 1))
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user) 4 "cc-tw4")
    (assert-eql 4 (limn/indent:current-column)
                "TAB with tab-width=4 → col 4")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §B.1 indent-to (10 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest indent-b-indent-to-spaces-only
  "indent-to 5 from col 0 with indent-tabs-mode=nil → 5 spaces"
  (with-i36-ctx ((b :id "it-sp" :text "" :point 0))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "it-sp")
    (limn/indent:indent-to 5)
    (assert-equal "     " (mbuf36-text b)
                  "5 spaces inserted")))

(deftest indent-b-indent-to-one-tab
  "indent-to 8 from col 0 with tabs-mode=t, tab-width=8 → '\\t'"
  (with-i36-ctx ((b :id "it-1tab" :text "" :point 0))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) t "it-1tab")
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user) 8 "it-1tab")
    (limn/indent:indent-to 8)
    (assert-equal (string #\Tab) (mbuf36-text b)
                  "single TAB inserted")))

(deftest indent-b-indent-to-tab-plus-spaces
  "indent-to 10 with tabs-mode=t, tab-width=8 → '\\t  ' (TAB + 2 SPC)"
  (with-i36-ctx ((b :id "it-mix" :text "" :point 0))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) t "it-mix")
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user) 8 "it-mix")
    (limn/indent:indent-to 10)
    (assert-equal (format nil "~C  " #\Tab) (mbuf36-text b)
                  "TAB + 2 spaces")))

(deftest indent-b-indent-to-no-op-if-already-past
  "Already at col >= target → no-op (no extra chars inserted)"
  (with-i36-ctx ((b :id "it-noop" :text "abcdef" :point 6))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "it-noop")
    (limn/indent:indent-to 3)
    (assert-equal "abcdef" (mbuf36-text b)
                  "no insertion when already past col 3")))

(deftest indent-b-indent-to-from-mid-line
  "At col 4 ('abcd|'), indent-to 8 with tabs-mode=nil → 'abcd    '"
  (with-i36-ctx ((b :id "it-mid" :text "abcd" :point 4))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "it-mid")
    (limn/indent:indent-to 8)
    (assert-equal "abcd    " (mbuf36-text b)
                  "4 spaces added to reach col 8")))

(deftest indent-b-indent-to-minimum-arg
  "indent-to COL MINIMUM: when at col 6, indent-to 4 :minimum 2 still inserts 2 spaces"
  (with-i36-ctx ((b :id "it-min" :text "abcdef" :point 6))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "it-min")
    (limn/indent:indent-to 4 2)
    (assert-equal "abcdef  " (mbuf36-text b)
                  "minimum=2 forces 2 spaces even when past col")))

(deftest indent-b-indent-to-respects-tabs-mode-flip
  "Same target col, different tabs-mode → different output"
  (with-i36-ctx ((b1 :id "it-fa" :text "" :point 0))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "it-fa")
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user) 8 "it-fa")
    (limn/indent:indent-to 8)
    (assert-equal "        " (mbuf36-text b1)
                  "tabs-mode=nil → 8 spaces")))

(deftest indent-b-indent-to-zero
  "indent-to 0 from col 0 → no-op"
  (with-i36-ctx ((b :id "it-zero" :text "" :point 0))
    (limn/indent:indent-to 0)
    (assert-equal "" (mbuf36-text b)
                  "no insertion")))

(deftest indent-b-indent-to-returns-target-column
  "indent-to returns the column after insertion"
  (with-i36-ctx ((b :id "it-ret" :text "" :point 0))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "it-ret")
    (assert-eql 5 (limn/indent:indent-to 5)
                "returns final column")))

(deftest indent-b-indent-to-after-tab
  "Buffer '\\t' (col 8), indent-to 12 tabs-mode=nil → '\\t    '"
  (with-i36-ctx ((b :id "it-aftab" :text (string #\Tab) :point 1))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "it-aftab")
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user) 8 "it-aftab")
    (limn/indent:indent-to 12)
    (assert-equal (format nil "~C    " #\Tab) (mbuf36-text b)
                  "4 spaces appended after TAB")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §B.2 move-to-column (8 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest indent-b-move-to-column-basic
  "Plain ASCII move-to-column 3 → point at offset 3, col 3"
  (with-i36-ctx ((b :id "mc-basic" :text "abcdef" :point 0))
    (limn/indent:move-to-column 3)
    (assert-eql 3 (mbuf36-point b) "point = 3")))

(deftest indent-b-move-to-column-returns-actual-column
  "move-to-column returns the column actually arrived at"
  (with-i36-ctx ((b :id "mc-ret" :text "abcdef" :point 0))
    (assert-eql 3 (limn/indent:move-to-column 3)
                "returns 3")))

(deftest indent-b-move-to-column-past-eol-no-force
  "move-to-column 99 on 'abc' without FORCE → stops at end-of-line"
  (with-i36-ctx ((b :id "mc-eol" :text "abc" :point 0))
    (limn/indent:move-to-column 99)
    (assert-eql 3 (mbuf36-point b) "point clamps to EOL")
    (assert-equal "abc" (mbuf36-text b) "no insertion")))

(deftest indent-b-move-to-column-past-eol-with-force
  "move-to-column 6 :force t on 'abc' → buffer 'abc   ', point at 6"
  (with-i36-ctx ((b :id "mc-force" :text "abc" :point 0))
    (limn/indent:move-to-column 6 t)
    (assert-equal "abc   " (mbuf36-text b)
                  "3 spaces appended")
    (assert-eql 6 (mbuf36-point b) "point at 6")))

(deftest indent-b-move-to-column-into-tab-no-force
  "On '\\tabc' move-to-column 3 without FORCE → falls inside TAB → point at 0 (Emacs convention: cannot split → stop at start of TAB)"
  (with-i36-ctx ((b :id "mc-tab" :text (format nil "~Cabc" #\Tab) :point 0))
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user) 8 "mc-tab")
    (limn/indent:move-to-column 3)
    (assert-eql 0 (mbuf36-point b)
                "stops at start of TAB when target falls inside")))

(deftest indent-b-move-to-column-into-tab-with-force
  "On '\\tabc' move-to-column 3 :force t → TAB splits into 3 SPC + 5 SPC, point at 3"
  (with-i36-ctx ((b :id "mc-tabf" :text (format nil "~Cabc" #\Tab) :point 0))
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user) 8 "mc-tabf")
    (limn/indent:move-to-column 3 t)
    (assert-equal "        abc" (mbuf36-text b)
                  "TAB expanded into 8 spaces")
    (assert-eql 3 (mbuf36-point b)
                "point at col 3")))

(deftest indent-b-move-to-column-cjk-not-into
  "On '中文a' move-to-column 1 → cannot split CJK char, lands at col 0 or 2 (per impl: 0)"
  (with-i36-ctx ((b :id "mc-cjk"
                    :text (concatenate 'string
                                       (string (code-char #x4E2D))
                                       (string (code-char #x6587))
                                       "a")
                    :point 0))
    (limn/indent:move-to-column 1)
    (assert-eql 0 (mbuf36-point b)
                "stops at start of CJK when target falls inside")))

(deftest indent-b-move-to-column-multi-line
  "Multi-line: move-to-column 2 only moves within the current line."
  (with-i36-ctx ((b :id "mc-ml"
                    :text (format nil "abcdef~Cghij" #\Newline)
                    :point 7))                  ; offset 7 = start of line 2
    (limn/indent:move-to-column 2)
    (assert-eql 9 (mbuf36-point b)
                "moves 2 chars into line 2 only")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §B.3 back-to-indentation (4 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest indent-b-back-to-indentation-spaces
  "'   foo' point at 6 → back-to-indentation → point at 3"
  (with-i36-ctx ((b :id "bi-sp" :text "   foo" :point 6))
    (limn/indent:back-to-indentation)
    (assert-eql 3 (mbuf36-point b)
                "back-to first non-whitespace")))

(deftest indent-b-back-to-indentation-mixed-tab-space
  "'\\t  foo' point at end → back-to-indentation → first non-whitespace"
  (with-i36-ctx ((b :id "bi-mix" :text (format nil "~C  foo" #\Tab) :point 6))
    (limn/indent:back-to-indentation)
    (assert-eql 3 (mbuf36-point b)
                "skips TAB and 2 spaces")))

(deftest indent-b-back-to-indentation-blank-line
  "All-whitespace line → end-of-line (Emacs convention)"
  (with-i36-ctx ((b :id "bi-blank" :text "    " :point 4))
    (limn/indent:back-to-indentation)
    (assert-eql 4 (mbuf36-point b)
                "lands at EOL on blank line")))

(deftest indent-b-back-to-indentation-second-line
  "Second line '\\tfoo' from end → first non-whitespace of that line"
  (with-i36-ctx ((b :id "bi-l2"
                    :text (format nil "xxx~C~Cfoo" #\Newline #\Tab)
                    :point 8))
    (limn/indent:back-to-indentation)
    (assert-eql 5 (mbuf36-point b)
                "after newline(4) + TAB(5) → at 'f' offset 5")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §B.4 indent-region / indent-rigidly (8 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest indent-b-indent-rigidly-positive
  "indent-rigidly 0..end 2 on 'a\\nb\\nc' → '  a\\n  b\\n  c'"
  (with-i36-ctx ((b :id "ir-pos"
                    :text (format nil "a~Cb~Cc" #\Newline #\Newline)
                    :point 0))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "ir-pos")
    (limn/indent:indent-rigidly 0 (mbuf36-len b) 2)
    (assert-equal (format nil "  a~C  b~C  c" #\Newline #\Newline)
                  (mbuf36-text b)
                  "2-col indent each line")))

(deftest indent-b-indent-rigidly-negative
  "indent-rigidly with negative count strips leading whitespace"
  (with-i36-ctx ((b :id "ir-neg"
                    :text (format nil "  a~C  b" #\Newline)
                    :point 0))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "ir-neg")
    (limn/indent:indent-rigidly 0 (mbuf36-len b) -2)
    (assert-equal (format nil "a~Cb" #\Newline) (mbuf36-text b)
                  "leading 2 spaces removed")))

(deftest indent-b-indent-rigidly-skip-blank
  "Blank lines untouched by indent-rigidly"
  (with-i36-ctx ((b :id "ir-blank"
                    :text (format nil "a~C~Cb" #\Newline #\Newline)
                    :point 0))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "ir-blank")
    (limn/indent:indent-rigidly 0 (mbuf36-len b) 2)
    ;; First and third line indented, blank line stays blank.
    (assert-equal (format nil "  a~C~C  b" #\Newline #\Newline)
                  (mbuf36-text b)
                  "blank line untouched")))

(deftest indent-b-indent-rigidly-partial-range
  "indent-rigidly across only lines 2..3, line 1 untouched"
  (with-i36-ctx ((b :id "ir-part"
                    :text (format nil "a~Cb~Cc" #\Newline #\Newline)
                    :point 0))
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "ir-part")
    ;; Range covers line 2 and 3 (offsets 2..5).
    (limn/indent:indent-rigidly 2 5 2)
    (assert-equal (format nil "a~C  b~C  c" #\Newline #\Newline)
                  (mbuf36-text b)
                  "only lines 2 & 3 indented")))

(deftest indent-b-indent-region-uses-line-fn
  "indent-region calls *indent-line-function* on each line"
  (with-i36-ctx ((b :id "ire-fn"
                    :text (format nil "a~Cb" #\Newline)
                    :point 0))
    ;; Install a custom indent-line-function that always inserts ">"
    ;; at the line start. After indent-region, both lines should be ">"-
    ;; prefixed.
    (let* ((sym (intern "*INDENT-LINE-FUNCTION*" :cl-user))
           (custom (lambda ()
                     (let ((bid "ire-fn"))
                       (funcall #'i36-insert-fn bid
                                (funcall #'i36-point-fn bid) ">")))))
      (setq-local-via-local sym custom "ire-fn")
      (limn/indent:indent-region 0 (mbuf36-len b))
      (assert-true (and (search ">a" (mbuf36-text b))
                        (search ">b" (mbuf36-text b)))
                   "both lines got '>' prefix"))))

(deftest indent-b-indent-region-empty-no-op
  "indent-region on empty buffer → no error, no change"
  (with-i36-ctx ((b :id "ire-empty" :text "" :point 0))
    (assert-no-error (limn/indent:indent-region 0 0)
                     "no error")
    (assert-equal "" (mbuf36-text b) "still empty")))

(deftest indent-b-indent-region-single-line
  "indent-region on single line uses indent-line-function"
  (with-i36-ctx ((b :id "ire-1l" :text "foo" :point 0))
    (let ((sym (intern "*INDENT-LINE-FUNCTION*" :cl-user))
          (custom (lambda ()
                    (funcall #'i36-insert-fn "ire-1l"
                             (funcall #'i36-point-fn "ire-1l") "X"))))
      (setq-local-via-local sym custom "ire-1l")
      (limn/indent:indent-region 0 3)
      (assert-true (search "Xfoo" (mbuf36-text b))
                   "X prefixed"))))

(deftest indent-b-indent-rigidly-zero-noop
  "indent-rigidly with count=0 → no change"
  (with-i36-ctx ((b :id "ir-0"
                    :text (format nil "a~Cb" #\Newline)
                    :point 0))
    (limn/indent:indent-rigidly 0 3 0)
    (assert-equal (format nil "a~Cb" #\Newline) (mbuf36-text b)
                  "no change with count=0")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §B.5 buffer-local variables interaction (4 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest indent-b-buffer-local-tab-width-isolation
  "tab-width set in buf-A doesn't affect buf-B"
  (with-i36-ctx ((bA :id "bl-A" :text (string #\Tab) :point 1)
                 (bB :id "bl-B" :text (string #\Tab) :point 1))
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user) 4 "bl-A")
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user) 8 "bl-B")
    ;; current-column uses *current-buffer* = bl-A
    (assert-eql 4 (limn/indent:current-column)
                "buf-A sees tab-width=4")))

(deftest indent-b-defvar-tab-width-default
  "*tab-width* default value is 8"
  (let ((sym (find-symbol "*TAB-WIDTH*" :cl-user)))
    (assert-true (and sym (boundp sym))
                 "*tab-width* is bound")
    (assert-eql 8 (symbol-value sym)
                "default = 8")))

(deftest indent-b-defvar-indent-tabs-mode-default
  "*indent-tabs-mode* default = t (Emacs default)"
  (let ((sym (find-symbol "*INDENT-TABS-MODE*" :cl-user)))
    (assert-true (and sym (boundp sym))
                 "*indent-tabs-mode* is bound")
    (assert-eq t (symbol-value sym)
               "default = t")))

(deftest indent-b-defvar-fill-column-default
  "*fill-column* default = 70 (plumbed for future use)"
  (let ((sym (find-symbol "*FILL-COLUMN*" :cl-user)))
    (assert-true (and sym (boundp sym))
                 "*fill-column* is bound")
    (assert-eql 70 (symbol-value sym)
                "default = 70")))

;;; ─────────────────────────────────────────────────────────────────────────
;;; §B.6 indent-relative + indent-for-tab-command (4 tests)
;;; ─────────────────────────────────────────────────────────────────────────

(deftest indent-b-indent-relative-copies-prev-line
  "indent-relative on a line: jumps to next indent stop of previous line"
  (with-i36-ctx ((b :id "irl-1"
                    :text (format nil "  foo~C" #\Newline)
                    :point 6))                   ; col 0 of line 2
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user) nil "irl-1")
    (limn/indent:indent-relative)
    (assert-true (>= (mbuf36-point b) 8)
                 "indented to align with prev line content")))

(deftest indent-b-indent-relative-first-line-no-op
  "indent-relative on first line is a no-op (no prev line)"
  (with-i36-ctx ((b :id "irl-first" :text "foo" :point 0))
    (assert-no-error (limn/indent:indent-relative)
                     "no error")))

(deftest indent-b-indent-for-tab-command-calls-line-fn
  "TAB at indent zero: indent-for-tab-command calls *indent-line-function*"
  (with-i36-ctx ((b :id "ift-1" :text "foo" :point 0))
    (let ((called (cons nil nil)))
      (setq-local-via-local (intern "*INDENT-LINE-FUNCTION*" :cl-user)
                            (lambda () (setf (car called) t))
                            "ift-1")
      (limn/indent:indent-for-tab-command)
      (assert-true (car called) "line-fn invoked"))))

(deftest indent-b-indent-for-tab-command-falls-back-when-noop
  "v0.37 Phase F regression: when *indent-line-function* leaves the
   buffer unchanged (e.g. indent-relative on a first line with no
   prior indent to copy), indent-for-tab-command falls back to
   inserting one tab-stop worth of indent at point.  Without the
   fallback, Tab on a brand-new empty file did nothing, breaking
   v036-tab-key-text-mode."
  (with-i36-ctx ((b :id "ift-fb" :text "foo" :point 0))
    (setq-local-via-local (intern "*INDENT-LINE-FUNCTION*" :cl-user)
                          (lambda () nil)   ; explicit no-op
                          "ift-fb")
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user)
                          t "ift-fb")
    (limn/indent:indent-for-tab-command)
    (assert-equal (concatenate 'string (string #\Tab) "foo")
                  (mbuf36-text b)
                  "literal tab inserted when indent-tabs-mode = t")))

(deftest indent-b-indent-for-tab-command-fallback-uses-spaces
  "Same fallback path, indent-tabs-mode nil → spaces of width
   *tab-width*."
  (with-i36-ctx ((b :id "ift-fb2" :text "bar" :point 0))
    (setq-local-via-local (intern "*INDENT-LINE-FUNCTION*" :cl-user)
                          (lambda () nil) "ift-fb2")
    (setq-local-via-local (intern "*INDENT-TABS-MODE*" :cl-user)
                          nil "ift-fb2")
    (setq-local-via-local (intern "*TAB-WIDTH*" :cl-user)
                          4 "ift-fb2")
    (limn/indent:indent-for-tab-command)
    (assert-equal "    bar" (mbuf36-text b)
                  "tab-width spaces inserted when indent-tabs-mode = nil")))

(deftest indent-b-newline-and-indent-inserts-and-indents
  "newline-and-indent: insert \\n then call indent-line-function"
  (with-i36-ctx ((b :id "nai-1" :text "foo" :point 3))
    (let ((called (cons nil nil)))
      (setq-local-via-local (intern "*INDENT-LINE-FUNCTION*" :cl-user)
                            (lambda () (setf (car called) t))
                            "nai-1")
      (limn/indent:newline-and-indent)
      (assert-true (search (string #\Newline) (mbuf36-text b))
                   "newline inserted")
      (assert-true (car called) "line-fn invoked after newline"))))
