;;;; dogfood-guided.lisp — 互動式視窗分割驗收驅動器（Phase 3b）
;;;;
;;;; 設計目標：把 SPLIT-DOGFOOD-CHECKLIST.md 的每一項自動「註入」要 eval 的
;;;; form，並印出「你現在應該在 Qt 視窗看到什麼」，然後等你按一個鍵：
;;;;
;;;;   y + Enter → 確定通過（看到預期結果）
;;;;   n + Enter → 不確定 / 怪怪的 / 壞掉（之後可補一句說明）
;;;;   s + Enter → 略過這一項
;;;;   q + Enter → 直接中止，跳到最後輸出摘要
;;;;
;;;; 跑完會印出一段 markdown 摘要，直接複製貼上即可。
;;;;
;;;; 用法（一行）：
;;;;   HEADLESS=0 /tmp/ph3-split/backend/dogfood-guided.sh
;;;; 或手動：
;;;;   HEADLESS=0 /tmp/ph3-split/backend/run-repl.sh \
;;;;     --load /tmp/ph3-split/backend/dogfood-guided.lisp --eval '(dogfood)'
;;;;
;;;; 這個檔在 cl-user，沿用 repl-helpers.lisp 的 (o)/(sp)/(wf)/(wc)/(vg)/(p)/(wins)。

