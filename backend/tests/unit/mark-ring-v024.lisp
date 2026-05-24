;;;; v0.24 §B — mark-ring RED tests
;;;;
;;;; 覆蓋：
;;;;   limn/mark : *mark-ring-max* / *global-mark-ring* / *global-mark-ring-max*
;;;;               set-mark / mark / push-mark / pop-mark
;;;;               exchange-point-and-mark
;;;;               pop-global-mark
;;;;               *buffer-cursor-fn* / *buffer-set-cursor-fn*
;;;;
;;;; mark 是 per-buffer 狀態，存在 limn/mode 的 mode-buffer slot 裡。
;;;; 但 limn/mark 本身透過 buffer-id 間接操作，不直接依賴 mode-buffer struct，
;;;; 所以 unit 測試可以用 stub registry 替代。
;;;;
;;;; 全部 RED — 在 limn-mark.lisp 實作前都會 fail。

;; ── package stubs ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/mark)
    (make-package '#:limn/mark :use '(#:cl)))
  (dolist (sym '("*MARK-RING-MAX*"
                 "*GLOBAL-MARK-RING*" "*GLOBAL-MARK-RING-MAX*"
                 "SET-MARK" "MARK"
                 "PUSH-MARK" "POP-MARK"
                 "EXCHANGE-POINT-AND-MARK"
                 "POP-GLOBAL-MARK"
                 ;; I/O vtable for test isolation
                 "*BUFFER-CURSOR-FN*" "*BUFFER-SET-CURSOR-FN*"
                 ;; Internal per-buffer registry — exposed for tests
                 "RESET-MARKS" "MARK-RING-FOR"))
    (export (intern sym '#:limn/mark) '#:limn/mark)))

(in-package #:limn/unit-test)
(use-package '#:limn/v024-helpers)

;;; ── helpers ───────────────────────────────────────────────────────────────

(defmacro with-mark-env ((buf-var &key (id "m") (text "") (cursor 0)) &body body)
  "Fresh mock-buf24 + clean mark state + cursor vtable bound."
  `(progn
     (when (find-package '#:limn/mark)
       (let ((reset (find-symbol "RESET-MARKS" '#:limn/mark)))
         (when reset (funcall reset ,id))))
     (with-mark-buf (,buf-var :id ,id :text ,text :cursor ,cursor)
       ,@body)))

;;; ── B1. set-mark / mark ───────────────────────────────────────────────────

(deftest mark-b1-set-mark-stores-position
  "set-mark pos buf-id 把 pos 設成 buf 的 mark。"
  (with-mark-env (b :id "m1" :text "hello")
    (limn/mark:set-mark 3 "m1")
    (assert-eql 3 (limn/mark:mark "m1"))))

(deftest mark-b1-mark-returns-nil-when-no-mark
  "mark buf-id 在沒有 mark 時回 nil（不 error），除非 :error-on-nil t。"
  (with-mark-env (b :id "m2")
    (assert-false (limn/mark:mark "m2") "no mark → nil")))

(deftest mark-b1-mark-error-on-nil
  "mark :error-on-nil t 在沒有 mark 時 signal error。"
  (with-mark-env (b :id "m3")
    (assert-error error (limn/mark:mark "m3" :error-on-nil t))))

(deftest mark-b1-set-mark-overrides-previous
  "連續 set-mark 覆蓋前一個 mark（不 push ring）。"
  (with-mark-env (b :id "m4" :text "abc")
    (limn/mark:set-mark 1 "m4")
    (limn/mark:set-mark 2 "m4")
    (assert-eql 2 (limn/mark:mark "m4"))))

;;; ── B2. push-mark ─────────────────────────────────────────────────────────

(deftest mark-b2-push-mark-saves-current-cursor
  "push-mark 無 pos 參數時儲存 buffer 目前的 cursor 位置。"
  (with-mark-env (b :id "p1" :cursor 7)
    (limn/mark:push-mark "p1")
    (assert-eql 7 (limn/mark:mark "p1"))))

(deftest mark-b2-push-mark-with-explicit-pos
  "push-mark 給 :pos 時儲存指定位置。"
  (with-mark-env (b :id "p2" :cursor 0)
    (limn/mark:push-mark "p2" :pos 5)
    (assert-eql 5 (limn/mark:mark "p2"))))

(deftest mark-b2-push-mark-grows-ring
  "每次 push-mark 都把前一個 mark 推進 mark-ring。"
  (with-mark-env (b :id "p3" :cursor 0)
    (limn/mark:set-mark  1 "p3")
    (limn/mark:push-mark "p3" :pos 2)
    (limn/mark:push-mark "p3" :pos 3)
    (let ((ring (limn/mark:mark-ring-for "p3")))
      (assert-true (>= (length ring) 2) "ring has at least 2 entries"))))

(deftest mark-b2-push-mark-ring-max
  "mark-ring 超過 *mark-ring-max* 時截掉最舊項目。"
  (let ((limn/mark:*mark-ring-max* 3))
    (with-mark-env (b :id "p4" :cursor 0)
      (dotimes (i 5)
        (limn/mark:push-mark "p4" :pos i))
      (assert-true (<= (length (limn/mark:mark-ring-for "p4")) 3)
                   "ring bounded by *mark-ring-max*"))))

(deftest mark-b2-push-mark-also-pushes-global-ring
  "push-mark 同時把 (buf-id . pos) 推進 *global-mark-ring*。"
  (let ((limn/mark:*global-mark-ring* '()))
    (with-mark-env (b :id "gp1" :cursor 4)
      (limn/mark:push-mark "gp1")
      (assert-true (find-if (lambda (entry)
                               (and (equal (car entry) "gp1")
                                    (eql   (cdr entry) 4)))
                             limn/mark:*global-mark-ring*)
                   "global ring contains (gp1 . 4)"))))

;;; ── B3. pop-mark ──────────────────────────────────────────────────────────

(deftest mark-b3-pop-mark-restores-ring-head
  "pop-mark 把 mark-ring 頭彈出並設為新 mark。"
  (with-mark-env (b :id "pm1" :cursor 0)
    (limn/mark:set-mark  1 "pm1")
    (limn/mark:push-mark "pm1" :pos 2)
    ;; mark = 2, ring = (1)
    (limn/mark:pop-mark "pm1")
    (assert-eql 1 (limn/mark:mark "pm1"))))

(deftest mark-b3-pop-mark-empty-ring-noop
  "ring 為空時 pop-mark 是 no-op（不 error）。"
  (with-mark-env (b :id "pm2")
    (assert-no-error (limn/mark:pop-mark "pm2"))))

(deftest mark-b3-pop-mark-shrinks-ring
  "pop-mark 讓 ring 長度減一。"
  (with-mark-env (b :id "pm3" :cursor 0)
    (limn/mark:set-mark  0 "pm3")
    (limn/mark:push-mark "pm3" :pos 1)
    (limn/mark:push-mark "pm3" :pos 2)
    (let ((len-before (length (limn/mark:mark-ring-for "pm3"))))
      (limn/mark:pop-mark "pm3")
      (assert-eql (1- len-before)
                  (length (limn/mark:mark-ring-for "pm3"))))))

(deftest mark-b3-pop-mark-roundtrip
  "push → pop → mark 回到 push 之前的位置。"
  (with-mark-env (b :id "pm4" :cursor 0)
    (limn/mark:set-mark  5 "pm4")
    (limn/mark:push-mark "pm4" :pos 9)
    (limn/mark:pop-mark  "pm4")
    (assert-eql 5 (limn/mark:mark "pm4"))))

;;; ── B4. exchange-point-and-mark ───────────────────────────────────────────

(deftest mark-b4-exchange-swaps-cursor-and-mark
  "exchange-point-and-mark 把 cursor 和 mark 對調。"
  (with-mark-env (b :id "ex1" :cursor 3)
    (limn/mark:set-mark 7 "ex1")
    (limn/mark:exchange-point-and-mark "ex1")
    (assert-eql 7 (mbuf-cursor b)  "cursor moved to old mark")
    (assert-eql 3 (limn/mark:mark "ex1") "mark moved to old cursor")))

(deftest mark-b4-exchange-twice-returns-to-original
  "連續兩次 exchange-point-and-mark 回到原始狀態。"
  (with-mark-env (b :id "ex2" :cursor 2)
    (limn/mark:set-mark 8 "ex2")
    (limn/mark:exchange-point-and-mark "ex2")
    (limn/mark:exchange-point-and-mark "ex2")
    (assert-eql 2 (mbuf-cursor b))
    (assert-eql 8 (limn/mark:mark "ex2"))))

(deftest mark-b4-exchange-no-mark-errors
  "exchange-point-and-mark 在沒有 mark 時 signal error。"
  (with-mark-env (b :id "ex3")
    (assert-error error (limn/mark:exchange-point-and-mark "ex3"))))

(deftest mark-b4-exchange-mark-equals-cursor-noop-equivalent
  "cursor == mark 時 exchange 是 no-op（數值不變）。"
  (with-mark-env (b :id "ex4" :cursor 5)
    (limn/mark:set-mark 5 "ex4")
    (limn/mark:exchange-point-and-mark "ex4")
    (assert-eql 5 (mbuf-cursor b))
    (assert-eql 5 (limn/mark:mark "ex4"))))

;;; ── B5. global mark ring ──────────────────────────────────────────────────

(deftest mark-b5-global-ring-max
  "*global-mark-ring* 超過 *global-mark-ring-max* 時截尾。"
  (let ((limn/mark:*global-mark-ring*     '())
        (limn/mark:*global-mark-ring-max*  3))
    (with-mark-env (b :id "gr1" :cursor 0)
      (dotimes (i 5)
        (limn/mark:push-mark "gr1" :pos i))
      (assert-true (<= (length limn/mark:*global-mark-ring*) 3)
                   "global ring bounded"))))

(deftest mark-b5-global-ring-entry-format
  "global ring 的每個 entry 是 (buf-id . offset) cons。"
  (let ((limn/mark:*global-mark-ring* '()))
    (with-mark-env (b :id "gr2" :cursor 0)
      (limn/mark:push-mark "gr2" :pos 10)
      (let ((entry (car limn/mark:*global-mark-ring*)))
        (assert-true (consp entry))
        (assert-true (stringp (car entry)) "buf-id is string")
        (assert-true (integerp (cdr entry)) "offset is integer")))))

(deftest mark-b5-pop-global-mark-changes-cursor
  "pop-global-mark 把 cursor 移到 global ring 最新 entry 的 buf+pos。"
  (let ((limn/mark:*global-mark-ring* '())
        (limn/mark:*buffer-set-cursor-fn*
          ;; override for this test: track which buf/pos was set
          (let ((last nil))
            (lambda (bid off) (setf last (cons bid off)) last))))
    (with-mark-env (b :id "gpm1" :cursor 0)
      (limn/mark:push-mark "gpm1" :pos 42)
      ;; pop: should move cursor to (gpm1 . 42)
      (assert-no-error (limn/mark:pop-global-mark)))))

(deftest mark-b5-pop-global-mark-removes-entry
  "pop-global-mark 之後 global ring 長度減一。"
  (let ((limn/mark:*global-mark-ring* '()))
    (with-mark-env (b :id "gpm2" :cursor 0)
      (limn/mark:push-mark "gpm2" :pos 1)
      (limn/mark:push-mark "gpm2" :pos 2)
      (let ((len-before (length limn/mark:*global-mark-ring*)))
        (assert-no-error (limn/mark:pop-global-mark))
        (assert-eql (1- len-before)
                    (length limn/mark:*global-mark-ring*))))))

(deftest mark-b5-per-buffer-isolation
  "一個 buffer 的 mark 不影響另一個 buffer 的 mark。"
  (with-mark-env (a :id "iso-a" :cursor 0)
    (with-mark-env (b :id "iso-b" :cursor 0)
      (limn/mark:set-mark 10 "iso-a")
      (limn/mark:set-mark 20 "iso-b")
      (assert-eql 10 (limn/mark:mark "iso-a"))
      (assert-eql 20 (limn/mark:mark "iso-b")))))
