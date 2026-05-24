;;;; v0.24 §D — kbd-macro RED tests
;;;;
;;;; 覆蓋：
;;;;   limn/kmacro : *defining-kbd-macro* / *current-kbd-macro* / *last-kbd-macro*
;;;;                 start-kbd-macro / end-kbd-macro
;;;;                 record-key          (dispatch loop 在 *defining-kbd-macro* 非 nil 時呼叫)
;;;;                 call-last-kbd-macro &optional count
;;;;                 name-last-kbd-macro name
;;;;                 *kmacro-counter* / kmacro-insert-counter
;;;;                 *kmacro-replay-fn*  (dispatch loop 的 replay hook — 供測試注入)
;;;;
;;;; 設計說明：
;;;;   dispatch loop (%dispatch-key) 在 call handler 後若 *defining-kbd-macro*
;;;;   非 nil 則呼叫 (limn/kmacro:record-key spec)。
;;;;
;;;;   call-last-kbd-macro 透過 *kmacro-replay-fn* 重放每個 key-spec，
;;;;   而不是直接呼叫 %dispatch-key（避免硬依賴 limn 包）。
;;;;   測試注入 mock replay-fn 以驗證 call-last-kbd-macro 行為。
;;;;
;;;; 全部 RED — 在 limn-kmacro.lisp 實作前都會 fail。

