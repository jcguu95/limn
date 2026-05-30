;;;; verify-logging-v037.lisp — v0.37 logging 自動驗證 runner
;;;;
;;;; 啟動方式（用伴生的 shell script，會幫你 build binary + 開 REPL）：
;;;;   bash /Users/jin/data/local/projects/sioyek-core/.claude/worktrees/reverent-williams-90cb72/scripts/verify-logging-v037.sh
;;;;
;;;; 設計：
;;;; -----
;;;; 把 v037-logging-manual-test.org 的 27 個手動 step 變成可
;;;; eval 的 lisp form，runner 逐個 inject 進活的 REPL，印出：
;;;;
;;;;   Form       — 即將被 eval 的 Lisp 表達式（quoted、讓你看清楚）
;;;;   Expected   — 平常話：應該得到什麼結果
;;;;   Predicate  — 我用什麼判斷式 auto-check ACTUAL
;;;;   Actual     — 實際 eval 出來的值（過長會截斷）
;;;;   Verdict    — ✓ PASS / ✗ FAIL（由 Predicate 自動判斷）
;;;;
;;;; 然後等你按鍵：
;;;;   ENTER     → 下一步
;;;;   q + ENTER → 中止，印 summary
;;;;   s + ENTER → 標 SKIP（predicate 跳過、繼續）
;;;;
;;;; 全部跑完（或中止後）會印一段 COPY-PASTE block，你直接複製回
;;;; chat 給 Claude 看。
;;;;
;;;; 為什麼這樣設計：
;;;; ---------------
;;;; - 手動逐 step 打 REPL 太慢、容易打錯
;;;; - 但 unit test 又無法驗 wire 端的真實格式
;;;; - 折衷：form 我寫好、判斷 Claude 自動做、你只需要 ENTER 確認
;;;;   進度跟看到的內容沒怪怪的

