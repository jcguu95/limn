;;;; ibuffer-gui-driver.lisp — guided walkthrough of ibuffer-mode in a
;;;; visible Qt window.
;;;;
;;;; Loaded by tmp/run-ibuffer-gui.sh AFTER (o tutorial.pdf) has run,
;;;; so by entry: limn is up, Qt window is visible, tutorial.pdf is
;;;; open in w1.  Each step tells the user what to press in the Qt
;;;; window and prints what should happen + what Lisp side sees.
;;;; User confirms in this terminal.
;;;;
;;;; After the walkthrough returns, SBCL drops to its REPL prompt so
;;;; the user can keep playing.  (q) to quit cleanly.

(in-package #:cl-user)

;; Give Qt a beat to paint the PDF before the walkthrough starts.
(sleep 1.5)

;; Turn on render diagnostics so each navigation key prints a one-line
;; trace to the terminal — useful when n/p look unresponsive.
(when (find-symbol "*IBUFFER-TRACE*" '#:limn/ibuffer)
  (setf (symbol-value (find-symbol "*IBUFFER-TRACE*" '#:limn/ibuffer)) t))

(defvar *gui-results* '())
(defvar *gui-step-n* 0)

(defun gui-read-line ()
  (string-trim '(#\Space #\Tab #\Newline #\Return)
               (or (read-line *standard-input* nil "") "")))

(defun gui-split-lines (s)
  (with-input-from-string (in (or s ""))
    (loop for l = (read-line in nil) while l collect l)))

(defun gui-banner (title)
  (incf *gui-step-n*)
  (format t "~&~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
  (format t "  STEP ~a / 13   ~a~%" *gui-step-n* title)
  (format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%"))

(defun gui-section (label lines)
  (format t " ~a~%" label)
  (dolist (l (gui-split-lines lines)) (format t "   ~a~%" l)))

(defun gui-step (title &key do-in-qt expected verify pre-action)
  "TITLE        — step short title.
   DO-IN-QT     — multiline string telling user what to do in Qt window.
   EXPECTED     — multiline string of what should happen visually.
   VERIFY       — optional thunk; its result printed under '我這邊看到'.
   PRE-ACTION   — optional thunk run by the driver BEFORE asking (e.g.
                  to open a second buffer auto-magically)."
  (gui-banner title)
  (when pre-action
    (gui-section "▶ Driver 先跑：" "(我自動執行；下方有結果)")
    (handler-case (funcall pre-action)
      (error (e) (format t "   ⚠ driver action 失敗：~a~%" e))))
  (when do-in-qt
    (gui-section "▶ 在 Qt 窗操作：" do-in-qt))
  (gui-section "▶ 預期看到：" expected)
  (when verify
    (let ((r (handler-case (funcall verify)
               (error (e) (list :error (princ-to-string e))))))
      (format t " ▶ Lisp side 我看到：~%   ~s~%" r)))
  (format t "─────────────────────────────────────────────────────────~%")
  (format t " 跟預期一致嗎？  [RET]=PASS   n=FAIL   s=SKIP   q=QUIT~%")
  (format t " > ")
  (finish-output)
  (let ((line (gui-read-line)))
    (cond
      ((member line '("q" "Q") :test #'string=)
       (push (list *gui-step-n* title :quit) *gui-results*)
       (throw 'gui-quit nil))
      ((member line '("n" "N") :test #'string=)
       (push (list *gui-step-n* title :fail) *gui-results*)
       (format t " → 標 FAIL~%"))
      ((member line '("s" "S") :test #'string=)
       (push (list *gui-step-n* title :skip) *gui-results*)
       (format t " → SKIP~%"))
      (t
       (push (list *gui-step-n* title :pass) *gui-results*)
       (format t " → PASS~%")))))

;;; ── helpers for verify thunks ─────────────────────────────────────────

(defun %ib-state ()
  (when (find-package '#:limn/ibuffer)
    (symbol-value (find-symbol "*IBUFFER-STATE*" '#:limn/ibuffer))))

(defun %ib-rows ()
  (let ((s (%ib-state)))
    (when s
      (mapcar (lambda (r)
                (list :id     (limn/ibuffer:ibuffer-row-id r)
                      :engine (limn/ibuffer:ibuffer-row-engine r)
                      :path   (limn/ibuffer:ibuffer-row-path r)))
              (limn/ibuffer:ibuffer-state-rows s)))))

(defun %ib-current ()
  (let ((s (%ib-state)))
    (and s (limn/ibuffer:ibuffer-state-current s))))

(defun %ib-marks ()
  (let ((s (%ib-state)))
    (when s
      (let ((tbl (limn/ibuffer:ibuffer-state-marks s))
            (acc '()))
        (maphash (lambda (k v) (push (cons k v) acc)) tbl)
        acc))))

(defun %registry-ids ()
  (sort (copy-list (limn/buffer:list-all)) #'string<))

(defun %open-text-file (path)
  "Allocate a text-engine buffer for PATH via the wire."
  (let ((r (limn:call "bridge/engine-load"
                      :|win-id| "w1" :|engine| "text" :|path| "")))
    (let* ((d   (limn/bridge:response-data r))
           (bid (getf d :|buffer-id|)))
      (when bid
        (limn:call "buffer/load-file" :|buffer-id| bid :|path| path)
        bid))))

(defun %open-and-stay-in-ibuffer (path)
  "Open PATH as text buffer, then yank w1 back to *Buffer List*.

   v0.40: backend's limn:call sync-shim handles all the Lisp/wire
   sync (path in limn/buffer, active in *window-active-buffer*),
   and %on-buffer-opened won't clobber an already-set major mode or
   an explicitly-set window active.  So this is now boringly
   straightforward: open the file, switch back, revert."
  (let ((ib-bid (and (%ib-state)
                     (limn/ibuffer:ibuffer-state-ibuffer-buf-id (%ib-state)))))
    (%open-text-file path)
    (when ib-bid
      ;; Switch w1 back to *Buffer List*.  buffer/show's sync-shim
      ;; updates *window-active-buffer* in lockstep — keystrokes will
      ;; route to ibuffer-mode.
      (handler-case (limn:call "buffer/show"
                               :|buffer-id| ib-bid :|win-id| "w1")
        (error () nil))
      ;; Re-render so the freshly-registered buffer appears in the
      ;; table with its correct path (sync-shim's buffer/load-file
      ;; case kept limn/buffer's path fresh).
      (handler-case (limn/cmd:call-interactively 'cl-user::ibuffer-revert)
        (error () nil)))))

;;; ── intro ─────────────────────────────────────────────────────────────

(format t "
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Ibuffer GUI Walkthrough — 13 steps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

我會逐步告訴你「在 Qt 窗按什麼」「預期看到什麼」「Lisp side 看到什麼」。
你看一眼 Qt 窗 → 切回 terminal → 按 RET/n/s/q。

  RET = 一致，PASS
  n   = 不一致，FAIL
  s   = 跳過
  q   = 提早結束

走完 driver 會 drop 到 SBCL prompt，你可以繼續玩。要關掉時打 (q) 然後 RET。
")
(finish-output)

(format t "  按 RET 開始：")
(finish-output)
(gui-read-line)

;;; ── steps ─────────────────────────────────────────────────────────────

(catch 'gui-quit

  ;; ── 1: baseline visibility ──
  (gui-step "Qt 窗顯示了 tutorial.pdf"
    :do-in-qt "把 Qt 窗放到你看得到的位置。
別操作，先看就好。"
    :expected "Qt 窗顯示 tutorial.pdf 第一頁。
PDF 顯示 \"sioyek\" 標題或 tutorial 內容。"
    :verify (lambda () (list :registered-buffers (%registry-ids))))

  ;; ── 2: M-x opens minibuffer ──
  (gui-step "M-x 開 minibuffer"
    :do-in-qt "在 Qt 窗按 M-x（macOS: option-x，或 ESC 然後 x）"
    :expected "Qt 窗底部跳出 minibuffer，提示文字大約是
\"M-x \" 之類；你打的字會出現在後面。
（看到 minibuffer 後不要 ENTER，先確認）"
    :verify nil)

  ;; ── 3: M-x ibuffer RET → *Buffer List* ──
  (gui-step "M-x ibuffer → 切到 *Buffer List*"
    :do-in-qt "在 minibuffer 打：ibuffer
然後 RET"
    :expected "w1 整個畫面換成一張表格，類似：

  M  ID                ENGINE   PATH
     b1                mupdf    /…/tutorial.pdf
     t1                text     <no file>

兩行 data：tutorial.pdf 自己 + *Buffer List* 自己（ibuffer
是一個 text-engine buffer，所以也會出現在 list 裡，就像
Emacs ibuffer 列自己一樣）。"
    :verify (lambda ()
              (list :rows (%ib-rows) :current (%ib-current))))

  ;; ── 4: ibuffer-state populated ──
  (gui-step "Lisp 側驗證：state 確實建好"
    :do-in-qt "不用做任何事。只是讓你看 Lisp side 的 state 是怎樣。"
    :expected "下方 :ROWS 應該是一個 2 元素的 list：
  - 一筆 :ENGINE \"mupdf\"、:PATH 結尾是 tutorial.pdf
  - 一筆 :ENGINE \"text\"、:PATH 空字串  (←這個就是 *Buffer List* 自己)
:CURRENT 應該是 0。"
    :verify (lambda ()
              (list :rows (%ib-rows) :current (%ib-current))))

  ;; ── 5: n / p navigation (2 rows → wraps) ──
  (gui-step "n / p 在 2 行間移動 + wrap"
    :do-in-qt "在 *Buffer List* 按 n。
再按 n（應該 wrap 回 0）。
再按 p（回到 1）。"
    :expected "Cursor 在 row 0 ↔ row 1 之間切換、wrap 正常。
:CURRENT 在 0 / 1 之間。"
    :verify (lambda () (list :current (%ib-current))))

  ;; ── 6: open second buffer + auto-switch back + auto-revert ──
  (gui-step "driver 開 /tmp/foo.txt，幫你切回 *Buffer List* 並 revert"
    :pre-action (lambda () (%open-and-stay-in-ibuffer "/tmp/foo.txt"))
    :do-in-qt "不用做任何事。Driver 會：
  1. bridge/engine-load 開 /tmp/foo.txt
  2. buffer/show 切回 *Buffer List*
  3. 對 ibuffer 跑 revert 重畫
Qt 窗可能會短暫閃一下，最後應該停在 *Buffer List*。"
    :expected "Qt 窗仍在 *Buffer List*（沒被踢去 text buffer）。
表格現在有 3 行 data：
  - 一行 mupdf tutorial.pdf
  - 一行 text  /tmp/foo.txt
  - 一行 text  <no file>      ← *Buffer List* 自己
:REGISTERED-BUFFERS 是 3 個。"
    :verify (lambda ()
              (list :rows (%ib-rows)
                    :current (%ib-current)
                    :registered (%registry-ids))))

  ;; ── 7: n moves cursor ──
  (gui-step "n 真的移動游標了"
    :do-in-qt "按 n。"
    :expected "Qt 窗的 cursor 視覺上跳到第 2 行 data。
:CURRENT 應該從 0 變成 1。"
    :verify (lambda () (list :current (%ib-current))))

  ;; ── 8: d marks for delete ──
  (gui-step "d 在當前行標 D"
    :do-in-qt "在第 2 行（/tmp/foo.txt）按 d。"
    :expected "該行最左欄 M 出現 D。游標自動下移（wrap 回第 1 行）。
:MARKS 出現 /tmp/foo.txt 的 buffer-id → (#\\D)。"
    :verify (lambda () (list :marks (%ib-marks) :current (%ib-current))))

  ;; ── 9: u clears marks ──
  (gui-step "u 清掉 mark"
    :do-in-qt "再按 p 移到 /tmp/foo.txt 那行（剛才那行）。
按 u。"
    :expected "該行的 D 消失，游標自動下移。
:MARKS 應該變空或那個 id 的 entry 沒了。"
    :verify (lambda () (list :marks (%ib-marks))))

  ;; ── 10: d + x kills the buffer ──
  (gui-step "d 標、x 執行 → buffer 真的被關掉"
    :do-in-qt "確認游標在 /tmp/foo.txt 那行（用 n/p 移動）。
按 d 標 D，再按 x。
注意：千萬不要在 *Buffer List* 自己那行（path 是 <no file>）按 d x，
否則你就把自己腳下的地板鋸掉了。"
    :expected "/tmp/foo.txt 從表格中消失。剩下 tutorial.pdf + *Buffer List* 自己。
:REGISTERED-BUFFERS 從 3 個回到 2 個。"
    :verify (lambda ()
              (list :rows (%ib-rows)
                    :registered (%registry-ids))))

  ;; ── 11: S sort prompt ──
  (gui-step "S 換排序"
    :pre-action (lambda () (%open-and-stay-in-ibuffer "/tmp/foo.txt"))
    :do-in-qt "Driver 已經幫你補了 /tmp/foo.txt 回來、切回 *Buffer List*、
也 revert 過，所以你應該已經有 2 行可以排序。
在 Qt 窗按 S（大寫）。
minibuffer 跳出 \"Sort by (id/path/engine): \"，
打 path 然後 RET。"
    :expected "表格依 path 重排：
含 \"foo\" 的字串通常排在 \"tutorial\" 之前（看實際 path 而定）。
:ROWS 順序反映新的排序。"
    :verify (lambda () (list :rows (%ib-rows))))

  ;; ── 12: / filter prompt ──
  (gui-step "/ 套 substring filter"
    :do-in-qt "按 / → minibuffer 跳出 \"Filter substring: \"。
打 tutorial 然後 RET。"
    :expected "表格只剩 path 含 \"tutorial\" 的行（就一個 — *Buffer List*
自己 path 是空字串，不會命中 \"tutorial\"）。
:ROWS 長度應該是 1。"
    :verify (lambda () (list :rows (%ib-rows))))

  ;; ── 13: empty filter clears ──
  (gui-step "清 filter"
    :do-in-qt "再按 /，這次 minibuffer 直接 RET（不打字）。"
    :expected "表格 3 行全部回來（tutorial.pdf、/tmp/foo.txt、*Buffer List* 自己）。"
    :verify (lambda () (list :rows (%ib-rows))))

  ;; ── (no step 14) ──
  ;;
  ;; v0.40 cleanup: ibuffer-mode does NOT bind `q`.  Emacs's
  ;; quit-window flow in ibuffer requires reliable text-engine →
  ;; mupdf-engine visual switching in the same window, which exposes
  ;; a sioyek-side Qt paint quirk independent of ibuffer.  Until
  ;; that's resolved at the C++ layer, users leave ibuffer by:
  ;;   • RET / f on a row  (visit that buffer)
  ;;   • M-x switch-to-buffer  (pick any buffer)
  ;; No GUI step needed here — the walkthrough ends after step 13.
  )

;;; ── final report ──────────────────────────────────────────────────────

(format t "~&~%~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%")
(format t " ▼▼▼ REPORT — 整段複製貼回給 Claude ▼▼▼~%")
(format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%~%")

(let ((sorted (sort (copy-list *gui-results*) #'< :key #'first)))
  (dolist (r sorted)
    (let ((tag (case (third r)
                 (:pass "PASS")
                 (:fail "FAIL")
                 (:skip "SKIP")
                 (:quit "QUIT")
                 (otherwise "????"))))
      (format t "[~a] step ~2,'0d  ~a~%" tag (first r) (second r)))))

(let ((pass (count :pass *gui-results* :key #'third))
      (fail (count :fail *gui-results* :key #'third))
      (skip (count :skip *gui-results* :key #'third))
      (quit (count :quit *gui-results* :key #'third)))
  (format t "~%── ~d PASS / ~d FAIL / ~d SKIP / ~d QUIT  (共 ~d steps) ──~%"
          pass fail skip quit *gui-step-n*))

(format t "~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
(format t " ▲▲▲ END OF REPORT ▲▲▲~%")
(format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%~%")

(format t "Driver 結束。Qt 窗還開著。你可以在這個 prompt 繼續玩，例如：~%")
(format t "  (limn/ibuffer:*ibuffer-state*)~%")
(format t "  (call-interactively 'cl-user::ibuffer)~%")
(format t "  (o \"/某個.pdf\")~%")
(format t "要結束打：~%")
(format t "  (q)~%~%")
(finish-output)
