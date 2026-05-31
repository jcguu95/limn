;;;; fuzzy-walkthrough.lisp — Fuzzy Selector §3–§6 Qt 視覺驗證
;;;;
;;;; 由 scratch/run-fuzzy-walkthrough.sh 呼叫。
;;;; 進入時：limn 已起動、tutorial.pdf 已開、Qt 視窗可見。
;;;; 共 6 步，全部是用眼睛看 Qt 視窗 + 在 Qt 視窗按鍵。

(in-package #:cl-user)

(sleep 1.5) ; 讓 Qt 視窗畫完

;; ─── helpers ────────────────────────────────────────────────────────────

(defvar *results* '())
(defvar *step-n* 0)
(defvar *total* 6)

(defun rline ()
  (finish-output)
  (string-trim '(#\Space #\Tab #\Newline #\Return)
               (or (read-line *standard-input* nil "") "")))

(defun banner (title)
  (incf *step-n*)
  (format t "~&~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
  (format t "  STEP ~a/~a   ~a~%" *step-n* *total* title)
  (format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%"))

(defun do-step (title &key action do-in-qt expected)
  (banner title)
  ;; 自動執行 Lisp side 動作
  (when action
    (format t " ▶ 自動執行...~%")
    (handler-case (funcall action)
      (error (e) (format t "   ⚠ 執行失敗：~a~%" e))))
  ;; 告訴使用者要做什麼
  (when do-in-qt
    (format t " ▶ 在 Qt 視窗操作：~%")
    (dolist (l (with-input-from-string (s do-in-qt)
                 (loop for l = (read-line s nil) while l collect l)))
      (format t "   ~a~%" l)))
  ;; 預期結果
  (when expected
    (format t " ▶ 預期看到：~%")
    (dolist (l (with-input-from-string (s expected)
                 (loop for l = (read-line s nil) while l collect l)))
      (format t "   ~a~%" l)))
  ;; 等待使用者確認
  (format t "─────────────────────────────────────────────────────────~%")
  (format t " [RET]=PASS   n=FAIL（可附備注）   s=跳過   q=離開~%")
  (format t " > ")
  (let ((input (rline)))
    (cond
      ((member input '("q" "Q") :test #'string=)
       (push (list *step-n* title :quit nil) *results*)
       (throw 'done nil))
      ((member input '("n" "N") :test #'string=)
       (format t " 備注（可空白）：")
       (let ((c (rline)))
         (push (list *step-n* title :fail c) *results*)
         (format t " → ✗ FAIL~%")))
      ((member input '("s" "S") :test #'string=)
       (push (list *step-n* title :skip nil) *results*)
       (format t " → ⊘ SKIP~%"))
      (t
       (push (list *step-n* title :pass nil) *results*)
       (format t " → ✓ PASS~%")))))

;; ─── 前置：開啟 fuzzy selector ──────────────────────────────────────────

(format t "~&~%
╔══════════════════════════════════════════════════════╗
║   Fuzzy Selector §3–§6 — Qt 視覺驗證                ║
║   branch: deepseek/fuzzy-selector-ui                 ║
╚══════════════════════════════════════════════════════╝

  6 個步驟，全部都要看 Qt 視窗。
  操作方式：
    RET          → PASS
    n + RET      → FAIL（可留備注）
    s + RET      → 跳過
    q + RET      → 中途離開

  建議把 terminal 和 Qt 視窗並排。
")
(format t "按 RET 開始...")
(rline)

;; 開啟 fuzzy selector
(setf limn/completion:*enable-fuzzy-selector* t)

;; ─── 步驟 ───────────────────────────────────────────────────────────────

(catch 'done

  ;; STEP 1：開啟 minibuffer
  (do-step "§3 — minibuffer 出現輸入框"
    :action (lambda ()
              (let ((call (find-symbol "CALL" '#:limn)))
                (when call
                  (ignore-errors
                    (funcall (symbol-function call)
                             "minibuffer/open"
                             :|prompt| "fuzzy 測試：")))))
    :expected "Qt 視窗底部出現「fuzzy 測試：」輸入框")

  ;; STEP 2：傳送候選，應出現垂直清單
  (do-step "§3 — 候選清單垂直顯示"
    :action (lambda ()
              (let ((call (find-symbol "CALL" '#:limn)))
                (when call
                  (ignore-errors
                    (funcall (symbol-function call)
                             "minibuffer/set-candidates"
                             :|candidates| '("apple" "apricot" "banana" "cherry" "date")
                             :|index| 0
                             :|total| 5)))))
    :expected "minibuffer 上方出現垂直候選清單：
  ▶ apple   ← 第一項高亮
    apricot
    banana
    cherry
    date")

  ;; STEP 3：注入 index=1 → apricot 高亮
  (do-step "§3 渲染 — 高亮移到第 2 項"
    :action (lambda ()
              (let ((call (symbol-function (find-symbol "CALL" '#:limn))))
                (funcall call "minibuffer/set-candidates"
                         :|candidates| '("apple" "apricot" "banana" "cherry" "date")
                         :|index| 1
                         :|total| 5)))
    :expected "候選清單更新，高亮從 apple 移到 apricot（第二項亮起）")

  ;; STEP 4：注入 index=0 → 回到 apple
  (do-step "§3 渲染 — 高亮移回第 1 項"
    :action (lambda ()
              (let ((call (symbol-function (find-symbol "CALL" '#:limn))))
                (funcall call "minibuffer/set-candidates"
                         :|candidates| '("apple" "apricot" "banana" "cherry" "date")
                         :|index| 0
                         :|total| 5)))
    :expected "高亮回到 apple（第一項亮起）")

  ;; STEP 5：RET 確認選取
  (do-step "§4 — RET 確認選取"
    :do-in-qt "按 RET（Enter）"
    :expected "minibuffer 和候選清單消失，視窗恢復正常
（若有 completing-read callback，選中項目為 apple）")

  ;; STEP 6：重新開啟並用 C-g 取消
  (do-step "§4 — C-g 取消並關閉"
    :action (lambda ()
              (let ((call (find-symbol "CALL" '#:limn)))
                (when call
                  (ignore-errors
                    (funcall (symbol-function call)
                             "minibuffer/open" :|prompt| "取消測試："))
                  (ignore-errors
                    (funcall (symbol-function call)
                             "minibuffer/set-candidates"
                             :|candidates| '("選項一" "選項二" "選項三")
                             :|index| 0 :|total| 3)))))
    :do-in-qt "按 C-g（Ctrl + g）"
    :expected "minibuffer 和候選清單消失，視窗恢復正常
（不應有任何選取結果）"))

;; 關閉 fuzzy selector
(setf limn/completion:*enable-fuzzy-selector* nil)

;; ─── 最終報告 ────────────────────────────────────────────────────────────

(format t "~&~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
(format t "  Fuzzy Selector — 視覺驗證結果~%")
(format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
(let ((pass 0) (fail 0) (skip 0))
  (dolist (r (reverse *results*))
    (destructuring-bind (n title status comment) r
      (format t "  ~a  STEP ~a  ~a~%"
              (case status (:pass "✓") (:fail "✗") (:skip "⊘") (t "Q"))
              n title)
      (when (and comment (not (string= comment "")))
        (format t "       💬 ~a~%" comment))
      (case status (:pass (incf pass)) (:fail (incf fail)) (:skip (incf skip)))))
  (format t "~%  PASS ~a   FAIL ~a   SKIP ~a~%" pass fail skip)
  (cond
    ((zerop fail)
     (format t "~%  🎉 全部通過！可以 merge deepseek/fuzzy-selector-ui~%"))
    (t
     (format t "~%  ⚠  ~a 個失敗——請把備注回報，修正後再 merge。~%" fail))))
(format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%~%")
