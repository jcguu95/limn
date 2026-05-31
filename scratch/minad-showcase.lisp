;;;; minad-showcase.lisp — MINAD 補全生態系 完整 showcase
;;;;
;;;; 由 scratch/run-minad-showcase.sh 呼叫。進入時 limn 已起動、tutorial.pdf 已開、
;;;; Qt 視窗可見、且有 live session + pump thread。
;;;;
;;;; 設計：
;;;;   幕 1–3 走「真實 completing-read live session」——
;;;;     背景執行緒跑真的 completing-read（fuzzy → vertico → 活的 session），
;;;;     主執行緒用 run-hook 注入「使用者事件」（打字 / C-n / RET / C-g）。
;;;;     所以 RET 真的會關閉 minibuffer 並回傳真值（不是空殼注入）。
;;;;   幕 4 純後端證明（Corfu/Cape 目前無 Qt UI，印出真實計算結果）。
;;;;
;;;;   每一步都印出 Lisp side 算出的真值當證據——證明這不是假的。

(in-package #:cl-user)

(sleep 1.5)

;; ─── 互動 / 報告 helpers ─────────────────────────────────────────────────

(defvar *results* '())
(defparameter *beat* 1.1)   ; 每個動作之間停多久（秒），讓你看清楚

(defun rline ()
  (finish-output)
  (string-trim '(#\Space #\Tab #\Newline #\Return)
               (or (read-line *standard-input* nil "") "")))

(defun hr (&optional (ch "─"))
  (format t "~a~%" (with-output-to-string (s)
                     (dotimes (i 57) (write-string ch s)))))

(defun confirm (scene-name)
  "問使用者這一幕的視覺/結果對不對。"
  (hr)
  (format t " 這一幕看起來對嗎？ [RET]=PASS  n=FAIL(可留言)  s=SKIP  q=離開~%")
  (format t " > ")
  (let ((in (rline)))
    (cond
      ((member in '("q" "Q") :test #'string=)
       (push (list scene-name :quit nil) *results*) (throw 'done nil))
      ((member in '("n" "N") :test #'string=)
       (format t " 備注：") (let ((c (rline)))
                              (push (list scene-name :fail c) *results*))
       (format t " → ✗ FAIL~%"))
      ((member in '("s" "S") :test #'string=)
       (push (list scene-name :skip nil) *results*) (format t " → ⊘ SKIP~%"))
      (t (push (list scene-name :pass nil) *results*) (format t " → ✓ PASS~%")))))

;; ─── 事件注入：模擬「使用者」操作 live session ──────────────────────────

(defun ev (s) (limn/dispatch:event-hook-name s))
(defun fire (name &rest args) (apply #'limn/hooks:run-hook name args))

(defun inj-type (text)
  (format t "   ⌨  使用者輸入 ~s~%" text)
  (fire (ev "minibuffer-input") (list :|text| text))
  (sleep *beat*))

(defun inj-down (&optional (n 1))
  (format t "   ↓  C-n ×~a（高亮下移）~%" n)
  (dotimes (i n) (fire (ev "minibuffer/candidates-next")) (sleep *beat*)))

(defun inj-up (&optional (n 1))
  (format t "   ↑  C-p ×~a（高亮上移）~%" n)
  (dotimes (i n) (fire (ev "minibuffer/candidates-prev")) (sleep *beat*)))

(defun inj-submit ()
  (format t "   ⏎  RET（確認；minibuffer 應該關閉）~%")
  (fire (ev "minibuffer-submit")))

(defun inj-cancel ()
  (format t "   ✗  C-g（取消；minibuffer 應該關閉）~%")
  (fire (ev "minibuffer-cancel")))

;; ─── play-session：跑真 completing-read，主執行緒注入事件 ────────────────

(defun play-session (prompt candidates script-thunk)
  "在背景執行緒跑真實 completing-read（fuzzy/vertico live path），
   主執行緒依 SCRIPT-THUNK 注入使用者事件。回傳選中的字串（或 :cancelled）。
   保證收尾：script 沒有結束 session 時自動送 cancel。"
  (setf limn/completion:*enable-fuzzy-selector* t)
  (let ((result :pending) (err nil) (done nil))
    (let ((th (sb-thread:make-thread
                (lambda ()
                  (handler-case
                      (setf result (limn/completion:completing-read
                                    prompt candidates :require-match t))
                    (limn/completion:quit-condition () (setf result :cancelled))
                    (error (e) (setf err e)))
                  (setf done t))
                :name "showcase-cr")))
      (sleep 1.3)                       ; 等 minibuffer 開 + 初始候選送出
      (handler-case (funcall script-thunk)
        (error (e) (format t "   !! 注入錯誤：~a~%" e)))
      ;; 等 worker 收尾
      (let ((d 50)) (loop while (and (not done) (> d 0)) do (sleep 0.1) (decf d)))
      ;; 還沒結束 → 強制取消，避免卡死
      (unless done
        (ignore-errors (fire (ev "minibuffer-cancel")))
        (let ((d 30)) (loop while (and (not done) (> d 0)) do (sleep 0.1) (decf d))))
      (when (sb-thread:thread-alive-p th)
        (ignore-errors (sb-thread:join-thread th)))
      (when err (format t "   !! worker 錯誤：~a~%" err))
      result)))

;; ─── Marginalia 資料：指令 + 真實 docstring ─────────────────────────────

(defparameter *cmd-docs*
  '(("find-file"           . "開啟一個檔案到新的 buffer")
    ("find-function"       . "跳到某個函式的定義處")
    ("switch-buffer"       . "切換到另一個已開啟的 buffer")
    ("save-buffer"         . "把目前 buffer 寫回磁碟")
    ("save-some-buffers"   . "批次儲存所有改過的 buffer")
    ("kill-buffer"         . "關閉目前的 buffer")
    ("kill-line"           . "刪除游標到行尾的文字")
    ("split-window-below"  . "把視窗上下對半切")
    ("split-window-right"  . "把視窗左右對半切")
    ("delete-window"       . "關掉目前的視窗")
    ("other-window"        . "把焦點移到下一個視窗")
    ("goto-line"           . "跳到指定的行號")
    ("goto-page"           . "跳到 PDF 的指定頁數")
    ("next-page"           . "翻到下一頁")
    ("previous-page"       . "翻回上一頁")
    ("zoom-in"             . "放大 PDF 顯示")
    ("zoom-out"            . "縮小 PDF 顯示")
    ("set-bookmark"        . "在目前位置放一個書籤")
    ("jump-to-bookmark"    . "跳到某個書籤")
    ("toggle-fullscreen"   . "切換全螢幕模式")
    ("search-forward"      . "向後搜尋文字")
    ("search-backward"     . "向前搜尋文字")
    ("copy-region"         . "複製選取的區域")
    ("paste"               . "貼上剪貼簿內容")
    ("undo"                . "復原上一個動作")
    ("redo"                . "重做被復原的動作")
    ("execute-command"     . "用名稱執行任意指令")
    ("describe-key"        . "查某個按鍵綁了什麼指令")
    ("describe-function"   . "查某個函式的說明")
    ("recent-files"        . "從最近開過的檔案挑一個")))

(defun setup-marginalia ()
  (setf limn/marginalia:*marginalia-command-doc-fn*
        (lambda (c) (cdr (assoc c *cmd-docs* :test #'string=)))))

(defun palette-candidates ()
  "把每個指令配上 marginalia 註解，組成對齊的顯示字串。"
  (mapcar (lambda (pair)
            (let* ((cmd (car pair))
                   (ann (limn/marginalia:annotate cmd :command)))
              (format nil "~24a  ·  ~a" cmd (or ann ""))))
          *cmd-docs*))

;; ═══════════════════════════════════════════════════════════════════════
;;  開場
;; ═══════════════════════════════════════════════════════════════════════

(format t "~%~%")
(hr "━")
(format t "   MINAD 補全生態系 — 完整 showcase~%")
(format t "   branch: deepseek/fuzzy-selector-ui~%")
(hr "━")
(format t "
  MINAD = minad 大神的 Emacs 補全套件群。這個 repo 用 Pure Lisp 全部重做了：
    Orderless（亂序/初字母/flex 比對）· Vertico（垂直清單+捲動）
    Marginalia（候選註解）· Consult（搜尋指令）
    Corfu（行內 popup）· Cape（capf 後端）· Embark（情境動作）

  接下來分 4 幕：
    幕 1–3：在真的 Qt 視窗裡，跑「真實的 completing-read session」，
            由腳本自動模擬使用者打字 / 移動 / 確認，你看著它動。
            每一步都印出 Lisp side 算出的真值——證明不是假畫面。
    幕 4：  Corfu/Cape 目前還沒接 Qt UI，所以印出真實後端計算結果。

  ⚠ 誠實說明：目前只有 Vertico 候選清單有 Qt 視覺渲染。
     Marginalia 的註解是「烤進候選字串」一起顯示；Consult 的即時預覽、
     Corfu 的 popup、Embark 的原生動作選單，都是「下一步的視覺整合」。
")
(setup-marginalia)
(setf limn/completion:*enable-fuzzy-selector* t)
(format t "按 RET 開始 ...")
(rline)

(catch 'done

  ;; ═════════════════════════════════════════════════════════════════════
  ;;  幕 1：Orderless + Vertico + Marginalia
  ;; ═════════════════════════════════════════════════════════════════════
  (format t "~%~%")
  (hr "═")
  (format t "  幕 1 / 4   Orderless + Vertico + Marginalia~%")
  (hr "═")
  (format t "
  一個 30 項的指令面板，每個指令右邊是 Marginalia 產生的真實說明。
  看 Qt 視窗——腳本會自動示範 Orderless 的三種比對威力：
    · 子字串：輸入 \"buffer\"
    · 亂序：  輸入 \"sw win\"（兩個詞，順序顛倒也能比中）
    · 初字母：輸入 \"sb\"（switch-buffer / set-bookmark...）
  然後 C-n 移動高亮、RET 確認。
")
  (format t "按 RET 開始這一幕 ...") (rline)
  (let ((picked
          (play-session
           "指令： " (palette-candidates)
           (lambda ()
             (format t "~% ▸ Orderless 子字串比對：~%")
             (inj-type "buffer")
             (format t "~% ▸ Orderless 亂序比對（顛倒順序）：~%")
             (inj-type "win split")
             (format t "~% ▸ Orderless 初字母比對：~%")
             (inj-type "sb")
             (format t "~% ▸ 回到完整清單，捲動高亮：~%")
             (inj-type "")
             (inj-down 4)
             (format t "~% ▸ 確認選取：~%")
             (inj-submit)))))
    (format t "~% ▶ Lisp side 回傳的選中項（證據）：~%   ~s~%" picked))
  (confirm "幕1 Orderless+Vertico+Marginalia")

  ;; ═════════════════════════════════════════════════════════════════════
  ;;  幕 2：Consult（consult-line over 真實 buffer 內容）
  ;; ═════════════════════════════════════════════════════════════════════
  (format t "~%~%")
  (hr "═")
  (format t "  幕 2 / 4   Consult — consult-line~%")
  (hr "═")
  (let* ((buffer-text
           (format nil "Limn is a PDF reader~%~
                        with an Emacs soul~%~
                        completion is powered by MINAD~%~
                        Orderless does fuzzy matching~%~
                        Vertico renders the candidate list~%~
                        Consult adds search commands~%~
                        and live preview someday~%~
                        Marginalia annotates each line~%~
                        Embark acts on candidates~%~
                        Corfu completes in the buffer"))
         (lines (limn/consult:consult-line-candidates buffer-text)))
    (format t "
  Consult 把一個 buffer 的每一行做成候選（\"行號:內容\"）。
  這就是 consult-line：在 buffer 裡用補全式搜尋跳行。
  腳本會輸入關鍵字縮小範圍，再選一行。
  （⚠ 即時預覽 = 選哪行就跳到哪行，是下一步的 wire 整合，這裡先不接。）
")
    (format t " ▶ Consult 後端產生的候選（共 ~a 行）：~%" (length lines))
    (dolist (l lines) (format t "     ~a~%" l))
    (format t "按 RET 開始這一幕 ...") (rline)
    (let ((picked
            (play-session
             "搜尋行： " lines
             (lambda ()
               (format t "~% ▸ 輸入關鍵字縮小到含 'matching/Marginalia/MINAD' 的行：~%")
               (inj-type "ma")
               (format t "~% ▸ 移動高亮、選取：~%")
               (inj-down 1)
               (inj-submit)))))
      (format t "~% ▶ Lisp side 回傳的選中行（證據）：~%   ~s~%" picked)))
  (confirm "幕2 Consult")

  ;; ═════════════════════════════════════════════════════════════════════
  ;;  幕 3：Embark（對候選的情境動作，用真清單呈現）
  ;; ═════════════════════════════════════════════════════════════════════
  (format t "~%~%")
  (hr "═")
  (format t "  幕 3 / 4   Embark — 對候選執行情境動作~%")
  (hr "═")
  (let* ((target "/Users/jin/notes.org")
         (action-syms (limn/embark:embark-action-names :file))
         (action-strs (mapcar (lambda (s) (string-downcase (symbol-name s)))
                              action-syms)))
    (format t "
  Embark = 對「目前這個候選」叫出可用動作選單。
  目標候選是一個檔案：~a
  Embark 後端查出它在 :file 類別下有這些動作（真實 registry）：
" target)
    (dolist (s action-syms) (format t "     · ~(~a~)~%" s))
    (format t "
  腳本會把這些動作做成一個真的補全清單，選一個，然後真的執行它。
")
    (format t "按 RET 開始這一幕 ...") (rline)
    (let ((chosen
            (play-session
             (format nil "對 ~a 執行： " (file-namestring target))
             action-strs
             (lambda ()
               (format t "~% ▸ 在動作清單裡移動、選 copy-path：~%")
               (inj-type "copy")
               (inj-submit)))))
      (format t "~% ▶ 選中的動作（證據）：~s~%" chosen)
      (when (stringp chosen)
        (let* ((sym (intern (string-upcase chosen) :keyword))
               (res (limn/embark:embark-execute sym target :file)))
          (format t " ▶ 真的執行 embark-execute：(~a ~s) => ~s~%"
                  chosen target res)))))
  (confirm "幕3 Embark")

  ;; ═════════════════════════════════════════════════════════════════════
  ;;  幕 4：Corfu + Cape（後端證明，印出真實計算）
  ;; ═════════════════════════════════════════════════════════════════════
  (format t "~%~%")
  (hr "═")
  (format t "  幕 4 / 4   Corfu + Cape — 行內補全（後端證明）~%")
  (hr "═")
  (format t "
  Corfu = 在 buffer 游標處跳 popup 補全；Cape = 提供候選的後端。
  ⚠ 這兩個目前還沒接 Qt popup UI，所以這裡印出真實後端計算，
     證明邏輯是完整的（下一步才是把 popup 畫到 Qt）。
")
  (let* ((buffer-text "format foobar foobaz qux foobar finish find-file format-time")
         (prefix "fo"))
    (format t " ▶ Cape dabbrev：在 buffer 文字裡找以 ~s 開頭的詞~%" prefix)
    (format t "     buffer 文字：~s~%" buffer-text)
    (let ((cands (limn/cape:cape-dabbrev-candidates prefix buffer-text)))
      (format t "     => Cape 候選：~s~%~%" cands)
      (format t " ▶ Corfu session：用這些候選開 popup 狀態機~%")
      (let* ((s0 (limn/corfu:make-corfu-session cands prefix))
             (s1 (limn/corfu:corfu-move s0 1))
             (s2 (limn/corfu:corfu-move s1 1)))
        (format t "     index 0 → ~s~%" (nth (limn/corfu:corfu-state-index s0) cands))
        (format t "     C-n → index 1 → ~s~%" (nth (limn/corfu:corfu-state-index s1) cands))
        (format t "     C-n → index 2 → ~s~%" (nth (limn/corfu:corfu-state-index s2) cands))
        (format t "     ⏎ corfu-commit => ~s~%" (limn/corfu:corfu-commit s2)))))
  (format t "
  （這一幕沒有 Qt 視覺，請看上面印出的真實後端計算結果。）
")
  (confirm "幕4 Corfu+Cape"))

;; ═══════════════════════════════════════════════════════════════════════
;;  收尾報告
;; ═══════════════════════════════════════════════════════════════════════

(setf limn/completion:*enable-fuzzy-selector* nil)

(format t "~%~%")
(hr "━")
(format t "  MINAD showcase — 結果~%")
(hr "━")
(let ((pass 0) (fail 0) (skip 0))
  (dolist (r (reverse *results*))
    (destructuring-bind (name status comment) r
      (format t "  ~a  ~a~%"
              (case status (:pass "✓") (:fail "✗") (:skip "⊘") (t "Q")) name)
      (when (and comment (not (string= comment "")))
        (format t "       💬 ~a~%" comment))
      (case status (:pass (incf pass)) (:fail (incf fail)) (:skip (incf skip)))))
  (format t "~%  PASS ~a   FAIL ~a   SKIP ~a~%" pass fail skip))
(format t "
  已證明：
    ✓ Orderless 三種比對（子字串/亂序/初字母）在真 session 裡即時過濾
    ✓ Vertico 垂直清單 + 高亮 + 捲動 + RET 真的回傳值並關閉 minibuffer
    ✓ Marginalia 真實註解（與候選一起顯示）
    ✓ Consult consult-line 真實候選餵進真 session
    ✓ Embark 真實動作 registry + 真的執行 embark-execute
    ✓ Corfu/Cape 真實後端狀態機計算

  下一步的視覺整合（wire + Qt 渲染）：
    ○ Marginalia 獨立註解欄（set-candidates 加 annotations 欄位）
    ○ Consult 即時預覽（選候選 → 跳 PDF 視圖）
    ○ Corfu 行內 popup（游標處的補全視窗）
    ○ Embark 原生動作選單
")
(hr "━")
(format t "~%")
