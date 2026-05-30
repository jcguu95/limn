;;;; narrow-walkthrough.lisp — v0.40 narrow/widen 互動 walkthrough
;;;;
;;;; 用法：
;;;;   export LIMN_BIN=/Users/jin/data/local/projects/sioyek-core/sioyek/limn.app/Contents/MacOS/limn
;;;;   cd /Users/jin/data/local/projects/sioyek-core/.claude/worktrees/hardcore-chatterjee-ba239b
;;;;   HEADLESS=0 backend/run-repl.sh
;;;;
;;;;   (load "/Users/jin/data/local/projects/sioyek-core/.claude/worktrees/hardcore-chatterjee-ba239b/scratch/narrow-walkthrough.lisp")
;;;;
;;;; 每一步：
;;;;   1. 注入 form
;;;;   2. 印出「預期看到什麼」
;;;;   3. 問 y / n / c / a
;;;;      y = 一致，繼續
;;;;      n = 不一致，繼續（不加 comment）
;;;;      c = 不一致，輸入一行 comment 再繼續
;;;;      a = 中止
;;;;
;;;; 結束（或中止）後，會印出每步的摘要：通過/失敗、comment、
;;;; 跟原始 form（可以直接複製貼回 prompt 重跑某一步）。

(in-package #:cl-user)

;;; ── 設定 ──────────────────────────────────────────────────────────────

(defparameter *narrow-demo-path* "/tmp/narrow-demo.txt")

(defparameter *narrow-demo-content*
  "0123456789abcdefghijklmnopqrstuvwxyz
(defun foo () 1)
(defun bar () 2)
(defun baz () 3)
")

(defvar *narrow-demo-buf* nil
  "目前 walkthrough 用的 text buffer-id（global，方便每一步引用）。")

;;; ── helper: 印 expect 區塊 ───────────────────────────────────────────

(defun %narrow-print-expect (msg)
  (terpri)
  (write-string "  ┌─ 預期 ───────────────────────────────────────────")
  (terpri)
  (with-input-from-string (in msg)
    (loop for line = (read-line in nil) while line
          do (format t "  │ ~a~%" line)))
  (write-string "  └──────────────────────────────────────────────────")
  (terpri)
  (force-output))

;;; ── helper: 詢問結果 ─────────────────────────────────────────────────

(defun %narrow-ask-result ()
  "回傳 (status . comment)；status 是 :pass / :fail / :abort，
   comment 是 string 或 nil。"
  (loop
    (format t "  結果? [y=pass  n=fail  c=fail+留 comment  a=中止] > ")
    (force-output)
    (let ((input (string-trim " " (or (read-line *standard-input* nil "") ""))))
      (cond
        ((or (string-equal input "y") (string= input ""))
         (return (cons :pass nil)))
        ((string-equal input "n")
         (return (cons :fail nil)))
        ((string-equal input "c")
         (format t "  請輸入 comment（一行）: ")
         (force-output)
         (return (cons :fail (read-line *standard-input* nil ""))))
        ((string-equal input "a")
         (return (cons :abort nil)))
        (t
         (format t "  ✗ 請輸入 y / n / c / a。~%"))))))

;;; ── 每一步的 forms（quoted，summary 跟執行共用） ────────────────────

(defparameter *narrow-steps*
  '((1 "開啟 demo 文字 buffer 並切到 text-mode"
       (progn
         (with-open-file (s *narrow-demo-path*
                            :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
           (write-string *narrow-demo-content* s))
         (let* ((r   (limn:call "bridge/engine-load"
                                :|win-id| "w1"
                                :|engine| "text" :|path| ""))
                (buf (getf (getf r :|data|) :|buffer-id|)))
           (limn:call "buffer/load-file"
                      :|buffer-id| buf :|path| *narrow-demo-path*)
           (setf limn/text:*current-text-buffer* buf
                 *narrow-demo-buf* buf)
           (let ((mb-fn (find-symbol "MODE-BUFFER-FOR-WINDOW" :limn/runtime)))
             (when (and mb-fn (fboundp mb-fn))
               (let ((mb (funcall mb-fn "w1")))
                 (when mb (limn/mode:activate mb 'text-mode)))))
           (limn/text:text-mode-update-modeline
            :buffer-id buf :path *narrow-demo-path*)
           (format t "  buf = ~s~%" buf)))
       "Qt 視窗顯示 demo 文字（共四行）：
    0123456789abcdefghijklmnopqrstuvwxyz
    (defun foo () 1)
    (defun bar () 2)
    (defun baz () 3)

modeline（左下角）寫著：「Text: narrow-demo.txt」。
modeline 沒有 Narrow 字樣。")

    (2 "cursor=5、設 mark=5、再把 cursor 移到 15"
       (let ((buf *narrow-demo-buf*))
         (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 5)
         (limn/mark:set-mark 5 buf)
         (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 15)
         (format t "  cursor=~s   mark=~s~%"
                 (getf (getf (limn:call "buffer/cursor-get"
                                         :|buffer-id| buf)
                              :|data|) :|offset|)
                 (limn/mark:mark buf)))
       "上方應該印出：cursor=15   mark=5

（Qt 視窗的游標 I-beam 可能不一定看得到 — text widget 沒拿到 keyboard
focus 時不會閃。此步主要靠上面那行印出來的數字確認狀態正確。）")

    (3 "C-x n n  →  narrow-to-region [5, 15)"
       (limn/cmd:call-interactively
        (find-symbol "NARROW-TO-REGION" :cl-user))
       "modeline 變成：「Text: narrow-demo.txt   Narrow」。

Qt 視窗第一行：
    01234 56789abcde fghij...xyz
    ^^^^^             ^^^^^^^^^^
    變暗               變暗
中間的「56789abcde」（10 個字）正常亮度。

第 2、3、4 行（三個 defun）也整個變暗。")

    (4 "M-> via 直接呼叫 → cursor clamp 到 point-max = 15"
       (progn
         (limn/text-nav:end-of-buffer *narrow-demo-buf*)
         (format t "  cursor → ~s~%"
                 (getf (getf (limn:call "buffer/cursor-get"
                                         :|buffer-id| *narrow-demo-buf*)
                              :|data|) :|offset|)))
       "上方印出：cursor → 15

如果 narrow 不生效，cursor 會跑到 buffer 真正的末端（>= 86）。
這裡只看數字即可。")

    (5 "M-< via 直接呼叫 → cursor clamp 到 point-min = 5"
       (progn
         (limn/text-nav:beginning-of-buffer *narrow-demo-buf*)
         (format t "  cursor → ~s~%"
                 (getf (getf (limn:call "buffer/cursor-get"
                                         :|buffer-id| *narrow-demo-buf*)
                              :|data|) :|offset|)))
       "上方印出：cursor → 5

如果 narrow 不生效，cursor 會跑到 0。")

    (6 "C-x n w  →  widen"
       (limn/cmd:call-interactively
        (find-symbol "WIDEN" :cl-user))
       "modeline 回到：「Text: narrow-demo.txt」（沒有 Narrow）。
Qt 視窗所有變暗的區域恢復亮度；整個 buffer 都可存取。")

    (7 "把 cursor 移到 (defun foo ...) 內，C-x n d  →  narrow-to-defun"
       (let* ((buf  *narrow-demo-buf*)
              (text (getf (getf (limn:call "buffer/text"
                                            :|buffer-id| buf)
                                 :|data|) :|text|))
              (idx  (search "(defun foo" text)))
         (limn:call "buffer/cursor-set"
                    :|buffer-id| buf :|offset| (+ idx 5))
         (limn/cmd:call-interactively
          (find-symbol "NARROW-TO-DEFUN" :cl-user))
         (format t "  narrowed → [~s, ~s)~%"
                 (limn/excursion:point-min-of buf)
                 (limn/excursion:point-max-of buf)))
       "上方印出的 [start, end) 應該正好包住整段「(defun foo () 1)」
（在 demo 內容裡，這段大約從 offset 37 開始，長度 17）。

modeline 顯示「Narrow」。Qt 視窗只有 (defun foo () 1) 那一行
維持亮度，其他三行（字母行 + 另外兩個 defun）全變暗。")

    (8 "widen 收尾"
       (limn/cmd:call-interactively
        (find-symbol "WIDEN" :cl-user))
       "modeline 不再有 Narrow，所有變暗區域恢復。"))
  "每個 element：(step-num title body-form expected-text)。
   body-form 是 quoted 的；script 用 EVAL 跑、也用在 summary 印出。")

;;; ── 結果 + 摘要 ──────────────────────────────────────────────────────

(defvar *narrow-results* nil
  "List of (step-num title status comment form expected)；newest first。")

(defun %narrow-print-summary ()
  (let ((results (reverse *narrow-results*)))
    (terpri)
    (format t "━━━━━━━━━━━━━━━━━━━━ 摘要 ━━━━━━━━━━━━━━━━━━━━~%")
    (dolist (r results)
      (destructuring-bind (n title status comment form expected) r
        (declare (ignore expected))
        (format t "~%step ~a: ~a — ~a~%"
                n
                (case status
                  (:pass  "✓ 通過")
                  (:fail  "✗ 失敗")
                  (:abort "■ 中止")
                  (t      "?"))
                title)
        (when comment
          (format t "  comment: ~a~%" comment))
        (format t "  form（可複製貼回 prompt 重跑）:~%")
        (let ((*print-pretty* t)
              (*print-right-margin* 70))
          (format t "    ~s~%" form))))
    (terpri)
    (let ((pass (count :pass results :key #'third))
          (fail (count :fail results :key #'third))
          (abort (count :abort results :key #'third)))
      (format t "通過 ~a  失敗 ~a  中止 ~a   (共 ~a 步)~%"
              pass fail abort (length results)))
    (format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")))

;;; ── 主流程 ──────────────────────────────────────────────────────────

(defun narrow-walkthrough ()
  "從 step 1 跑到最後。隨時可以重呼叫。"
  (setf *narrow-results* nil)
  (block walkthrough
    (let ((total (length *narrow-steps*)))
      (dolist (step *narrow-steps*)
        (destructuring-bind (n title form expected) step
          (format t "~&~%━━ step ~a/~a — ~a ━━~%" n total title)
          (handler-case (eval form)
            (error (e)
              (format t "  ✗ 執行 form 時 error: ~a~%" e)))
          (%narrow-print-expect expected)
          (let* ((res     (%narrow-ask-result))
                 (status  (car res))
                 (comment (cdr res)))
            (push (list n title status comment form expected)
                  *narrow-results*)
            (when (eq status :abort)
              (format t "~&  ■ 中止於 step ~a。~%" n)
              (return-from walkthrough nil)))))))
  (%narrow-print-summary)
  t)

;; 載入時印一行 confirm，但 NOT 自動跑（auto-call 在 load context
;; 下可能被吃掉或 stdin 行為怪怪的）。請手動呼叫 (narrow-walkthrough)。
(format t "~&~%── narrow-walkthrough.lisp 載入完成 ──~%")
(format t "  *narrow-steps* 有 ~a 步~%" (length *narrow-steps*))
(format t "  在 prompt 打：(narrow-walkthrough) 開始跑~%~%")
(force-output)