(in-package #:cl-user)

;;; ── 小工具 ───────────────────────────────────────────────────────────────

(defvar *dogfood-results* nil
  "list of (n title verdict note) — verdict ∈ :pass :unsure :skip。")

(defun %df-page (win-id)
  "讀 WIN-ID 目前頁碼（0-based），讀不到回傳 NIL。"
  (ignore-errors (getf (getf (vg win-id) :|data|) :|page|)))

(defun %df-inject-key (key &optional (n 1) (pause 0.45))
  "對目前 focused 視窗注入 KEY N 次，每次間隔 PAUSE 秒（讓你肉眼看得到翻頁）。"
  (dotimes (i n)
    (limn:call "test/inject-key" :|key| key)
    (sleep pause)))

(defun %df-read-verdict ()
  "讀一行；回傳 (verdict . note)。verdict ∈ :pass :unsure :skip :abort。"
  (finish-output)
  (let* ((line (or (read-line *standard-input* nil "") ""))
         (c    (and (plusp (length line)) (char-downcase (char line 0)))))
    (case c
      ((#\y) (cons :pass   nil))
      ((#\q) (cons :abort  nil))
      ((#\s) (cons :skip   nil))
      (t     ;; n / 空白 / 其它 → 視為不確定，給機會補一句
       (format t "    想補一句說明嗎？（直接 Enter 跳過）：")
       (finish-output)
       (let ((note (string-trim '(#\Space #\Tab)
                                (or (read-line *standard-input* nil "") ""))))
         (cons :unsure (if (plusp (length note)) note nil)))))))

(defun %df-step (n title expectation &key (auto nil))
  "印出第 N 步的標題與預期；若 AUTO 非空則它是 (verdict . note)（不需問人，
   程式自己判定）；否則問人。把結果記進 *dogfood-results*，回傳 verdict。"
  (format t "~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
  (format t "【第 ~a 項】~a~%" n title)
  (format t "  預期：~a~%" expectation)
  (let* ((vn (cond
               (auto
                (format t "  → 程式自動判定：~a~@[（~a）~]~%"
                        (case (car auto) (:pass "PASS") (:unsure "FAIL") (t (car auto)))
                        (cdr auto))
                auto)
               (t
                (format t "  ✅ 看到了 → 按 y；不確定/怪怪的 → 按 n；略過 → s；中止 → q，然後 Enter：")
                (%df-read-verdict)))))
    (push (list n title (car vn) (cdr vn)) *dogfood-results*)
    (car vn)))

;;; ── 主流程 ───────────────────────────────────────────────────────────────

(defun dogfood (&optional (pdf "/tmp/ph3-split/sioyek/tutorial.pdf") (dir "h"))
  "互動式走完 8 項視窗分割驗收。PDF 預設 tutorial.pdf，DIR 預設 \"h\"（左右）。"
  (setf *dogfood-results* nil)
  (format t "~%════════════════════════════════════════════════════~%")
  (format t " 視窗分割互動驗收（Phase 3b）  PDF=~a  分割=~a~%" pdf dir)
  (format t " 看 Qt 視窗、回這個終端機按鍵。隨時 q 中止。~%")
  (format t "════════════════════════════════════════════════════~%")

  ;; 開檔 + 分割（自動）
  (o pdf) (sleep 0.6) (p)
  (let ((w2 (sp dir)))
    (declare (ignorable w2))
    (sleep 0.4) (p))

  ;; 1. 分割長出第二格
  (when (eq :abort
            (%df-step 1 "分割：真的長出第二個 pane"
                      (format nil "Qt 視窗~a兩格，兩格都看得到 PDF（同一份、同一頁），中間有分隔線。"
                              (if (string= dir "v") "上下" "左右"))))
    (return-from dogfood (%df-summary)))

  ;; 2. 焦點邊框（此刻 focus 在 w1）
  (when (eq :abort
            (%df-step 2 "焦點邊框：看得出哪一格 focused"
                      "有焦點那格（目前是 w1）有【藍色粗框 #1e88ff 4px】，另一格是灰框。"))
    (return-from dogfood (%df-summary)))

  ;; 3. 焦點移動：wf 邊框跟著跑
  (wf "w2") (sleep 0.4) (p)
  (when (eq :abort
            (%df-step 3 "焦點移動：(wf \"w2\") 邊框跳到 w2"
                      "藍框從第一格跳到第二格（w2）。"))
    (return-from dogfood (%df-summary)))
  (wf "w1") (sleep 0.4) (p)
  (when (eq :abort
            (%df-step 3.5 "焦點移動：(wf \"w1\") 邊框跳回 w1"
                      "藍框跳回第一格（w1）。"))
    (return-from dogfood (%df-summary)))

  ;; 4a. 鍵盤只驅動 focused（focus w1）—— 自動注入 J×3，肉眼看哪格翻頁
  (wf "w1") (sleep 0.4) (p)
  (let ((b1 (%df-page "w1")) (b2 (%df-page "w2")))
    (format t "~%  （注入前頁碼：w1=~a w2=~a；接著對 focused=w1 注入 J×3…）~%" b1 b2)
    (%df-inject-key "J" 3)
    (let ((a1 (%df-page "w1")) (a2 (%df-page "w2")))
      (format t "  （注入後頁碼：w1=~a w2=~a）~%" a1 a2)
      (when (eq :abort
                (%df-step 4 "鍵盤只驅動 focused pane：focus=w1 按 J×3"
                          "【第一格 w1】往後翻 3 頁，第二格 w2【完全不動】。"))
        (return-from dogfood (%df-summary)))))

  ;; 4b. 鍵盤只驅動 focused（focus w2）
  (wf "w2") (sleep 0.4) (p)
  (let ((b1 (%df-page "w1")) (b2 (%df-page "w2")))
    (format t "~%  （注入前頁碼：w1=~a w2=~a；接著對 focused=w2 注入 J×3…）~%" b1 b2)
    (%df-inject-key "J" 3)
    (let ((a1 (%df-page "w1")) (a2 (%df-page "w2")))
      (format t "  （注入後頁碼：w1=~a w2=~a）~%" a1 a2)
      (when (eq :abort
                (%df-step 4.5 "鍵盤只驅動 focused pane：focus=w2 按 J×3（原 bug 處）"
                          "【第二格 w2】往後翻 3 頁，第一格 w1【完全不動】。"))
        (return-from dogfood (%df-summary)))))

  ;; 5. 捲動（手動、誠實標註）
  (format t "~%  （請改用觸控板/滾輪：先確認 focus 在某一格，在 Qt 視窗上下滑。~%")
  (format t "    已知：backend 目前【沒有接 scroll 事件】，所以滾輪可能不動；~%")
  (format t "    若會動，原則上只動 focused 那格。據實回報即可。）~%")
  (when (eq :abort
            (%df-step 5 "捲動獨立：觸控板/滾輪"
                      "若會捲動，只動 focused 那格；w1/w2 不會一起跑。（不動也請回報）"))
    (return-from dogfood (%df-summary)))

  ;; 6. 多層分割：focus w2 再 (sp "v") → 共 3 格；用 (wins) 自動驗
  (wf "w2") (sleep 0.3) (p)
  (let ((w3 (sp "v"))) (declare (ignorable w3)) (sleep 0.4) (p))
  (when (eq :abort
            (%df-step 6 "多層分割：(wf \"w2\")+(sp \"v\") → 第二格再上下切成兩格"
                      "原本第二格的位置變成上下兩格，畫面共 3 格、都有內容。"))
    (return-from dogfood (%df-summary)))
  ;; 自動：(wins) 數 tiled 視窗是否=3
  (let* ((r (limn:call "bridge/win-list"))
         (wins (and (limn/bridge:response-ok? r)
                    (limn/bridge:response-data r)))
         (n (length wins)))
    (%df-step 6.5 "多層分割（自動）：window 數量應為 3"
              (format nil "(wins) 列出 3 個 tiled window（實得 ~a 個）。" n)
              :auto (if (= n 3) (cons :pass nil)
                        (cons :unsure (format nil "實得 ~a 個，非 3" n)))))

  ;; 7. 關閉 pane：關 w3 → 剩 2；自動驗「不能關最後一格」
  (wc "w3") (sleep 0.4) (p)
  (when (eq :abort
            (%df-step 7 "關閉 pane：(wc \"w3\") 乾淨收掉、空間補滿"
                      "第三格消失，剩下的格子補滿空間，沒有殘留空白格、沒 crash。"))
    (return-from dogfood (%df-summary)))
  ;; 關到剩一格，並驗證拒絕關最後一格
  (let* ((r1   (limn:call "bridge/win-list"))
         (wins (and (limn/bridge:response-ok? r1) (limn/bridge:response-data r1))))
    ;; 把除了第一個以外的 tiled 視窗都關掉
    (dolist (w (cdr wins))
      (let ((wid (getf w :|win-id|))) (when wid (wc wid) (sleep 0.3) (p))))
    (let* ((r2 (limn:call "bridge/win-close" :|win-id| "w1"))
           (refused (not (limn/bridge:response-ok? r2))))
      (%df-step 7.5 "關閉 pane（自動）：關到剩一格時拒絕關最後一格"
                "(wc \"w1\") 被拒絕（不能關最後一格），且邊框消失、回到單格樣子。"
                :auto (if refused (cons :pass nil)
                          (cons :unsure "最後一格竟然被關掉了（應被拒絕）")))))

  ;; 8. 收尾（手動）
  (format t "~%  （驗收結束。確認沒 crash、畫面回到單格無邊框後，待會自己打 (q) 離開。）~%")
  (%df-step 8 "收尾：畫面回到單格、無邊框"
            "只剩一格、沒有藍框、跟舊版單視窗一模一樣，準備好可 (q) 離開。")

  (%df-summary))

;;; ── 摘要輸出（複製貼上用）─────────────────────────────────────────────────

(defun %df-mark (verdict)
  (case verdict (:pass "[X]") (:unsure "[?]") (:skip "[ ]") (t "[ ]")))

(defun %df-summary ()
  "把結果印成一段 markdown，直接複製貼上回 checklist / 給 LLM。"
  (let ((rows (sort (copy-list *dogfood-results*) #'< :key #'first)))
    (format t "~%~%════════════════ 驗收摘要（複製以下整段）════════════════~%")
    (format t "```markdown~%")
    (format t "## 視窗分割驗收結果（dogfood-guided）~%")
    (dolist (row rows)
      (destructuring-bind (n title verdict note) row
        (format t "- ~a 第 ~a 項：~a~@[  ← ~a~]~%"
                (%df-mark verdict) n title note)))
    (let ((bad (remove-if-not (lambda (r) (eq (third r) :unsure)) rows)))
      (format t "~%總結：~a 項通過、~a 項待查、~a 項略過。~%"
              (count :pass rows :key #'third)
              (length bad)
              (count :skip rows :key #'third))
      (when bad
        (format t "待查項：~{~a~^、~}~%" (mapcar #'second bad))))
    (format t "```~%")
    (format t "═══════════════════════════════════════════════════════~%")
    (format t "（看完摘要後，打 (q) 離開）~%")
    (values)))