(defpackage #:verify-logging
  (:use #:cl)
  (:export #:run #:run-visible))

(in-package #:verify-logging)

(defvar *results* nil
  "倒序紀錄：(STEP-ID :PASS|:FAIL|:SKIP DISPLAY-STRING)。
   run 開始時清空、結尾印 summary 時用。")

;;; ── 工具函式 ─────────────────────────────────────────────────────────

(defun %ms-text ()
  "從 C++ 端把 *messages* GapBuffer 整段字串撈回來。
   走 wire（buffer/text）、wire 出錯就回 \"<wire error: ...>\"
   讓 step 自己判斷 fail。"
  (handler-case
      (or (getf (getf (limn:call "buffer/text" :|buffer-id| "*messages*")
                      :|data|) :|text|)
          "")
    (error (e) (format nil "<wire error: ~A>" e))))

(defun %trunc (x &optional (limit 280))
  "把 X princ 成單行、超過 LIMIT 字元截斷加 [+N chars]。
   給 Actual 顯示用：GapBuffer 字串可能很長，避免螢幕被淹沒。"
  (let ((s (princ-to-string x)))
    (if (> (length s) limit)
        (format nil "~A...[+~A chars]"
                (subseq s 0 limit)
                (- (length s) limit))
        s)))

;;; ── step 結構與 macro ────────────────────────────────────────────────

(defstruct vstep
  id              ; 對應 org 檔的編號字串，例如 "3.1"
  desc            ; 一行 desc
  form            ; quoted lisp form，runner 會 eval 它
  expected        ; user-readable 預期描述
  pred-desc       ; predicate 的描述（給人看）
  pred)           ; (lambda (actual) ...) — predicate，回 truthy = PASS

(defmacro defstep (id desc form expected pred-desc pred-form)
  "Step 定義 sugar。PRED-FORM 內可以用 anaphoric 變數 ACTUAL（就是
   eval form 之後的回傳值）。"
  `(make-vstep :id ,id :desc ,desc :form ',form
               :expected ,expected :pred-desc ,pred-desc
               :pred (lambda (actual)
                       (declare (ignorable actual))
                       ,pred-form)))

;;; ── 27 個 step ───────────────────────────────────────────────────────
;;;
;;; 順序很重要：
;;;
;;; §3 (4 step)   — 先驗最基本的 ring + wire mirror
;;; §4 (8 step)   — 驗 hierarchical ns 繼承（會留下 explicit binding）
;;; §5 (3 step)   — 驗 with-log-levels；用到 §4 留下的 binding
;;; §6 (7 step)   — 驗「ring 永遠記、wire 受 level filter」核心 invariant
;;; §7 (1 step)   — 驗 wire 格式 [HH:MM:SS LEVEL ns] 的正確性
;;; §9 (4 step)   — 驗 stop/start，*必須最後*（會把 session 砍掉）

(defparameter *steps*
  (list
   ;; ───── §3 ring 寫入 + wire 鏡射 ─────────────────────────────────
   (defstep "3.1" "基本 limn/log:message 回傳格式化後的字串"
     (limn/log:message "hello from REPL")
     "字串 \"hello from REPL\""
     "EQUAL \"hello from REPL\""
     (equal actual "hello from REPL"))

   (defstep "3.2" "Ring 把訊息記下來；get-messages 回 string list"
     (first (limn/log:get-messages 1))
     "\"hello from REPL\""
     "ring 第一筆 EQUAL \"hello from REPL\""
     (equal actual "hello from REPL"))

   (defstep "3.3" "Ring 存的是 log-record struct、不是 raw string"
     (let ((r (first (limn/log:get-records 1))))
       (when r
         (list :is-struct (limn/log:log-record-p r)
               :level     (limn/log:log-record-level r)
               :ns        (string (limn/log:log-record-ns r))
               :text      (limn/log:log-record-text r))))
     "plist :is-struct T :level :INFO :ns \"DEFAULT\" :text \"hello from REPL\""
     ":is-struct T、:level :info、:ns name = DEFAULT、:text 對得上"
     (and (consp actual)
          (eq (getf actual :is-struct) t)
          (eq (getf actual :level) :info)
          (equal (getf actual :ns) "DEFAULT")
          (equal (getf actual :text) "hello from REPL")))

   (defstep "3.4" "C++ 端 *messages* GapBuffer 收到 wire 鏡射的那行"
     (let* ((txt (verify-logging::%ms-text))
            (pos (search "hello from REPL" txt)))
       (if pos
           (subseq txt (max 0 (- pos 40))
                       (min (length txt) (+ pos 20)))
           :not-found-in-gapbuffer))
     "片段含 \"[HH:MM:SS INFO  default] hello from REPL\""
     "字串含 hello from REPL、且附近 regex \\[HH:MM:SS INFO  default\\] 中"
     (and (stringp actual)
          (search "hello from REPL" actual)
          (cl-ppcre:scan "\\[\\d{2}:\\d{2}:\\d{2} INFO  default\\]"
                         actual)))

   ;; ───── §4 hierarchical ns 解析 ──────────────────────────────────
   ;;
   ;; 用 pdf-mode 系列建一個 explicit binding tree：
   ;;   pdf-mode             :warn
   ;;   pdf-mode.annotation  :debug
   ;;   （annotation.edit 沒設）
   ;;   （pdf-mode.other 沒設）
   ;; 然後驗 effective-level 是否照 leaf → root → default 解析。

   (defstep "4.1a" "set-level 'pdf-mode :warn — 建第一個 explicit binding"
     (limn/log:set-level 'pdf-mode :warn)
     ":WARN" "EQ :WARN"
     (eq actual :warn))

   (defstep "4.1b" "set-level 'pdf-mode.annotation :debug — 建子節點 binding"
     (limn/log:set-level 'pdf-mode.annotation :debug)
     ":DEBUG" "EQ :DEBUG"
     (eq actual :debug))

   (defstep "4.2" "effective-level 'pdf-mode → :WARN（自己 explicit）"
     (limn/log:effective-level 'pdf-mode)
     ":WARN" "EQ :WARN"
     (eq actual :warn))

   (defstep "4.3" "effective-level 'pdf-mode.annotation.edit → :DEBUG（更具體的 annotation 勝）"
     (limn/log:effective-level 'pdf-mode.annotation.edit)
     ":DEBUG（更具體者勝、不是 pdf-mode 的 :WARN）"
     "EQ :DEBUG"
     (eq actual :debug))

   (defstep "4.4" "effective-level 'pdf-mode.other → :WARN（繼承 pdf-mode root）"
     (limn/log:effective-level 'pdf-mode.other)
     ":WARN" "EQ :WARN"
     (eq actual :warn))

   (defstep "4.5" "effective-level 'totally-unrelated → :INFO（fall through 到 *default-log-level*）"
     (limn/log:effective-level 'totally-unrelated)
     ":INFO" "EQ :INFO"
     (eq actual :info))

   (defstep "4.6a" "get-level 'pdf-mode → :WARN（有 explicit binding）"
     (limn/log:get-level 'pdf-mode)
     ":WARN" "EQ :WARN"
     (eq actual :warn))

   (defstep "4.6b" "get-level 'pdf-mode.annotation.edit → NIL（只有繼承、沒 explicit）"
     (limn/log:get-level 'pdf-mode.annotation.edit)
     "NIL" "NULL"
     (null actual))

   ;; ───── §5 with-log-levels macro ─────────────────────────────────
   ;;
   ;; 驗 dynamic binding 行為：BODY 內看到新值、出 BODY 後正確 unwind。
   ;; 特別注意 5.3 — 對原本就沒 binding 的 ns、unwind 後要回到「無
   ;; binding」狀態（不是回到某個預設值），否則會 leak。

   (defstep "5.1" "with-log-levels BODY 內看到新 binding"
     (limn/log:with-log-levels ((pdf-mode :debug) (auto-revert :error))
       (list (limn/log:effective-level 'pdf-mode)
             (limn/log:effective-level 'auto-revert)))
     "(:DEBUG :ERROR)" "EQUAL (:debug :error)"
     (equal actual '(:debug :error)))

   (defstep "5.2" "Macro 結束後 pdf-mode 恢復成 :WARN（§4.1a 設的原值）"
     (limn/log:effective-level 'pdf-mode)
     ":WARN" "EQ :WARN"
     (eq actual :warn))

   (defstep "5.3" "Macro 結束後 auto-revert 回到「無 explicit binding」（macro 前就沒設過）"
     (limn/log:get-level 'auto-revert)
     "NIL" "NULL"
     (null actual))

   ;; ───── §6 verbosity filter 核心 invariant ───────────────────────
   ;;
   ;; *最重要*的一段。驗以下 spec：
   ;;
   ;;   1. Ring 永遠記錄（不看 level）
   ;;   2. Wire（送進 C++ GapBuffer）受 effective-level filter
   ;;
   ;; 這保證：post-mortem 開 (get-records) 永遠看得到完整歷史，
   ;; 但 user 開 *messages* buffer 只看到他想看的等級。

   (defstep "6.1a" "clear-messages — 清空 ring 拿乾淨環境"
     (limn/log:clear-messages)
     "NIL" "NULL"
     (null actual))

   (defstep "6.1b" "set-level 'noisy :error — 設高門檻"
     (limn/log:set-level 'noisy :error)
     ":ERROR" "EQ :ERROR"
     (eq actual :error))

   (defstep "6.2" "送 :info 訊息到 :error-門檻 的 ns — message 仍回傳字串"
     (limn/log:message :level :info :ns 'noisy "should-be-filtered")
     "\"should-be-filtered\"" "EQUAL \"should-be-filtered\""
     (equal actual "should-be-filtered"))

   (defstep "6.3" "Ring 有記下這筆（invariant 1：ring 不看 level）"
     (first (limn/log:get-messages 1))
     "\"should-be-filtered\"" "EQUAL \"should-be-filtered\""
     (equal actual "should-be-filtered"))

   (defstep "6.4" "C++ GapBuffer 沒收到（invariant 2：wire 受 level filter）"
     (search "should-be-filtered" (verify-logging::%ms-text))
     "NIL（GapBuffer 字串中找不到此 substring）"
     "NULL — wire sender 被 effective-level 擋下"
     (null actual))

   (defstep "6.5a" "對照組：送 :error 到同 ns、應該通過 filter"
     (limn/log:message :level :error :ns 'noisy "should-be-shown")
     "\"should-be-shown\"" "EQUAL \"should-be-shown\""
     (equal actual "should-be-shown"))

   (defstep "6.5b" "C++ GapBuffer 收到了 :error 那行"
     (if (search "should-be-shown" (verify-logging::%ms-text)) t nil)
     "T" "EQ T"
     (eq actual t))

   ;; ───── §7 wire 格式驗證 ─────────────────────────────────────────
   ;;
   ;; 驗 install-log-wire-sender 寫的格式 prefix：
   ;;   [HH:MM:SS LEVEL ns] text
   ;; LEVEL 是 5 字元 padded（INFO ⎵ / WARN ⎵），ns 是 lowercase
   ;; symbol-name + dot 保留，format args 正確展開（~A → 42）。

   (defstep "7.1" "Wire 格式 prefix [HH:MM:SS WARN  my-test.sub] x=42 正確"
     (progn
       (limn/log:clear-messages)
       (limn/log:message :level :warn :ns 'my-test.sub "x=~A" 42)
       (verify-logging::%ms-text))
     "字串結尾含 [HH:MM:SS WARN  my-test.sub] x=42"
     "regex /\\[\\d{2}:\\d{2}:\\d{2} WARN  my-test\\.sub\\] x=42/ 命中"
     (and (stringp actual)
          (cl-ppcre:scan
           "\\[\\d{2}:\\d{2}:\\d{2} WARN  my-test\\.sub\\] x=42"
           actual)))

   ;; ───── §9 stop/start sender 卸載 — *必須最後* ───────────────────
   ;;
   ;; 9.2a 會把 session 砍掉，9.2b 之後任何 wire call 都會 error。
   ;; 9.3 確認 sender NIL 時 message 仍只走 ring 不 crash。

   (defstep "9.1" "現在 *log-wire-sender* 是有裝的（start 安裝了）"
     (functionp limn/log:*log-wire-sender*)
     "T" "EQ T（sender 是個 function）"
     (eq actual t))

   (defstep "9.2a" "(limn:stop) 回 T"
     (limn:stop)
     "T" "EQ T"
     (eq actual t))

   (defstep "9.2b" "Stop 後 *log-wire-sender* 自動卸下變 NIL"
     limn/log:*log-wire-sender*
     "NIL" "NULL"
     (null actual))

   (defstep "9.3" "Post-stop 還能 log（純 ring、沒 wire、不 crash）"
     (progn (limn/log:message "no wire here")
            (first (limn/log:get-messages 1)))
     "\"no wire here\"" "EQUAL \"no wire here\""
     (equal actual "no wire here"))))

;;; ── runner UI ────────────────────────────────────────────────────────

(defun %read-key ()
  "讀一行 stdin、剝掉前後空白與換行。"
  (force-output)
  (string-trim '(#\Space #\Tab #\Return)
               (or (read-line *standard-input* nil "") "")))

(defun %summary (aborted)
  "印 summary block + copy-paste block。ABORTED 表示是 user 中途按 q。"
  (let* ((results (reverse *results*))
         (pass (count :pass results :key #'second))
         (fail (count :fail results :key #'second))
         (skip (count :skip results :key #'second)))
    (terpri) (terpri)
    (format t "============================================================~%")
    (format t "  總結                                                       ~%")
    (format t "============================================================~%")
    (format t "  PASS：~A    FAIL：~A    SKIP：~A~A~%~%"
            pass fail skip (if aborted "    （中途中止）" ""))
    (when (plusp fail)
      (format t "  失敗的 step：~%")
      (dolist (r results)
        (when (eq (second r) :fail)
          (format t "    [~A] actual = ~A~%"
                  (first r) (%trunc (third r) 200))))
      (terpri))
    (format t "------------------------------------------------------------~%")
    (format t "  複製下面這段貼回 chat 給 Claude：                          ~%")
    (format t "------------------------------------------------------------~%")
    (format t "verify-logging-v037: ~A PASS / ~A FAIL / ~A SKIP~A~%"
            pass fail skip (if aborted " (aborted)" ""))
    (dolist (r results)
      (format t "  ~6A ~A~A~%"
              (first r)
              (case (second r)
                (:pass "PASS")
                (:fail "FAIL")
                (:skip "SKIP"))
              (if (eq (second r) :fail)
                  (format nil "  | ~A" (%trunc (third r) 160))
                  "")))
    (format t "============================================================~%")
    (when (or (plusp fail) aborted)
      (format t "  （SBCL 仍在 REPL 提示符。打 (sb-ext:exit) 退出。）~%"))))

(defun run ()
  "主入口。逐 step inject、eval、判斷、互動 pause、收結果。"
  (setf *results* nil)
  (terpri)
  (format t "============================================================~%")
  (format t "  v0.37 logging 自動驗證 — 共 ~A 個 step                     ~%"
          (length *steps*))
  (format t "  每 step 後：ENTER = 下一步、q = 中止、s = 跳過           ~%")
  (format t "============================================================~%")
  (block runner
    (loop for step in *steps*
          for i from 1
          do (terpri)
             (format t "[~A/~A] ~A — ~A~%"
                     i (length *steps*)
                     (vstep-id step) (vstep-desc step))
             (format t "  Form     ：~S~%" (vstep-form step))
             (format t "  Expected ：~A~%" (vstep-expected step))
             (format t "  Predicate：~A~%" (vstep-pred-desc step))
             (let* ((actual (handler-case (eval (vstep-form step))
                              (error (e)
                                (format nil "<eval 拋出: ~A>" e))))
                    (pass   (handler-case (funcall (vstep-pred step) actual)
                              (error () nil)))
                    (display (%trunc actual)))
               (format t "  Actual   ：~A~%" display)
               (format t "  Verdict  ：~A~%" (if pass "✓ PASS" "✗ FAIL"))
               (format t "  [ENTER=下一步 / q=中止 / s=跳過]：")
               (let ((key (%read-key)))
                 (cond
                   ((string-equal key "q")
                    (push (list (vstep-id step)
                                (if pass :pass :fail) display)
                          *results*)
                    (%summary t)
                    (return-from runner))
                   ((string-equal key "s")
                    (push (list (vstep-id step) :skip display) *results*))
                   (t
                    (push (list (vstep-id step)
                                (if pass :pass :fail) display)
                          *results*)))))
          finally (%summary nil))))

;;; ── §Q 視覺驗證 — 用眼睛看 Qt 視窗 ───────────────────────────────────
;;;
;;; 跟 run 不同：這個會把主 widget 切到 *messages*，然後 fire 幾條
;;; (limn/log:message ...)、每條中間 sleep 1 秒，讓 user 真的看到行
;;; 一行一行加進視窗（test C++ 端 v0.37 的 widget sync 修補真的 work）。
;;;
;;; 必須 HEADLESS=0 啟動才有意義。launcher (verify-logging-v037-visible.sh)
;;; 會自動帶這 env。

(defvar *visible-results* nil
  "Visible 驗證的兩階段結果 (Q.1, Q.2)，summary 印出來給 user copy。")

(defun %ask-visible (id question valid-keys)
  "印 QUESTION、讀一個 key、return 標準化過的字串（小寫）。
   只接受 VALID-KEYS 裡的、其他重問。"
  (loop
    (format t "  回答 [~{~A~^/~}]：" valid-keys)
    (let ((k (string-downcase (%read-key))))
      (cond
        ((member k valid-keys :test #'string=)
         (push (list id k) *visible-results*)
         (return k))
        (t
         (format t "  ⚠  只能輸入 ~{~A~^ / ~}，請重打。~%" valid-keys))))))

(defun run-visible ()
  "兩階段視覺驗證：
     Q.1 — 7 行 demo (顯示 + prefix 是否正確)
     Q.2 — 80 行 stress (auto-scroll 是否跟到最後一行)
   兩段都跑完才印 summary。"
  (setf *visible-results* nil)
  (terpri)
  (format t "============================================================~%")
  (format t "  v0.37 logging 視覺驗證 — 用眼睛看 Qt 視窗                 ~%")
  (format t "  共 2 階段：Q.1 (7 行 demo) → Q.2 (80 行 scroll stress)    ~%")
  (format t "============================================================~%~%")

  ;; ── 環境準備 ────────────────────────────────────────────────────
  (format t "→ 清 ring + 重設 verbosity ...~%")
  (limn/log:clear-messages)
  (when (hash-table-p limn/log:*log-levels*)
    (clrhash limn/log:*log-levels*))
  (setf limn/log:*default-log-level* :debug)

  (format t "→ buffer/show *messages* 到 w1（Qt 視窗應該變空白 text view）...~%")
  (let ((r (limn:call "buffer/show" :|buffer-id| "*messages*" :|win-id| "w1")))
    (unless (eq (getf r :|ok|) t)
      (format t "  ✗ buffer/show 失敗：~S~%" r)
      (format t "  Q.0 [FAIL: wire 切換失敗]、後續略過~%")
      (return-from run-visible nil))
    (format t "  ✓ ok~%"))
  (sleep 0.8)

  ;; ── Q.1：7 行 demo ──────────────────────────────────────────────
  (terpri)
  (format t "============================================================~%")
  (format t "  Q.1 / 2 — 7 行 demo                                       ~%")
  (format t "============================================================~%")
  (format t "→ 接下來 7 秒、每秒 fire 1 條。請盯 Qt 視窗看行慢慢長出來：~%~%")
  (loop for i from 1 to 5
        do (let ((msg (format nil "live demo line ~A" i)))
             (format t "    [shell] sending: ~S~%" msg)
             (force-output)
             (limn/log:message msg)
             (sleep 1.0)))
  (let ((m "warning from demo namespace"))
    (format t "    [shell] sending :warn :ns demo : ~S~%" m)
    (force-output)
    (limn/log:message :level :warn :ns 'demo m)
    (sleep 1.0))
  (let ((m "error from demo.sub"))
    (format t "    [shell] sending :error :ns demo.sub : ~S~%" m)
    (force-output)
    (limn/log:message :level :error :ns 'demo.sub m)
    (sleep 0.5))

  (terpri)
  (format t "  Q.1 預期 Qt 視窗顯示 7 行（順序由上而下）：~%")
  (format t "  ─────────────────────────────────────────~%")
  (format t "    [HH:MM:SS INFO  default] live demo line 1~%")
  (format t "    [HH:MM:SS INFO  default] live demo line 2~%")
  (format t "    [HH:MM:SS INFO  default] live demo line 3~%")
  (format t "    [HH:MM:SS INFO  default] live demo line 4~%")
  (format t "    [HH:MM:SS INFO  default] live demo line 5~%")
  (format t "    [HH:MM:SS WARN  demo] warning from demo namespace~%")
  (format t "    [HH:MM:SS ERROR demo.sub] error from demo.sub~%")
  (format t "  ─────────────────────────────────────────~%")
  (format t "  *只驗*：行有出現嗎、prefix 對嗎？scroll 不論（行太少看不出）。~%~%")
  (format t "    y = 7 行都出現、prefix 對~%")
  (format t "    p = 部分對（vimaybe prefix 怪 / 漏行 / 順序錯）~%")
  (format t "    n = Qt 視窗空白、沒看到任何訊息~%")
  (%ask-visible "Q.1" "" '("y" "p" "n"))

  ;; ── Q.2：80 行 stress、觀察 scroll ─────────────────────────────
  (terpri)
  (format t "============================================================~%")
  (format t "  Q.2 / 2 — 80 行 scroll stress                             ~%")
  (format t "============================================================~%")
  (format t "→ 接下來 ~~4 秒、快速 fire 80 條，會把 widget 灌滿讓 scrollbar~%")
  (format t "  出現。看 Qt 視窗 viewport 有沒有跟著最後一行往下捲：~%~%")
  (loop for i from 1 to 80
        do (limn/log:message
            "stress line ~3,'0D — filler text padding padding padding padding padding"
            i)
           (sleep 0.05))
  (sleep 0.5)
  (format t "  Q.2 預期 Qt 視窗：~%")
  (format t "  ─────────────────────────────────────────~%")
  (format t "    1. 右側 scrollbar 出現（內容超過視窗高度）~%")
  (format t "    2. *最後一行* 顯示為 [HH:MM:SS INFO  default] stress line 080 ...~%")
  (format t "       而不是停在 line 030 / 040 中間~%")
  (format t "    3. （滑鼠去拉 scrollbar 上去能看到 stress line 001、~%")
  (format t "        放手後新訊息會把你帶回最底 — 不過這個 stress 結束了、~%")
  (format t "        沒新訊息進來、所以不會再 auto-scroll；自己拉沒問題）~%")
  (format t "  ─────────────────────────────────────────~%~%")
  (format t "    y = 最後一行是 stress line 080、scrollbar 有出現~%")
  (format t "    p = scrollbar 有出現、但 viewport 停在中間沒跟到 080~%")
  (format t "    n = Qt 視窗根本沒長出 stress lines（或仍空白）~%")
  (%ask-visible "Q.2" "" '("y" "p" "n"))

  ;; ── Summary ──────────────────────────────────────────────────────
  (terpri) (terpri)
  (format t "============================================================~%")
  (format t "  視覺驗證總結                                              ~%")
  (format t "============================================================~%")
  (dolist (r (reverse *visible-results*))
    (let ((id (first r)) (ans (second r)))
      (format t "    ~A : ~A  (~A)~%"
              id
              (cond ((string= ans "y") "✓ PASS")
                    ((string= ans "p") "⚠  PARTIAL")
                    ((string= ans "n") "✗ FAIL"))
              (cond ((string= id "Q.1") "顯示 + prefix")
                    ((string= id "Q.2") "auto-scroll 跟到底")))))
  (terpri)
  (format t "------------------------------------------------------------~%")
  (format t "  複製下面這段貼回 chat 給 Claude：                          ~%")
  (format t "------------------------------------------------------------~%")
  (format t "verify-logging-v037-visible:~%")
  (dolist (r (reverse *visible-results*))
    (let ((id (first r)) (ans (second r)))
      (format t "  ~A ~A~%"
              id
              (cond ((string= ans "y") "PASS")
                    ((string= ans "p") "PARTIAL")
                    ((string= ans "n") "FAIL")))))
  (format t "============================================================~%")
  (format t "  （SBCL 還在 REPL。打 (sb-ext:exit) 退出。）~%"))
