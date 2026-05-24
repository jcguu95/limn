;;;; v0.24 §C — registers RED tests
;;;;
;;;; 覆蓋：
;;;;   limn/register : *register-alist*
;;;;                   set-register / get-register
;;;;                   point-to-register / jump-to-register
;;;;                   copy-to-register / insert-register
;;;;                   window-configuration-to-register
;;;;                   register-read-with-preview / list-registers
;;;;
;;;; 全部 RED — 在 limn-register.lisp 實作前都會 fail。

;; ── package stubs ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/register)
    (make-package '#:limn/register :use '(#:cl)))
  (dolist (sym '("*REGISTER-ALIST*"
                 "SET-REGISTER" "GET-REGISTER"
                 "POINT-TO-REGISTER" "JUMP-TO-REGISTER"
                 "COPY-TO-REGISTER" "INSERT-REGISTER"
                 "WINDOW-CONFIGURATION-TO-REGISTER"
                 "REGISTER-READ-WITH-PREVIEW"
                 "LIST-REGISTERS"
                 ;; I/O vtable for test isolation
                 "*BUFFER-CURSOR-FN*"
                 "*BUFFER-SET-CURSOR-FN*"
                 "*BUFFER-TEXT-FN*"
                 "*BUFFER-INSERT-FN*"))
    (export (intern sym '#:limn/register) '#:limn/register)))

(in-package #:limn/unit-test)
(use-package '#:limn/v024-helpers)

;;; ── helpers ───────────────────────────────────────────────────────────────

(defmacro with-register-env (&body body)
  "Reset *register-alist* to empty for each test."
  `(let ((limn/register:*register-alist* '()))
     ,@body))

(defmacro with-register-buf ((buf-var &key (id "reg") (text "") (cursor 0))
                              &body body)
  "mock-buf24 + wire register's I/O vtable to it. Falls through to the
   previously-bound vtable so nested with-register-buf forms compose."
  `(with-kill-buf (,buf-var :id ,id :text ,text :cursor ,cursor)
     (let* ((prev-cursor limn/register:*buffer-cursor-fn*)
            (prev-set    limn/register:*buffer-set-cursor-fn*)
            (prev-text   limn/register:*buffer-text-fn*)
            (prev-insert limn/register:*buffer-insert-fn*))
       (let ((limn/register:*buffer-cursor-fn*
               (lambda (bid)
                 (if (equal bid ,id)
                     (mbuf-cursor ,buf-var)
                     (funcall prev-cursor bid))))
             (limn/register:*buffer-set-cursor-fn*
               (lambda (bid off)
                 (if (equal bid ,id)
                     (setf (mbuf-cursor ,buf-var) off)
                     (funcall prev-set bid off))))
             (limn/register:*buffer-text-fn*
               (lambda (bid start end)
                 (if (equal bid ,id)
                     (subseq (mbuf-text ,buf-var) start end)
                     (funcall prev-text bid start end))))
             (limn/register:*buffer-insert-fn*
               (lambda (bid offset str)
                 (if (equal bid ,id)
                     (mbuf-insert-at! ,buf-var offset str)
                     (funcall prev-insert bid offset str)))))
         ,@body))))

;;; ── C1. set-register / get-register ──────────────────────────────────────

(deftest register-c1-set-and-get
  "set-register 儲存、get-register 讀回。"
  (with-register-env
    (limn/register:set-register #\a '(string . "hello"))
    (assert-equal '(string . "hello")
                  (limn/register:get-register #\a))))

(deftest register-c1-get-nil-for-unknown
  "未設定的 register 回 nil、不 error。"
  (with-register-env
    (assert-false (limn/register:get-register #\z)
                  "unknown register → nil")))

(deftest register-c1-set-overrides-previous
  "同一 key 重複 set-register 覆蓋前值。"
  (with-register-env
    (limn/register:set-register #\b '(string . "first"))
    (limn/register:set-register #\b '(string . "second"))
    (assert-equal '(string . "second")
                  (limn/register:get-register #\b))))

(deftest register-c1-multiple-keys-independent
  "不同 key 的 register 互不干擾。"
  (with-register-env
    (limn/register:set-register #\x '(number . 10))
    (limn/register:set-register #\y '(number . 20))
    (assert-equal 10 (cdr (limn/register:get-register #\x)))
    (assert-equal 20 (cdr (limn/register:get-register #\y)))))

(deftest register-c1-list-registers-returns-alist
  "list-registers 回 register alist 副本。"
  (with-register-env
    (limn/register:set-register #\p '(string . "p-val"))
    (let ((lst (limn/register:list-registers)))
      (assert-true (listp lst) "returns a list")
      (assert-true (find #\p lst :key #'car)
                   "alist contains key #\\p"))))

;;; ── C2. text register (copy-to-register / insert-register) ───────────────

(deftest register-c2-copy-to-register-stores-string
  "copy-to-register 把 buf 片段存成 (string . str)。"
  (with-register-env
    (with-register-buf (b :id "rt" :text "hello world" :cursor 0)
      (limn/register:copy-to-register #\t 0 5 "rt")
      (let ((val (limn/register:get-register #\t)))
        (assert-true (consp val) "value is a cons")
        (assert-equal 'string (car val) "type is string")
        (assert-equal "hello" (cdr val) "content matches")))))

(deftest register-c2-insert-register-to-buffer
  "insert-register 把 string register 插入 buffer。"
  (with-register-env
    (with-register-buf (b :id "ri" :text "world" :cursor 0)
      (limn/register:set-register #\r '(string . "hello "))
      (limn/register:insert-register #\r "ri")
      (assert-true (search "hello " (mbuf-text b))
                   "inserted text appears in buffer"))))

(deftest register-c2-insert-nil-register-errors
  "insert-register 對空 register signal error。"
  (with-register-env
    (with-register-buf (b :id "rie" :text "" :cursor 0)
      (assert-error error
                    (limn/register:insert-register #\q "rie")))))

(deftest register-c2-copy-empty-range
  "copy-to-register start==end 儲存空字串。"
  (with-register-env
    (with-register-buf (b :id "re" :text "abc" :cursor 0)
      (limn/register:copy-to-register #\e 2 2 "re")
      (assert-equal "" (cdr (limn/register:get-register #\e))))))

;;; ── C3. position register (point-to-register / jump-to-register) ─────────

(deftest register-c3-point-to-register-saves-cursor
  "point-to-register 把當前 cursor 存成 position register。"
  (with-register-env
    (with-register-buf (b :id "rp" :text "abcde" :cursor 3)
      (limn/register:point-to-register #\m "rp")
      (let ((val (limn/register:get-register #\m)))
        (assert-true (consp val))
        (assert-equal 'position (car val))
        (assert-eql 3 (cddr val) "offset stored correctly")))))

(deftest register-c3-jump-to-register-moves-cursor
  "jump-to-register 把 cursor 移到 position register 的 offset。"
  (with-register-env
    (with-register-buf (b :id "rj" :text "abcde" :cursor 0)
      (limn/register:set-register #\j (cons 'position (cons "rj" 4)))
      (limn/register:jump-to-register #\j)
      (assert-eql 4 (mbuf-cursor b) "cursor moved to stored offset"))))

(deftest register-c3-jump-nil-register-errors
  "jump-to-register 對空 register signal error。"
  (with-register-env
    (assert-error error (limn/register:jump-to-register #\z))))

(deftest register-c3-different-bufs-independent
  "不同 buffer 的 position register 互不干擾。"
  (with-register-env
    (with-register-buf (a :id "ra1" :text "aaa" :cursor 1)
      (with-register-buf (b :id "ra2" :text "bbb" :cursor 2)
        (limn/register:point-to-register #\1 "ra1")
        (limn/register:point-to-register #\2 "ra2")
        (let ((v1 (limn/register:get-register #\1))
              (v2 (limn/register:get-register #\2)))
          (assert-equal "ra1" (cadr v1))
          (assert-equal "ra2" (cadr v2))
          (assert-eql 1 (cddr v1))
          (assert-eql 2 (cddr v2)))))))

;;; ── C4. window-configuration register ────────────────────────────────────

(deftest register-c4-window-config-stored
  "window-configuration-to-register 存 window-config type。"
  (with-register-env
    (limn/register:window-configuration-to-register #\w)
    (let ((val (limn/register:get-register #\w)))
      (assert-true (consp val) "value is cons")
      (assert-equal "WINDOW-CONFIG" (symbol-name (car val))
                    "type is window-config"))))

(deftest register-c4-jump-window-config-no-error
  "jump-to-register 對 window-config 不 error（opaque restore）。"
  (with-register-env
    (limn/register:window-configuration-to-register #\v)
    (assert-no-error (limn/register:jump-to-register #\v))))

;;; ── C5. edge cases ────────────────────────────────────────────────────────

(deftest register-c5-overwrite-same-key
  "同 key 連存 5 次、最後值正確。"
  (with-register-env
    (dotimes (i 5)
      (limn/register:set-register #\k (cons 'number i)))
    (assert-eql 4 (cdr (limn/register:get-register #\k)))))

(deftest register-c5-zero-length-text
  "copy-to-register 0-length range 儲存空字串不 error。"
  (with-register-env
    (with-register-buf (b :id "rz" :text "abc" :cursor 0)
      (assert-no-error (limn/register:copy-to-register #\0 1 1 "rz"))
      (assert-equal "" (cdr (limn/register:get-register #\0))))))

(deftest register-c5-symbol-key
  "key 是 symbol（不是字元）不 error。"
  (with-register-env
    (assert-no-error
      (limn/register:set-register :my-reg '(string . "sym-key")))
    (assert-equal "sym-key"
                  (cdr (limn/register:get-register :my-reg)))))

(deftest register-c5-list-registers-empty
  "list-registers 在空 alist 時回 nil 或空 list。"
  (with-register-env
    (let ((lst (limn/register:list-registers)))
      (assert-true (or (null lst) (listp lst))
                   "empty registers returns nil or empty list"))))
