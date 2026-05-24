;;;; v0.31 §A — syntax tables RED tests (~60 tests)
;;;;
;;;; 覆蓋：
;;;;   limn/syntax : make-syntax-table / copy-syntax-table
;;;;                 modify-syntax-entry / char-syntax
;;;;                 with-syntax-table / *standard-syntax-table*
;;;;                 *current-syntax-table*
;;;;   limn/text-nav : *syntax-table-fn* vtable
;;;;                   skip-syntax-forward / skip-syntax-backward
;;;;                   forward-word / backward-word / kill-word
;;;;                   (syntax-aware 版本)
;;;;
;;;; Syntax class keywords（SPEC v0.31）：
;;;;   :word :symbol :whitespace :open :close :string :escape :punct
;;;;   :comment-start :comment-end
;;;;
;;;; CLASS-STR 對應（skip-syntax-forward / backward 用）：
;;;;   "w" = :word    "_" = :symbol    "-" = :whitespace
;;;;   "(" = :open    ")" = :close     "\"" = :string
;;;;   "\\" = :escape  "." = :punct    "<" = :comment-start
;;;;   ">" = :comment-end
;;;;
;;;; 全部 RED — 在 limn-syntax.lisp 實作前都會 fail。

;; ── package stubs ─────────────────────────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/syntax)
    (make-package '#:limn/syntax :use '(#:cl)))
  (dolist (sym '("MAKE-SYNTAX-TABLE"
                 "COPY-SYNTAX-TABLE"
                 "MODIFY-SYNTAX-ENTRY"
                 "CHAR-SYNTAX"
                 "WITH-SYNTAX-TABLE"
                 "*STANDARD-SYNTAX-TABLE*"
                 "*CURRENT-SYNTAX-TABLE*"))
    (export (intern sym '#:limn/syntax) '#:limn/syntax))

  ;; limn/text-nav — augment with new v0.31 symbols (package already exists
  ;; from run-unit.lisp impl loading; these just ensure the exports are known
  ;; in standalone loads)
  (unless (find-package '#:limn/text-nav)
    (make-package '#:limn/text-nav :use '(#:cl)))
  (dolist (sym '("*SYNTAX-TABLE-FN*"
                 "SKIP-SYNTAX-FORWARD"
                 "SKIP-SYNTAX-BACKWARD"))
    (export (intern sym '#:limn/text-nav) '#:limn/text-nav)))

(in-package #:limn/unit-test)

;;; ── helpers ───────────────────────────────────────────────────────────────

(defmacro with-syntax-pkg (&body body)
  "Skip body (pass silently) when limn/syntax hasn't been loaded yet."
  `(let ((pkg (find-package '#:limn/syntax)))
     (if (null pkg)
         (format t "  (skipped: limn/syntax not loaded)~%")
         (progn ,@body))))

(defun %syn (name &rest args)
  "Call limn/syntax:NAME with ARGS."
  (let ((pkg (find-package '#:limn/syntax)))
    (when pkg
      (apply (symbol-function (find-symbol name pkg)) args))))

(defun %standard-syntax-table ()
  (let ((pkg (find-package '#:limn/syntax)))
    (when pkg
      (symbol-value (find-symbol "*STANDARD-SYNTAX-TABLE*" pkg)))))

;;; ── §A1. make-syntax-table — standard defaults ───────────────────────────

(deftest syn-a1-word-lower
  "*standard-syntax-table* : 'a' → :word"
  (with-syntax-pkg
    (assert-eq :word (%syn "CHAR-SYNTAX" #\a (%standard-syntax-table)))))

(deftest syn-a1-word-upper
  "*standard-syntax-table* : 'Z' → :word"
  (with-syntax-pkg
    (assert-eq :word (%syn "CHAR-SYNTAX" #\Z (%standard-syntax-table)))))

(deftest syn-a1-word-digit
  "*standard-syntax-table* : '5' → :word"
  (with-syntax-pkg
    (assert-eq :word (%syn "CHAR-SYNTAX" #\5 (%standard-syntax-table)))))

(deftest syn-a1-space-whitespace
  "*standard-syntax-table* : SPACE → :whitespace"
  (with-syntax-pkg
    (assert-eq :whitespace (%syn "CHAR-SYNTAX" #\Space (%standard-syntax-table)))))

(deftest syn-a1-tab-whitespace
  "*standard-syntax-table* : TAB → :whitespace"
  (with-syntax-pkg
    (assert-eq :whitespace (%syn "CHAR-SYNTAX" #\Tab (%standard-syntax-table)))))

(deftest syn-a1-newline-whitespace
  "*standard-syntax-table* : NEWLINE → :whitespace"
  (with-syntax-pkg
    (assert-eq :whitespace (%syn "CHAR-SYNTAX" #\Newline (%standard-syntax-table)))))

(deftest syn-a1-open-paren
  "*standard-syntax-table* : '(' → :open"
  (with-syntax-pkg
    (assert-eq :open (%syn "CHAR-SYNTAX" #\( (%standard-syntax-table)))))

(deftest syn-a1-close-paren
  "*standard-syntax-table* : ')' → :close"
  (with-syntax-pkg
    (assert-eq :close (%syn "CHAR-SYNTAX" #\) (%standard-syntax-table)))))

(deftest syn-a1-open-bracket
  "*standard-syntax-table* : '[' → :open"
  (with-syntax-pkg
    (assert-eq :open (%syn "CHAR-SYNTAX" #\[ (%standard-syntax-table)))))

(deftest syn-a1-close-bracket
  "*standard-syntax-table* : ']' → :close"
  (with-syntax-pkg
    (assert-eq :close (%syn "CHAR-SYNTAX" #\] (%standard-syntax-table)))))

(deftest syn-a1-double-quote-string
  "*standard-syntax-table* : '\"' → :string"
  (with-syntax-pkg
    (assert-eq :string (%syn "CHAR-SYNTAX" #\" (%standard-syntax-table)))))

(deftest syn-a1-backslash-escape
  "*standard-syntax-table* : '\\\\' → :escape"
  (with-syntax-pkg
    (assert-eq :escape (%syn "CHAR-SYNTAX" #\\ (%standard-syntax-table)))))

(deftest syn-a1-dash-punct
  "*standard-syntax-table* : '-' → :punct (not :word; lisp-mode overrides this)"
  (with-syntax-pkg
    (assert-eq :punct (%syn "CHAR-SYNTAX" #\- (%standard-syntax-table)))))

(deftest syn-a1-comma-punct
  "*standard-syntax-table* : ',' → :punct"
  (with-syntax-pkg
    (assert-eq :punct (%syn "CHAR-SYNTAX" #\, (%standard-syntax-table)))))

;;; ── §A2. make-syntax-table — fresh / copy ────────────────────────────────

(deftest syn-a2-make-fresh-inherits-standard
  "make-syntax-table without parent inherits *standard-syntax-table*"
  (with-syntax-pkg
    (let ((t2 (%syn "MAKE-SYNTAX-TABLE")))
      (assert-eq :word (%syn "CHAR-SYNTAX" #\a t2)))))

(deftest syn-a2-make-with-explicit-parent
  "make-syntax-table with parent: 'a' inherits :word from parent"
  (with-syntax-pkg
    (let* ((parent (%standard-syntax-table))
           (t2 (%syn "MAKE-SYNTAX-TABLE" parent)))
      (assert-eq :word (%syn "CHAR-SYNTAX" #\a t2)))))

(deftest syn-a2-copy-syntax-table
  "copy-syntax-table makes an independent copy; changing copy doesn't touch original"
  (with-syntax-pkg
    (let* ((orig (%standard-syntax-table))
           (copy (%syn "COPY-SYNTAX-TABLE" orig)))
      ;; mutate the copy
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :word copy)
      ;; original unchanged
      (assert-eq :punct (%syn "CHAR-SYNTAX" #\- orig))
      ;; copy changed
      (assert-eq :word  (%syn "CHAR-SYNTAX" #\- copy)))))

;;; ── §A3. modify-syntax-entry / char-syntax ────────────────────────────────

(deftest syn-a3-modify-and-read
  "modify-syntax-entry then char-syntax round-trip"
  (with-syntax-pkg
    (let ((t1 (%syn "MAKE-SYNTAX-TABLE")))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol t1)
      (assert-eq :symbol (%syn "CHAR-SYNTAX" #\- t1)))))

(deftest syn-a3-modify-others-unaffected
  "modify-syntax-entry on '-' doesn't change 'a'"
  (with-syntax-pkg
    (let ((t1 (%syn "MAKE-SYNTAX-TABLE")))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol t1)
      (assert-eq :word (%syn "CHAR-SYNTAX" #\a t1)))))

(deftest syn-a3-modify-to-whitespace
  "modify-syntax-entry: change '#\\.' to :whitespace"
  (with-syntax-pkg
    (let ((t1 (%syn "MAKE-SYNTAX-TABLE")))
      (%syn "MODIFY-SYNTAX-ENTRY" #\. :whitespace t1)
      (assert-eq :whitespace (%syn "CHAR-SYNTAX" #\. t1)))))

(deftest syn-a3-modify-ascii-boundary
  "modify-syntax-entry: char #\\DEL (127) treated as ASCII slot"
  (with-syntax-pkg
    (let ((t1 (%syn "MAKE-SYNTAX-TABLE")))
      (%syn "MODIFY-SYNTAX-ENTRY" (code-char 127) :word t1)
      (assert-eq :word (%syn "CHAR-SYNTAX" (code-char 127) t1)))))

;;; ── §A4. parent inheritance ───────────────────────────────────────────────

(deftest syn-a4-child-overrides-parent
  "child table overrides '-': parent sees :punct, child sees :symbol"
  (with-syntax-pkg
    (let* ((parent (%standard-syntax-table))
           (child  (%syn "MAKE-SYNTAX-TABLE" parent)))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol child)
      (assert-eq :punct  (%syn "CHAR-SYNTAX" #\- parent))
      (assert-eq :symbol (%syn "CHAR-SYNTAX" #\- child)))))

(deftest syn-a4-child-inherits-unmodified
  "child inherits 'a' as :word from parent (unmodified entry)"
  (with-syntax-pkg
    (let* ((parent (%standard-syntax-table))
           (child  (%syn "MAKE-SYNTAX-TABLE" parent)))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol child)
      (assert-eq :word (%syn "CHAR-SYNTAX" #\a child)))))

(deftest syn-a4-two-level-inheritance
  "grandchild inherits from child inherits from standard"
  (with-syntax-pkg
    (let* ((grandparent (%standard-syntax-table))
           (parent (%syn "MAKE-SYNTAX-TABLE" grandparent))
           (child  (%syn "MAKE-SYNTAX-TABLE" parent)))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol parent)
      ;; child inherits :symbol for '-' via parent chain
      (assert-eq :symbol (%syn "CHAR-SYNTAX" #\- child))
      ;; grandparent still has :punct
      (assert-eq :punct  (%syn "CHAR-SYNTAX" #\- grandparent)))))

(deftest syn-a4-child-can-shadow-parent-again
  "child shadows what parent already overrode"
  (with-syntax-pkg
    (let* ((parent (%syn "MAKE-SYNTAX-TABLE" (%standard-syntax-table)))
           (child  (%syn "MAKE-SYNTAX-TABLE" parent)))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol parent)
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :word   child)
      (assert-eq :symbol (%syn "CHAR-SYNTAX" #\- parent))
      (assert-eq :word   (%syn "CHAR-SYNTAX" #\- child)))))

;;; ── §A5. with-syntax-table dynamic binding ───────────────────────────────

(deftest syn-a5-with-syntax-table-body-sees-new
  "with-syntax-table: body reads the overriding table"
  (with-syntax-pkg
    (let* ((t1 (%syn "MAKE-SYNTAX-TABLE"))
           (syn-pkg (find-package '#:limn/syntax))
           (cur-sym (find-symbol "*CURRENT-SYNTAX-TABLE*" syn-pkg)))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol t1)
      (funcall (symbol-function (find-symbol "WITH-SYNTAX-TABLE" syn-pkg))
               t1
               (lambda ()
                 (assert-eq :symbol
                            (%syn "CHAR-SYNTAX" #\-
                                  (symbol-value cur-sym))))))))

(deftest syn-a5-with-syntax-table-restored-after
  "with-syntax-table: *current-syntax-table* restored after body"
  (with-syntax-pkg
    (let* ((t1 (%syn "MAKE-SYNTAX-TABLE"))
           (syn-pkg (find-package '#:limn/syntax))
           (cur-sym (find-symbol "*CURRENT-SYNTAX-TABLE*" syn-pkg))
           (before (symbol-value cur-sym)))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol t1)
      (funcall (symbol-function (find-symbol "WITH-SYNTAX-TABLE" syn-pkg))
               t1
               (lambda () nil))
      (assert-eq before (symbol-value cur-sym)))))

(deftest syn-a5-with-syntax-table-fn-form
  "with-syntax-table as function: body thunk sees overriding table, restored after"
  (with-syntax-pkg
    (let* ((t1 (%syn "MAKE-SYNTAX-TABLE"))
           (result nil))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol t1)
      ;; Call as (with-syntax-table table thunk)
      (%syn "WITH-SYNTAX-TABLE" t1
            (lambda () (setf result (%syn "CHAR-SYNTAX" #\-))))
      (assert-eq :symbol result "inside thunk sees :symbol")
      ;; after: standard table restored → '-' is :punct
      (assert-eq :punct (%syn "CHAR-SYNTAX" #\-
                              (%standard-syntax-table))))))

;;; ── §A6. forward-word with syntax table ──────────────────────────────────
;;;
;;; In these tests we wire limn/text-nav:*syntax-table-fn* to return a
;;; specific table for the mock buffer. "lisp-table" has '-' as :symbol so
;;; forward-word treats "foo-bar" as one word. "standard-table" keeps '-' as
;;; :punct so "foo-bar" is two words.

(defstruct (syn-nav-mock (:constructor %make-syn-nav-mock (&key id text cursor)))
  id (text "" :type string) (cursor 0 :type integer))

(defmacro with-syn-nav-buf ((var &key (id "b") (text "") (cursor 0) table) &body body)
  "Like with-nav-buf but also wires limn/text-nav:*syntax-table-fn* to TABLE."
  (let ((pkg  (gensym "PKG"))
        (mock (gensym "MOCK")))
    `(let* ((,mock (%make-syn-nav-mock :id ,id :text ,text :cursor ,cursor))
            (,pkg  (find-package '#:limn/text-nav)))
       (if (null ,pkg)
           (progn ,@body)
           (let* ((syms (list
                         (find-symbol "*BUFFER-TEXT-FN*"       ,pkg)
                         (find-symbol "*BUFFER-CURSOR-FN*"     ,pkg)
                         (find-symbol "*BUFFER-SET-CURSOR-FN*" ,pkg)
                         (find-symbol "*BUFFER-INSERT-FN*"     ,pkg)
                         (find-symbol "*BUFFER-DELETE-FN*"     ,pkg)
                         (find-symbol "*KILL-NEW-FN*"          ,pkg)
                         (find-symbol "*SYNTAX-TABLE-FN*"      ,pkg)))
                  (vals (list
                         (lambda (b) (declare (ignore b)) (syn-nav-mock-text ,mock))
                         (lambda (b) (declare (ignore b)) (syn-nav-mock-cursor ,mock))
                         (lambda (b p) (declare (ignore b))
                           (setf (syn-nav-mock-cursor ,mock) p))
                         (lambda (b p s) (declare (ignore b))
                           (let ((tx (syn-nav-mock-text ,mock)))
                             (setf (syn-nav-mock-text ,mock)
                                   (concatenate 'string
                                                (subseq tx 0 p) s
                                                (subseq tx p)))))
                         (lambda (b f to) (declare (ignore b))
                           (let ((tx (syn-nav-mock-text ,mock)))
                             (setf (syn-nav-mock-text ,mock)
                                   (concatenate 'string
                                                (subseq tx 0 f)
                                                (subseq tx to)))))
                         (lambda (s) (declare (ignore s)))
                         ,(if table
                              `(lambda (b) (declare (ignore b)) ,table)
                              `(lambda (b) (declare (ignore b)) nil))))
                  (valid (remove nil syms)))
             (progv valid
                    (loop for s in syms for v in vals
                          when s collect v)
               (let ((,var ,mock))
                 ,@body)))))))

(deftest syn-a6-standard-table-foo-dash-bar-two-words
  "standard syntax table: 'foo-bar' → two forward-words (stop at '-')"
  (let* ((syn-pkg (find-package '#:limn/syntax))
         (std (when syn-pkg (%standard-syntax-table))))
    (with-syn-nav-buf (b :text "foo-bar" :cursor 0 :table std)
      (let ((fw (find-symbol "FORWARD-WORD" (find-package '#:limn/text-nav))))
        (when fw
          (funcall (symbol-function fw) (syn-nav-mock-id b))
          (assert-eql 3 (syn-nav-mock-cursor b) "first word ends at 3"))))))

(deftest syn-a6-lisp-table-foo-dash-bar-one-word
  "lisp-mode syntax table ('-' is :symbol): 'foo-bar' is one forward-word"
  (with-syntax-pkg
    (let* ((lisp-table (%syn "MAKE-SYNTAX-TABLE" (%standard-syntax-table))))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol lisp-table)
      (%syn "MODIFY-SYNTAX-ENTRY" #\? :symbol lisp-table)
      (with-syn-nav-buf (b :text "foo-bar baz" :cursor 0 :table lisp-table)
        (let ((fw (find-symbol "FORWARD-WORD" (find-package '#:limn/text-nav))))
          (when fw
            (funcall (symbol-function fw) (syn-nav-mock-id b))
            ;; "foo-bar" = 7 chars all :word or :symbol
            (assert-eql 7 (syn-nav-mock-cursor b) "foo-bar is one word in lisp-mode")))))))

(deftest syn-a6-lisp-table-question-mark-in-word
  "lisp-mode: 'done?' is one word ('?' is :symbol)"
  (with-syntax-pkg
    (let* ((lisp-table (%syn "MAKE-SYNTAX-TABLE" (%standard-syntax-table))))
      (%syn "MODIFY-SYNTAX-ENTRY" #\? :symbol lisp-table)
      (with-syn-nav-buf (b :text "done? yes" :cursor 0 :table lisp-table)
        (let ((fw (find-symbol "FORWARD-WORD" (find-package '#:limn/text-nav))))
          (when fw
            (funcall (symbol-function fw) (syn-nav-mock-id b))
            (assert-eql 5 (syn-nav-mock-cursor b) "done? = 5 chars")))))))

(deftest syn-a6-backward-word-lisp-table
  "lisp-mode: backward-word on 'foo-bar|' moves to 0"
  (with-syntax-pkg
    (let* ((lisp-table (%syn "MAKE-SYNTAX-TABLE" (%standard-syntax-table))))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol lisp-table)
      (with-syn-nav-buf (b :text "foo-bar" :cursor 7 :table lisp-table)
        (let ((bw (find-symbol "BACKWARD-WORD" (find-package '#:limn/text-nav))))
          (when bw
            (funcall (symbol-function bw) (syn-nav-mock-id b))
            (assert-eql 0 (syn-nav-mock-cursor b) "back to start of foo-bar")))))))

(deftest syn-a6-backward-word-standard-table
  "standard table: backward-word on 'foo-bar|' lands at 4 (start of 'bar')"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "foo-bar" :cursor 7 :table (%standard-syntax-table))
      (let ((bw (find-symbol "BACKWARD-WORD" (find-package '#:limn/text-nav))))
        (when bw
          (funcall (symbol-function bw) (syn-nav-mock-id b))
          (assert-eql 4 (syn-nav-mock-cursor b)))))))

(deftest syn-a6-kill-word-lisp-table
  "kill-word with lisp table: 'foo-bar baz' kills 'foo-bar'"
  (with-syntax-pkg
    (let* ((lisp-table (%syn "MAKE-SYNTAX-TABLE" (%standard-syntax-table))))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol lisp-table)
      (with-syn-nav-buf (b :text "foo-bar baz" :cursor 0 :table lisp-table)
        (let ((kw (find-symbol "KILL-WORD" (find-package '#:limn/text-nav))))
          (when kw
            (funcall (symbol-function kw) (syn-nav-mock-id b))
            (assert-equal " baz" (syn-nav-mock-text b)
                          "foo-bar removed")))))))

;;; ── §A7. CJK + non-BMP ────────────────────────────────────────────────────

(deftest syn-a7-cjk-word-by-default
  "CJK char 你 (U+4F60): standard table default → :word"
  (with-syntax-pkg
    (assert-eq :word (%syn "CHAR-SYNTAX" #\U+4F60 (%standard-syntax-table)))))

(deftest syn-a7-cjk-forward-word
  "forward-word on '你好世界' moves from 0 to 4"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "你好世界" :cursor 0 :table (%standard-syntax-table))
      (let ((fw (find-symbol "FORWARD-WORD" (find-package '#:limn/text-nav))))
        (when fw
          (funcall (symbol-function fw) (syn-nav-mock-id b))
          (assert-eql 4 (syn-nav-mock-cursor b)))))))

(deftest syn-a7-cjk-forward-word-mixed
  "forward-word on '你好 world' stops at space (offset 2)"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "你好 world" :cursor 0 :table (%standard-syntax-table))
      (let ((fw (find-symbol "FORWARD-WORD" (find-package '#:limn/text-nav))))
        (when fw
          (funcall (symbol-function fw) (syn-nav-mock-id b))
          (assert-eql 2 (syn-nav-mock-cursor b)))))))

(deftest syn-a7-non-bmp-emoji-word
  "Non-BMP U+1F600 (emoji): default → :word (chars > 127 default to :word)"
  (with-syntax-pkg
    (let ((c (code-char #x1F600)))
      (assert-eq :word (%syn "CHAR-SYNTAX" c (%standard-syntax-table))))))

(deftest syn-a7-modify-cjk-char
  "modify-syntax-entry on CJK char: change 你 to :punct"
  (with-syntax-pkg
    (let ((t1 (%syn "MAKE-SYNTAX-TABLE" (%standard-syntax-table))))
      (%syn "MODIFY-SYNTAX-ENTRY" #\U+4F60 :punct t1)
      (assert-eq :punct (%syn "CHAR-SYNTAX" #\U+4F60 t1))
      ;; others unaffected
      (assert-eq :word (%syn "CHAR-SYNTAX" #\U+597D t1)))))

;;; ── §A8. skip-syntax-forward / backward ──────────────────────────────────
;;;
;;; These are in limn/text-nav and use the buffer's syntax table.
;;; The vtable *buffer-text-fn* + *buffer-cursor-fn* + *buffer-set-cursor-fn*
;;; + *syntax-table-fn* must all be wired for the test to work.

(deftest syn-a8-skip-syntax-forward-word
  "skip-syntax-forward \"w\" skips word chars, stops at space"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "hello world" :cursor 0
                          :table (%standard-syntax-table))
      (let* ((nav-pkg (find-package '#:limn/text-nav))
             (ssf (find-symbol "SKIP-SYNTAX-FORWARD" nav-pkg)))
        (when ssf
          (funcall (symbol-function ssf) "w" (syn-nav-mock-id b))
          (assert-eql 5 (syn-nav-mock-cursor b) "stopped at space"))))))

(deftest syn-a8-skip-syntax-forward-whitespace
  "skip-syntax-forward \"-\" skips whitespace chars"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "   hello" :cursor 0
                          :table (%standard-syntax-table))
      (let* ((nav-pkg (find-package '#:limn/text-nav))
             (ssf (find-symbol "SKIP-SYNTAX-FORWARD" nav-pkg)))
        (when ssf
          (funcall (symbol-function ssf) "-" (syn-nav-mock-id b))
          (assert-eql 3 (syn-nav-mock-cursor b) "skipped 3 spaces"))))))

(deftest syn-a8-skip-syntax-forward-multi-class
  "skip-syntax-forward \"w_\" skips word AND symbol chars"
  (with-syntax-pkg
    (let* ((lisp-table (%syn "MAKE-SYNTAX-TABLE" (%standard-syntax-table))))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol lisp-table)
      (with-syn-nav-buf (b :text "foo-bar!" :cursor 0 :table lisp-table)
        (let* ((nav-pkg (find-package '#:limn/text-nav))
               (ssf (find-symbol "SKIP-SYNTAX-FORWARD" nav-pkg)))
          (when ssf
            (funcall (symbol-function ssf) "w_" (syn-nav-mock-id b))
            (assert-eql 7 (syn-nav-mock-cursor b) "stopped at !")))))))

(deftest syn-a8-skip-syntax-forward-at-end-noop
  "skip-syntax-forward at end of buffer: cursor stays at end"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "hi" :cursor 2 :table (%standard-syntax-table))
      (let* ((nav-pkg (find-package '#:limn/text-nav))
             (ssf (find-symbol "SKIP-SYNTAX-FORWARD" nav-pkg)))
        (when ssf
          (funcall (symbol-function ssf) "w" (syn-nav-mock-id b))
          (assert-eql 2 (syn-nav-mock-cursor b)))))))

(deftest syn-a8-skip-syntax-backward-word
  "skip-syntax-backward \"w\" from end of 'world' lands at start"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "world" :cursor 5 :table (%standard-syntax-table))
      (let* ((nav-pkg (find-package '#:limn/text-nav))
             (ssb (find-symbol "SKIP-SYNTAX-BACKWARD" nav-pkg)))
        (when ssb
          (funcall (symbol-function ssb) "w" (syn-nav-mock-id b))
          (assert-eql 0 (syn-nav-mock-cursor b)))))))

(deftest syn-a8-skip-syntax-backward-whitespace
  "skip-syntax-backward \"-\" from after trailing spaces"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "hi   " :cursor 5 :table (%standard-syntax-table))
      (let* ((nav-pkg (find-package '#:limn/text-nav))
             (ssb (find-symbol "SKIP-SYNTAX-BACKWARD" nav-pkg)))
        (when ssb
          (funcall (symbol-function ssb) "-" (syn-nav-mock-id b))
          (assert-eql 2 (syn-nav-mock-cursor b)))))))

(deftest syn-a8-skip-syntax-backward-at-start-noop
  "skip-syntax-backward at start of buffer: cursor stays at 0"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "hi" :cursor 0 :table (%standard-syntax-table))
      (let* ((nav-pkg (find-package '#:limn/text-nav))
             (ssb (find-symbol "SKIP-SYNTAX-BACKWARD" nav-pkg)))
        (when ssb
          (funcall (symbol-function ssb) "w" (syn-nav-mock-id b))
          (assert-eql 0 (syn-nav-mock-cursor b)))))))

;;; ── §A9. edge cases ───────────────────────────────────────────────────────

(deftest syn-a9-forward-word-empty-buffer
  "forward-word on empty buffer: cursor stays at 0"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "" :cursor 0 :table (%standard-syntax-table))
      (let ((fw (find-symbol "FORWARD-WORD" (find-package '#:limn/text-nav))))
        (when fw
          (assert-no-error (funcall (symbol-function fw) (syn-nav-mock-id b)))
          (assert-eql 0 (syn-nav-mock-cursor b)))))))

(deftest syn-a9-backward-word-empty-buffer
  "backward-word on empty buffer: cursor stays at 0"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "" :cursor 0 :table (%standard-syntax-table))
      (let ((bw (find-symbol "BACKWARD-WORD" (find-package '#:limn/text-nav))))
        (when bw
          (assert-no-error (funcall (symbol-function bw) (syn-nav-mock-id b)))
          (assert-eql 0 (syn-nav-mock-cursor b)))))))

(deftest syn-a9-forward-word-all-whitespace
  "forward-word on '   ': cursor moves to end (nothing to stop at)"
  (with-syntax-pkg
    (with-syn-nav-buf (b :text "   " :cursor 0 :table (%standard-syntax-table))
      (let ((fw (find-symbol "FORWARD-WORD" (find-package '#:limn/text-nav))))
        (when fw
          (funcall (symbol-function fw) (syn-nav-mock-id b))
          (assert-eql 3 (syn-nav-mock-cursor b)))))))

(deftest syn-a9-char-syntax-unknown-non-ascii-defaults-word
  "Non-ASCII char with no explicit entry: default :word (not :punct, not error)"
  (with-syntax-pkg
    (let ((t1 (%syn "MAKE-SYNTAX-TABLE")))
      ;; fresh table with no entries; should fall back to :word for letters/CJK
      (assert-eq :word (%syn "CHAR-SYNTAX" (code-char #x4e2d) t1)))))

(deftest syn-a9-modify-syntax-entry-idempotent
  "modify-syntax-entry called twice with same args: no error, correct value"
  (with-syntax-pkg
    (let ((t1 (%syn "MAKE-SYNTAX-TABLE")))
      (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol t1)
      (assert-no-error (%syn "MODIFY-SYNTAX-ENTRY" #\- :symbol t1))
      (assert-eq :symbol (%syn "CHAR-SYNTAX" #\- t1)))))

(deftest syn-a9-make-syntax-table-returns-new-object
  "Two make-syntax-table calls return distinct objects"
  (with-syntax-pkg
    (let ((t1 (%syn "MAKE-SYNTAX-TABLE"))
          (t2 (%syn "MAKE-SYNTAX-TABLE")))
      (assert-true (not (eq t1 t2))))))