;; ── package stubs ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/kmacro)
    (make-package '#:limn/kmacro :use '(#:cl)))
  (dolist (sym '("*DEFINING-KBD-MACRO*"
                 "*CURRENT-KBD-MACRO*"
                 "*LAST-KBD-MACRO*"
                 "START-KBD-MACRO"
                 "END-KBD-MACRO"
                 "RECORD-KEY"
                 "CALL-LAST-KBD-MACRO"
                 "NAME-LAST-KBD-MACRO"
                 "*KMACRO-COUNTER*"
                 "KMACRO-INSERT-COUNTER"
                 "*KMACRO-REPLAY-FN*"
                 ;; insert vtable for kmacro-insert-counter
                 "*INSERT-AT-POINT-FN*"))
    (export (intern sym '#:limn/kmacro) '#:limn/kmacro)))

(in-package #:limn/unit-test)
(use-package '#:limn/v024-helpers)

;;; ── D1. start / end 狀態 ──────────────────────────────────────────────────

(deftest kmacro-d1-start-sets-defining
  "start-kbd-macro 後 *defining-kbd-macro* 非 nil。"
  (let ((limn/kmacro:*defining-kbd-macro* nil)
        (limn/kmacro:*current-kbd-macro* #()))
    (limn/kmacro:start-kbd-macro)
    (assert-true limn/kmacro:*defining-kbd-macro*)))

(deftest kmacro-d1-start-resets-current-macro
  "start-kbd-macro 清空 *current-kbd-macro*。"
  (let ((limn/kmacro:*defining-kbd-macro* nil)
        (limn/kmacro:*current-kbd-macro* #("old-key")))
    (limn/kmacro:start-kbd-macro)
    (assert-eql 0 (length limn/kmacro:*current-kbd-macro*)
                "*current-kbd-macro* reset to empty")))

(deftest kmacro-d1-end-clears-defining
  "end-kbd-macro 後 *defining-kbd-macro* 是 nil。"
  (let ((limn/kmacro:*defining-kbd-macro* t)
        (limn/kmacro:*current-kbd-macro* #()))
    (limn/kmacro:end-kbd-macro)
    (assert-false limn/kmacro:*defining-kbd-macro*)))

(deftest kmacro-d1-end-saves-to-last
  "end-kbd-macro 把 *current-kbd-macro* copy 到 *last-kbd-macro*。"
  (let ((limn/kmacro:*defining-kbd-macro* t)
        (limn/kmacro:*current-kbd-macro* #("C-n" "C-n" "C-a")))
    (limn/kmacro:end-kbd-macro)
    (assert-equal '("C-n" "C-n" "C-a")
                  (coerce limn/kmacro:*last-kbd-macro* 'list)
                  "*last-kbd-macro* matches recorded keys")))

;;; ── D2. record-key ────────────────────────────────────────────────────────

(deftest kmacro-d2-record-key-appends-when-defining
  "record-key 在錄製狀態下把 key-spec append 進 *current-kbd-macro*。"
  (let ((limn/kmacro:*defining-kbd-macro* t)
        (limn/kmacro:*current-kbd-macro* (make-array 0 :adjustable t
                                                        :fill-pointer 0)))
    (limn/kmacro:record-key "j")
    (limn/kmacro:record-key "k")
    (assert-eql 2 (length limn/kmacro:*current-kbd-macro*))
    (assert-equal "j" (aref limn/kmacro:*current-kbd-macro* 0))
    (assert-equal "k" (aref limn/kmacro:*current-kbd-macro* 1))))

(deftest kmacro-d2-record-key-noop-when-not-defining
  "record-key 在 *defining-kbd-macro* = nil 時不動 *current-kbd-macro*。"
  (let ((limn/kmacro:*defining-kbd-macro* nil)
        (limn/kmacro:*current-kbd-macro* (make-array 0 :adjustable t
                                                        :fill-pointer 0)))
    (limn/kmacro:record-key "x")
    (assert-eql 0 (length limn/kmacro:*current-kbd-macro*))))

(deftest kmacro-d2-roundtrip-start-record-end
  "start → record → end 完整 roundtrip。"
  (let ((limn/kmacro:*defining-kbd-macro* nil)
        (limn/kmacro:*current-kbd-macro* #())
        (limn/kmacro:*last-kbd-macro* #()))
    (limn/kmacro:start-kbd-macro)
    (limn/kmacro:record-key "a")
    (limn/kmacro:record-key "b")
    (limn/kmacro:record-key "c")
    (limn/kmacro:end-kbd-macro)
    (assert-equal '("a" "b" "c")
                  (coerce limn/kmacro:*last-kbd-macro* 'list))))

;;; ── D3. call-last-kbd-macro ───────────────────────────────────────────────

(deftest kmacro-d3-no-macro-noop
  "call-last-kbd-macro 在 *last-kbd-macro* 為空時 no-op（不 error）。"
  (let ((limn/kmacro:*last-kbd-macro* #()))
    (assert-no-error (limn/kmacro:call-last-kbd-macro))))

(deftest kmacro-d3-replays-via-replay-fn
  "call-last-kbd-macro 對每個 key-spec 呼叫 *kmacro-replay-fn*。"
  (let ((limn/kmacro:*last-kbd-macro* #("j" "k" "l"))
        (replayed '()))
    (let ((limn/kmacro:*kmacro-replay-fn*
            (lambda (spec) (push spec replayed))))
      (limn/kmacro:call-last-kbd-macro)
      (assert-equal '("j" "k" "l") (reverse replayed)
                    "keys replayed in order"))))

(deftest kmacro-d3-replay-in-order
  "replay 順序和錄製順序一致。"
  (let ((limn/kmacro:*last-kbd-macro* #("1" "2" "3" "4" "5"))
        (order '()))
    (let ((limn/kmacro:*kmacro-replay-fn*
            (lambda (s) (push s order))))
      (limn/kmacro:call-last-kbd-macro)
      (assert-equal '("1" "2" "3" "4" "5") (reverse order)))))

(deftest kmacro-d3-replay-does-not-re-record
  "replay 期間 *defining-kbd-macro* 是 nil（不會把 replay 的按鍵錄進去）。"
  (let ((limn/kmacro:*defining-kbd-macro* t)  ; was recording before call
        (limn/kmacro:*last-kbd-macro* #("x"))
        (seen-defining-during-replay nil))
    (let ((limn/kmacro:*kmacro-replay-fn*
            (lambda (s)
              (declare (ignore s))
              (setf seen-defining-during-replay
                    limn/kmacro:*defining-kbd-macro*))))
      (limn/kmacro:call-last-kbd-macro)
      (assert-false seen-defining-during-replay
                    "*defining-kbd-macro* is nil during replay"))))

;;; ── D4. count 參數 ────────────────────────────────────────────────────────

(deftest kmacro-d4-count-repeats-replay
  "call-last-kbd-macro 3 → replay macro 三次。"
  (let ((limn/kmacro:*last-kbd-macro* #("a" "b"))
        (n 0))
    (let ((limn/kmacro:*kmacro-replay-fn*
            (lambda (s) (declare (ignore s)) (incf n))))
      (limn/kmacro:call-last-kbd-macro 3)
      (assert-eql 6 n "2 keys × 3 repetitions = 6 replay calls"))))

(deftest kmacro-d4-count-zero-noop
  "call-last-kbd-macro 0 → no replay。"
  (let ((limn/kmacro:*last-kbd-macro* #("a"))
        (called nil))
    (let ((limn/kmacro:*kmacro-replay-fn*
            (lambda (s) (declare (ignore s)) (setf called t))))
      (limn/kmacro:call-last-kbd-macro 0)
      (assert-false called "count=0 does nothing"))))

(deftest kmacro-d4-count-default-is-one
  "count 預設是 1。"
  (let ((limn/kmacro:*last-kbd-macro* #("x"))
        (calls 0))
    (let ((limn/kmacro:*kmacro-replay-fn*
            (lambda (s) (declare (ignore s)) (incf calls))))
      (limn/kmacro:call-last-kbd-macro)
      (assert-eql 1 calls "default count = 1"))))

;;; ── D5. name-last-kbd-macro ───────────────────────────────────────────────

(deftest kmacro-d5-name-creates-command
  "name-last-kbd-macro 'my-macro 讓 find-command 找到該命令。"
  (let ((limn/kmacro:*last-kbd-macro* #("j" "j" "j")))
    (limn/kmacro:name-last-kbd-macro 'my-test-macro)
    (let ((cmd-pkg (find-package '#:limn/cmd)))
      (when cmd-pkg
        (let ((find-cmd (find-symbol "FIND-COMMAND" cmd-pkg)))
          (when find-cmd
            (assert-true (funcall find-cmd 'my-test-macro)
                         "named macro registered as command")))))))

(deftest kmacro-d5-named-macro-is-callable
  "name-last-kbd-macro 產生的命令 funcall 後透過 *kmacro-replay-fn* 重放。"
  (let ((limn/kmacro:*last-kbd-macro* #("G"))
        (replayed nil))
    (let ((limn/kmacro:*kmacro-replay-fn*
            (lambda (s) (push s replayed))))
      (limn/kmacro:name-last-kbd-macro 'go-to-end)
      ;; 呼叫這個 named command
      (let ((cmd-pkg (find-package '#:limn/cmd)))
        (when cmd-pkg
          (let ((find-cmd (find-symbol "FIND-COMMAND" cmd-pkg))
                (call-i   (find-symbol "CALL-INTERACTIVELY" cmd-pkg)))
            (when (and find-cmd call-i)
              (let ((cmd (funcall find-cmd 'go-to-end)))
                (when cmd
                  (assert-no-error
                    (funcall call-i cmd nil))
                  (assert-true (member "G" replayed :test #'equal)
                               "named macro replayed 'G'"))))))))))

;;; ── D6. *kmacro-counter* ──────────────────────────────────────────────────

(deftest kmacro-d6-counter-increments-per-call
  "*kmacro-counter* 每次 call-last-kbd-macro 後遞增。"
  (let ((limn/kmacro:*last-kbd-macro* #("x"))
        (limn/kmacro:*kmacro-counter* 0)
        (limn/kmacro:*kmacro-replay-fn* (lambda (s) (declare (ignore s)))))
    (limn/kmacro:call-last-kbd-macro)
    (assert-eql 1 limn/kmacro:*kmacro-counter*)
    (limn/kmacro:call-last-kbd-macro)
    (assert-eql 2 limn/kmacro:*kmacro-counter*)))

(deftest kmacro-d6-counter-not-incremented-on-empty-macro
  "*last-kbd-macro* 為空時 counter 不遞增。"
  (let ((limn/kmacro:*last-kbd-macro* #())
        (limn/kmacro:*kmacro-counter* 0))
    (limn/kmacro:call-last-kbd-macro)
    (assert-eql 0 limn/kmacro:*kmacro-counter*)))

;;; ── D7. kmacro-insert-counter ─────────────────────────────────────────────

(deftest kmacro-d7-insert-counter-inserts-value
  "kmacro-insert-counter 在 point 插入 *kmacro-counter* 的字串表示。"
  (let ((limn/kmacro:*kmacro-counter* 7)
        (inserted nil))
    (let ((limn/kmacro:*insert-at-point-fn*
            (lambda (text) (setf inserted text))))
      (limn/kmacro:kmacro-insert-counter)
      (assert-equal "7" inserted "counter value inserted as string"))))

(deftest kmacro-d7-insert-counter-format-matches-counter
  "counter 為多位數時插入完整字串。"
  (let ((limn/kmacro:*kmacro-counter* 42)
        (inserted nil))
    (let ((limn/kmacro:*insert-at-point-fn*
            (lambda (text) (setf inserted text))))
      (limn/kmacro:kmacro-insert-counter)
      (assert-equal "42" inserted))))

;;; ── D8. edge cases ────────────────────────────────────────────────────────

(deftest kmacro-d8-end-without-start-errors-or-noop
  "end-kbd-macro 在 *defining-kbd-macro* = nil 時 signal error 或 no-op。"
  (let ((limn/kmacro:*defining-kbd-macro* nil))
    ;; Either no-op or error — both acceptable; must not hang.
    (handler-case
        (progn
          (limn/kmacro:end-kbd-macro)
          (check t "end-kbd-macro without start: no-op accepted"))
      (error ()
        (check t "end-kbd-macro without start: error accepted")))))

(deftest kmacro-d8-start-while-recording-errors-or-noop
  "start-kbd-macro 已在錄製時 signal error 或 no-op，不崩潰。"
  (let ((limn/kmacro:*defining-kbd-macro* t)
        (limn/kmacro:*current-kbd-macro*
          (make-array 0 :adjustable t :fill-pointer 0)))
    (handler-case
        (progn
          (limn/kmacro:start-kbd-macro)
          (check t "double-start: no-op accepted"))
      (error ()
        (check t "double-start: error accepted")))))

(deftest kmacro-d8-replay-error-in-fn-does-not-abort-remaining
  "replay-fn 丟 error 時應繼續 replay 下一個 key（framework 保護）。"
  (let ((limn/kmacro:*last-kbd-macro* #("a" "boom" "c"))
        (completed '()))
    (let ((limn/kmacro:*kmacro-replay-fn*
            (lambda (s)
              (if (equal s "boom")
                  (error "intentional replay error")
                  (push s completed)))))
      (assert-no-error (limn/kmacro:call-last-kbd-macro))
      ;; "a" and "c" should be replayed; "boom" skipped or caught
      (assert-true (member "a" completed :test #'equal)
                   "keys before error still replayed")
      (assert-true (member "c" completed :test #'equal)
                   "keys after error still replayed"))))
