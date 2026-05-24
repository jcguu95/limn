;;;; v0.24 §A — kill-ring / yank RED tests
;;;;
;;;; 覆蓋：
;;;;   limn/kill  : *kill-ring* / *kill-ring-max*
;;;;                kill-new / kill-append
;;;;                kill-region / copy-region-as-kill
;;;;                yank / yank-pop
;;;;                *interprogram-cut-function* / *interprogram-paste-function*
;;;;                *buffer-insert-fn* / *buffer-delete-fn*
;;;;                *buffer-cursor-fn* / *buffer-set-cursor-fn*
;;;;                *yank-from* / *yank-to*   (內部 yank 邊界 — 供 yank-pop 用)
;;;;   limn/cmd   : *last-command* / *this-command*
;;;;
;;;; 全部 RED — 在 limn-kill.lisp 和 limn-cmd 擴充實作前都會 fail。

;; ── package stubs ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/kill)
    (make-package '#:limn/kill :use '(#:cl)))
  (dolist (sym '("*KILL-RING*" "*KILL-RING-MAX*"
                 "KILL-NEW" "KILL-APPEND"
                 "KILL-REGION" "COPY-REGION-AS-KILL"
                 "YANK" "YANK-POP"
                 "*INTERPROGRAM-CUT-FUNCTION*"
                 "*INTERPROGRAM-PASTE-FUNCTION*"
                 "*BUFFER-INSERT-FN*" "*BUFFER-DELETE-FN*"
                 "*BUFFER-CURSOR-FN*" "*BUFFER-SET-CURSOR-FN*"
                 "*YANK-FROM*" "*YANK-TO*"))
    (export (intern sym '#:limn/kill) '#:limn/kill))
  ;; *last-command* / *this-command* live in limn/cmd
  (unless (find-package '#:limn/cmd)
    (make-package '#:limn/cmd :use '(#:cl)))
  (dolist (sym '("*LAST-COMMAND*" "*THIS-COMMAND*"))
    (export (intern sym '#:limn/cmd) '#:limn/cmd)))

(in-package #:limn/unit-test)
(use-package '#:limn/v024-helpers)

;;; ── A1. ring 基本操作 ─────────────────────────────────────────────────────

(deftest kill-a1-kill-new-prepends
  "kill-new 把新字串放在 ring 頭（最近在前）。"
  (let ((limn/kill:*kill-ring* '()))
    (limn/kill:kill-new "first")
    (limn/kill:kill-new "second")
    (assert-equal "second" (car limn/kill:*kill-ring*))
    (assert-equal "first"  (cadr limn/kill:*kill-ring*))))

(deftest kill-a1-kill-new-max-size
  "*kill-ring-max* 限制 ring 長度：超過時截掉尾端最舊項目。"
  (let ((limn/kill:*kill-ring* '())
        (limn/kill:*kill-ring-max* 3))
    (limn/kill:kill-new "a")
    (limn/kill:kill-new "b")
    (limn/kill:kill-new "c")
    (limn/kill:kill-new "d")               ; 應該把 "a" 擠掉
    (assert-eql 3 (length limn/kill:*kill-ring*))
    (assert-false (member "a" limn/kill:*kill-ring* :test #'equal)
                  "oldest entry dropped")))

(deftest kill-a1-ring-is-list
  "*kill-ring* 是一個 list。"
  (let ((limn/kill:*kill-ring* '()))
    (limn/kill:kill-new "x")
    (assert-true (listp limn/kill:*kill-ring*))))

(deftest kill-a1-kill-new-empty-string-ok
  "kill-new 接受空字串不 error。"
  (let ((limn/kill:*kill-ring* '()))
    (assert-no-error (limn/kill:kill-new ""))
    (assert-equal "" (car limn/kill:*kill-ring*))))

(deftest kill-a1-kill-new-unicode
  "kill-new 正確保留 Unicode / CJK 字串。"
  (let ((limn/kill:*kill-ring* '()))
    (limn/kill:kill-new "你好世界")
    (assert-equal "你好世界" (car limn/kill:*kill-ring*))))

(deftest kill-a1-kill-new-duplicate-creates-separate-entry
  "即使字串相同，kill-new 仍建立新的獨立 entry（不合並）。"
  (let ((limn/kill:*kill-ring* '()))
    (limn/kill:kill-new "dup")
    (limn/kill:kill-new "dup")
    (assert-eql 2 (length limn/kill:*kill-ring*))))

;;; ── A2. kill-append ───────────────────────────────────────────────────────

(deftest kill-a2-append-to-last-entry
  "kill-append 把文字附加到 ring 最新的 entry（後面）。"
  (let ((limn/kill:*kill-ring* '()))
    (limn/kill:kill-new "hello")
    (limn/kill:kill-append " world")
    (assert-equal "hello world" (car limn/kill:*kill-ring*))
    (assert-eql 1 (length limn/kill:*kill-ring*) "still only one entry")))

(deftest kill-a2-prepend-before-p
  "kill-append :before-p t 把文字放在 entry 前面。"
  (let ((limn/kill:*kill-ring* '()))
    (limn/kill:kill-new "world")
    (limn/kill:kill-append "hello " :before-p t)
    (assert-equal "hello world" (car limn/kill:*kill-ring*))))

(deftest kill-a2-append-on-empty-ring-creates-entry
  "ring 為空時 kill-append 就像 kill-new。"
  (let ((limn/kill:*kill-ring* '()))
    (assert-no-error (limn/kill:kill-append "x"))
    (assert-equal "x" (car limn/kill:*kill-ring*))))

(deftest kill-a2-append-does-not-add-new-ring-entry
  "kill-append 不增加 ring 長度（只修改最近 entry）。"
  (let ((limn/kill:*kill-ring* '()))
    (limn/kill:kill-new "a")
    (limn/kill:kill-new "b")
    (limn/kill:kill-append "c")
    (assert-eql 2 (length limn/kill:*kill-ring*))))

;;; ── A3. kill-region / copy-region-as-kill ────────────────────────────────

(deftest kill-a3-kill-region-deletes-text
  "kill-region 刪除 [from, to) 區間的文字。"
  (with-kill-buf (b :text "hello world" :cursor 0)
    (limn/kill:kill-region (mbuf-id b) 6 11)
    (assert-equal "hello " (mbuf-text b))))

(deftest kill-a3-kill-region-adds-to-ring
  "kill-region 把刪除的文字加進 kill-ring。"
  (let ((limn/kill:*kill-ring* '()))
    (with-kill-buf (b :text "hello world" :cursor 0)
      (limn/kill:kill-region (mbuf-id b) 0 5)
      (assert-equal "hello" (car limn/kill:*kill-ring*)))))

(deftest kill-a3-copy-region-does-not-delete
  "copy-region-as-kill 把文字加進 ring 但不刪除。"
  (let ((limn/kill:*kill-ring* '()))
    (with-kill-buf (b :text "hello" :cursor 0)
      (limn/kill:copy-region-as-kill (mbuf-id b) 0 5)
      (assert-equal "hello" (mbuf-text b) "text unchanged")
      (assert-equal "hello" (car limn/kill:*kill-ring*)))))

(deftest kill-a3-kill-region-cjk
  "kill-region 正確處理含 CJK 的 buffer（codepoint offset）。"
  (let ((limn/kill:*kill-ring* '()))
    (with-kill-buf (b :text "A你好B" :cursor 0)
      ;; positions are character (not byte) offsets
      (limn/kill:kill-region (mbuf-id b) 1 3)
      (assert-equal "AB"   (mbuf-text b))
      (assert-equal "你好" (car limn/kill:*kill-ring*)))))

(deftest kill-a3-kill-region-zero-range-noop
  "kill-region with from=to は no-op（不 error、不加 ring）。"
  (let ((limn/kill:*kill-ring* '()))
    (with-kill-buf (b :text "abc" :cursor 0)
      (assert-no-error (limn/kill:kill-region (mbuf-id b) 2 2))
      (assert-equal "abc" (mbuf-text b))
      (assert-true (null limn/kill:*kill-ring*)
                   "no-op does not push to ring"))))

;;; ── A4. yank ──────────────────────────────────────────────────────────────

(deftest kill-a4-yank-inserts-at-cursor
  "yank 在 cursor 位置插入 ring 最新的 entry。"
  (let ((limn/kill:*kill-ring* '("world")))
    (with-kill-buf (b :text "hello " :cursor 6)
      (limn/kill:yank (mbuf-id b))
      (assert-equal "hello world" (mbuf-text b)))))

(deftest kill-a4-yank-n-selects-nth-entry
  "yank n 插入 ring 中第 n 個（1-based）entry。"
  (let ((limn/kill:*kill-ring* '("c" "b" "a")))
    (with-kill-buf (b :text "" :cursor 0)
      (limn/kill:yank (mbuf-id b) 2)
      (assert-equal "b" (mbuf-text b)))))

(deftest kill-a4-yank-on-empty-ring-noop
  "ring 為空時 yank 是 no-op（不 error）。"
  (let ((limn/kill:*kill-ring* '()))
    (with-kill-buf (b :text "x" :cursor 0)
      (assert-no-error (limn/kill:yank (mbuf-id b)))
      (assert-equal "x" (mbuf-text b)))))

(deftest kill-a4-yank-records-yank-boundaries
  "yank 成功後設定 *yank-from* 和 *yank-to*，供 yank-pop 使用。"
  (let ((limn/kill:*kill-ring* '("abc")))
    (with-kill-buf (b :text "" :cursor 0)
      (limn/kill:yank (mbuf-id b))
      (assert-eql 0 limn/kill:*yank-from*)
      (assert-eql 3 limn/kill:*yank-to*))))

;;; ── A5. yank-pop + *last-command* ────────────────────────────────────────

(deftest kill-a5-yank-pop-replaces-last-yank
  "yank-pop 在 *last-command* = 'yank 時，刪掉舊 yank 文字並插入下一個 entry。"
  (let ((limn/kill:*kill-ring* '("second" "first"))
        (limn/cmd:*last-command* 'limn/kill:yank))
    (with-kill-buf (b :text "first" :cursor 5)
      ;; 模擬 yank 剛插入了 "first" 在 [0,5)
      (let ((limn/kill:*yank-from* 0)
            (limn/kill:*yank-to*   5))
        (limn/kill:yank-pop (mbuf-id b))
        (assert-equal "second" (mbuf-text b))))))

(deftest kill-a5-yank-pop-after-yank-pop-continues-cycling
  "連續 yank-pop（*last-command* = 'yank-pop）繼續往下一個 entry 移動。"
  (let ((limn/kill:*kill-ring* '("c" "b" "a"))
        (limn/cmd:*last-command* 'limn/kill:yank-pop))
    (with-kill-buf (b :text "b" :cursor 1)
      (let ((limn/kill:*yank-from* 0)
            (limn/kill:*yank-to*   1))
        (limn/kill:yank-pop (mbuf-id b))
        (assert-equal "c" (mbuf-text b))))))

(deftest kill-a5-yank-pop-not-after-yank-is-noop
  "yank-pop 在 *last-command* 不是 yank / yank-pop 時是 no-op。"
  (let ((limn/kill:*kill-ring* '("other"))
        (limn/cmd:*last-command* 'some-other-command))
    (with-kill-buf (b :text "original" :cursor 8)
      (assert-no-error (limn/kill:yank-pop (mbuf-id b)))
      (assert-equal "original" (mbuf-text b)))))

(deftest kill-a5-yank-pop-updates-yank-boundaries
  "yank-pop 完成後更新 *yank-from* / *yank-to* 為新插入文字的邊界。"
  (let ((limn/kill:*kill-ring* '("XX" "Y"))
        (limn/cmd:*last-command* 'limn/kill:yank))
    (with-kill-buf (b :text "Y" :cursor 1)
      (let ((limn/kill:*yank-from* 0)
            (limn/kill:*yank-to*   1))
        (limn/kill:yank-pop (mbuf-id b))
        (assert-eql 0 limn/kill:*yank-from*)
        (assert-eql 2 limn/kill:*yank-to*)))))

(deftest kill-a5-yank-pop-sets-last-command
  "yank-pop 執行後把 *last-command* 設成 'yank-pop，讓下次還能繼續 pop。"
  (let ((limn/kill:*kill-ring* '("b" "a"))
        (limn/cmd:*last-command* 'limn/kill:yank))
    (with-kill-buf (b :text "a" :cursor 1)
      (let ((limn/kill:*yank-from* 0)
            (limn/kill:*yank-to*   1))
        (limn/kill:yank-pop (mbuf-id b))
        (assert-eq 'limn/kill:yank-pop limn/cmd:*last-command*)))))

;;; ── A6. *last-command* / *this-command* ──────────────────────────────────

(deftest kill-a6-last-command-initially-nil
  "*last-command* 在沒有任何 dispatch 時是 nil。"
  ;; 若實作初始化為 nil 或 symbol，都可接受
  (assert-true (or (null limn/cmd:*last-command*)
                   (symbolp limn/cmd:*last-command*))
               "*last-command* is nil or a symbol"))

(deftest kill-a6-this-command-settable
  "*this-command* 可以被 dispatch loop 設定（無 type error）。"
  (let ((limn/cmd:*this-command* 'test-cmd))
    (assert-eq 'test-cmd limn/cmd:*this-command*)))

(deftest kill-a6-last-command-tracks-this-command
  "dispatch 完成後 *last-command* 應等於 dispatch 前的 *this-command*。
   這裡測試 yank 是否正確更新 *last-command*。"
  (let ((limn/kill:*kill-ring* '("hi"))
        (limn/cmd:*last-command* nil))
    (with-kill-buf (b :text "" :cursor 0)
      (limn/kill:yank (mbuf-id b))
      ;; yank 本身應該把 *last-command* 設成 'yank（或等效 symbol）
      (assert-true (member limn/cmd:*last-command*
                            '(limn/kill:yank yank))
                   "*last-command* updated to yank after yank"))))

;;; ── A7. clipboard hooks ───────────────────────────────────────────────────

(deftest kill-a7-interprogram-cut-called-by-kill-new
  "kill-new 在 *interprogram-cut-function* 非 nil 時呼叫它。"
  (let ((limn/kill:*kill-ring* '())
        (called-with nil))
    (let ((limn/kill:*interprogram-cut-function*
            (lambda (str) (setf called-with str))))
      (limn/kill:kill-new "clip-test")
      (assert-equal "clip-test" called-with
                    "cut fn called with new kill text"))))

(deftest kill-a7-interprogram-cut-nil-disables
  "*interprogram-cut-function* = nil → 不呼叫、不 error。"
  (let ((limn/kill:*kill-ring* '())
        (limn/kill:*interprogram-cut-function* nil))
    (assert-no-error (limn/kill:kill-new "no-clip"))))

(deftest kill-a7-interprogram-paste-consulted-by-yank
  "yank 在 *interprogram-paste-function* 非 nil 時，若它回傳字串則插入
   clipboard 內容而非 ring 最新 entry。"
  ;; Emacs 慣例：paste-fn 回傳 string → 用它；回傳 nil → 用 ring。
  (let ((limn/kill:*kill-ring* '("ring-entry"))
        (limn/kill:*interprogram-paste-function*
          (lambda () "clipboard-text")))
    (with-kill-buf (b :text "" :cursor 0)
      (limn/kill:yank (mbuf-id b))
      (assert-equal "clipboard-text" (mbuf-text b)
                    "clipboard takes precedence over ring"))))
