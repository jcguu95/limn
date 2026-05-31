;;;; limn-vertico — Vertico 補全 UI 狀態機（minad Vertico 的 Lisp 等價後端）
;;;;
;;;; 一個 completing-read session 的後端狀態包含：
;;;;   - all-candidates（全候選集 list）
;;;;   - input（當前輸入字串）
;;;;   - filtered-candidates（orderless-filter 後的 list，照 score 排）
;;;;   - index（0-based，當前選中的項目）
;;;;   - scroll-offset（顯示窗格起點，確保 index 永遠在可視範圍）
;;;;   - window-size（窗格大小，預設 10）
;;;;
;;;; 操作語意：
;;;;   - update-input(session input)：重新 orderless-filter，reset index=0、scroll=0
;;;;   - move(session delta)：index += delta，clamp 到 [0, len-1]（不 wrap），更新 scroll-offset
;;;;   - visible(session)：回傳 (visible-candidates . relative-index) 代表可見窗格
;;;;   - current(session)：回傳選中的候選字串，或 nil（若 filtered 為空）
;;;;
;;;; 純後端、headless 可驗。前端 Qt 垂直渲染留增量。

(defpackage #:limn/vertico
  (:use #:cl)
  (:export #:vertico-session
           #:make-session
           #:session-all-candidates
           #:session-input
           #:session-filtered-candidates
           #:session-index
           #:session-scroll-offset
           #:session-window-size
           #:session-update-input
           #:session-move
           #:session-visible
           #:session-current
           #:vertico-completing-read))

(in-package #:limn/vertico)

;;; ─── 結構定義 ────────────────────────────────────────────────────────

(defstruct (vertico-session (:conc-name session-))
  "Vertico 補全會話的後端狀態。
   照抄 minad Vertico 設計：候選集、輸入、過濾結果、選中索引、窗格參數。"
  (all-candidates      '() :type list)    ; 全候選集（原始 list）
  (input               ""  :type string)  ; 當前輸入字串
  (filtered-candidates '() :type list)    ; orderless-filter 後的排序 list
  (index               0   :type integer) ; 0-based 選中索引
  (scroll-offset       0   :type integer) ; 顯示窗格起點
  (window-size         10  :type integer)); 窗格大小（預設 10）

;;; ─── 建構子 ──────────────────────────────────────────────────────────

(defun make-session (all-candidates &key (window-size 10))
  "建立一個新的 Vertico 補全會話。
   ALL-CANDIDATES 為候選字串 list。
   WINDOW-SIZE 為顯示窗格大小，預設 10。"
  (let ((session (make-vertico-session
                   :all-candidates (copy-list all-candidates)
                   :input ""
                   :filtered-candidates (copy-list all-candidates)
                   :index 0
                   :scroll-offset 0
                   :window-size window-size)))
    session))

;;; ─── 輸入更新 ────────────────────────────────────────────────────────

(defun session-update-input (session input)
  "更新 SESSION 的輸入字串為 INPUT。
   重新以 orderless-filter 過濾 all-candidates，
   並重設 index 為 0、scroll-offset 為 0。
   回傳 SESSION（side-effect + 回傳自身以便串接）。"
  (setf (session-input session) input)
  (let ((filtered
          (if (or (null input)
                  (zerop (length (string-trim '(#\Space #\Tab #\Newline) input))))
              ;; 空輸入 → 顯示所有候選（保持原始順序）
              (copy-list (session-all-candidates session))
              ;; 非空輸入 → orderless 過濾並排序
              (limn/orderless:orderless-filter
               input
               (session-all-candidates session)))))
    (setf (session-filtered-candidates session) filtered)
    (setf (session-index session) 0)
    (setf (session-scroll-offset session) 0))
  session)

;;; ─── 移動選中索引 ────────────────────────────────────────────────────

(defun session-move (session delta)
  "移動 SESSION 的選中索引，DELTA 為整數偏移量（正向下、負向上）。
   index 會 clamp 到 [0, len-1]，不 wrap。
   自動更新 scroll-offset 以確保 index 在可視窗格內。
   回傳 SESSION。"
  (let* ((filtered (session-filtered-candidates session))
         (len (length filtered))
         (window (session-window-size session)))
    (when (zerop len)
      (return-from session-move session))
    ;; clamp index
    (let ((new-index (+ (session-index session) delta)))
      (setf new-index (max 0 (min new-index (1- len))))
      (setf (session-index session) new-index)
      ;; 更新 scroll-offset 確保 index 在可視範圍 [offset, offset+window-1]
      (let ((offset (session-scroll-offset session)))
        (cond
          ;; index 跑到窗格前面 → 把窗格拉到 index
          ((< new-index offset)
           (setf (session-scroll-offset session) new-index))
          ;; index 跑到窗格後面 → 把窗格往前推到 index 在最後一行
          ((>= new-index (+ offset window))
           (setf (session-scroll-offset session)
                 (max 0 (- new-index window -1))))
          ;; index 在窗格內 → 不動 scroll
          (t nil)))))
  session)

;;; ─── 可見窗格 ────────────────────────────────────────────────────────

(defun session-visible (session)
  "回傳 SESSION 的可見窗格內容。
   回傳值為 cons cell：(visible-candidates . relative-index)
   - visible-candidates：從 scroll-offset 開始，最多 window-size 個候選
   - relative-index：當前選中項目在 visible-candidates 中的相對索引（0-based）
   若 filtered-candidates 為空，回傳 (nil . 0)。"
  (let* ((filtered (session-filtered-candidates session))
         (len (length filtered))
         (offset (session-scroll-offset session))
         (window (session-window-size session))
         (index (session-index session)))
    (if (zerop len)
        (cons nil 0)
        (let* ((end (min (+ offset window) len))
               (visible (subseq filtered offset end)))
          (cons visible (- index offset))))))

;;; ─── 當前選中候選 ────────────────────────────────────────────────────

(defun session-current (session)
  "回傳 SESSION 目前選中的候選字串。
   若 filtered-candidates 為空，回傳 nil。"
  (let* ((filtered (session-filtered-candidates session))
         (len (length filtered))
         (index (session-index session)))
    (when (and (> len 0) (>= index 0) (< index len))
      (elt filtered index))))

;;; ─── vertico-completing-read（headless wrapper）──────────────────────

(defun vertico-completing-read (prompt collection
                                &key predicate require-match
                                     initial-input history default)
  "Vertico 版本的 completing-read。
   使用 vertico session 狀態機驅動，以 orderless 過濾。

   在 live session（limn:*session* 存在且 pump thread 運行中）：
   - 建立 vertico session
   - 開啟 minibuffer
   - 傳送初始 candidates 到 Qt（minibuffer/set-candidates）
   - 監聽 minibuffer-input 事件來更新過濾並推送新 candidates
   - 監聽 minibuffer-submit → 回傳選中候選
   - 監聽 minibuffer-cancel → 拋出 quit condition
   - blocking wait 直到確認或取消
   - 關閉 minibuffer

   在 headless（unit test）模式下：
   - 建立 session、套用 initial-input
   - 若 filtered 非空 → 回傳 current（即排序後的第一個候選）
   - 若 filtered 為空 + require-match → error
   - 若 filtered 為空 + default → 回傳 default
   - 否則回傳 initial-input"
  (declare (ignore history))
  ;; ── 先判斷是否為 live session ──
  (let* ((limn-pkg (find-package '#:limn))
         (session  (and limn-pkg
                        (let ((s (find-symbol "*SESSION*" limn-pkg)))
                          (and s (boundp s) (symbol-value s)))))
         ;; 檢查 pump thread（代表真的在 live 模式下）
         (pt-fn (find-symbol "SESSION-PUMP-THREAD" '#:limn/dispatch)))
    (when (and session
               pt-fn
               (let ((pt (ignore-errors (funcall pt-fn session))))
                 (and pt (sb-thread:thread-alive-p pt))))
      (return-from vertico-completing-read
        (%vertico-live-completing-read
         prompt collection
         :predicate predicate
         :require-match require-match
         :initial-input initial-input
         :default default
         :session session))))

  ;; ── headless / unit test 模式 ──
  (let* ((raw-candidates
           (etypecase collection
             (list collection)
             (hash-table
              (let ((keys '()))
                (maphash (lambda (k _v) (declare (ignore _v)) (push k keys)) collection)
                keys))
             (function
              ;; 用空字串呼叫 function collection 取得所有候選
              (funcall collection "" predicate nil)))))
    ;; 套用 predicate
    (when predicate
      (setf raw-candidates (remove-if-not predicate raw-candidates)))
    ;; 建立 session
    (let ((session (make-session raw-candidates)))
      ;; 套用 initial-input
      (when initial-input
        (session-update-input session initial-input))
      (let* ((input (or initial-input ""))
             (current (session-current session)))
        (cond
          ;; 有匹配 → 回傳選中項
          (current
           current)
          ;; 無匹配 + require-match → error
          (require-match
           (error "No match for ~s in vertico-completing-read" input))
          ;; 無匹配 + default
          (default
            default)
          ;; 無匹配 + 無 require → 回傳輸入本身
          (t
           input))))))

;;; ─── live session 實作 ─────────────────────────────────────────────────

(defun %vertico-live-completing-read (prompt collection
                                      &key predicate require-match
                                           initial-input default session)
  "在 live session 中執行 vertico-completing-read。
   使用 bridge 與 Qt 前端溝通，實作完整的 Vertico 互動流程。
   所有 limn:call / limn:hooks 等符號透過 late binding 存取，
   因為 limn-vertico 的載入順序早於 limn.lisp。"
  ;; 準備候選集
  (let* ((raw-candidates
           (etypecase collection
             (list collection)
             (hash-table
              (let ((keys '()))
                (maphash (lambda (k _v) (declare (ignore _v)) (push k keys)) collection)
                keys))
             (function
              (funcall collection "" predicate nil))))
         ;; 套用 predicate
         (cands (if predicate
                    (remove-if-not predicate raw-candidates)
                    raw-candidates))
         ;; 建立 vertico session
         (vsession (make-session cands))
         ;; 用來記錄提交/取消狀態
         (submitted nil)
         (selected nil)
         ;; Late binding：limn 包在 limn-vertico 之後才載入
         (call-fn (or (find-symbol "CALL" '#:limn)
                      (error "limn:call not available")))
         (quit-cond (find-symbol "QUIT-CONDITION" '#:limn/completion)))
    (when initial-input
      (session-update-input vsession initial-input))
    
    (labels
        ;; ── 推送目前候選到前端 ──
        ((send-candidates ()
           (let* ((visible (session-visible vsession))
                  (vis-cands (car visible))
                  (rel-idx   (cdr visible))
                  (filtered  (session-filtered-candidates vsession))
                  (total     (length filtered)))
             (ignore-errors
               (funcall call-fn "minibuffer/set-candidates"
                        :|candidates| (or vis-cands '())
                        :|index| rel-idx
                        :|total| total))))
         
         ;; ── 處理輸入更新（使用者打字） ──
         (on-input (ev)
           (let ((text (getf ev :|text|)))
             (when text
               (session-update-input vsession text)
               (send-candidates))))
         
         ;; §4：C-n / Down → 向下移動選中
         (on-next (ev)
           (declare (ignore ev))
           (session-move vsession 1)
           (send-candidates))
         
         ;; §4：C-p / Up → 向上移動選中
         (on-prev (ev)
           (declare (ignore ev))
           (session-move vsession -1)
           (send-candidates))
         
         ;; ── 處理提交（RET） ──
         (on-submit (ev)
           (declare (ignore ev))
           (let ((cur (session-current vsession)))
             (setf selected (or cur (session-input vsession))
                   submitted :submit)))
         
         ;; ── 處理取消（ESC / C-g） ──
         (on-cancel (ev)
           (declare (ignore ev))
           (setf submitted :cancel)))
      
      (let ((add-hook-fn (find-symbol "ADD-HOOK" '#:limn/hooks))
            (remove-hook-fn (find-symbol "REMOVE-HOOK" '#:limn/hooks))
            (input-hook  (limn/dispatch:event-hook-name "minibuffer-input"))
            (next-hook   (limn/dispatch:event-hook-name "minibuffer/candidates-next"))
            (prev-hook   (limn/dispatch:event-hook-name "minibuffer/candidates-prev"))
            (submit-hook (limn/dispatch:event-hook-name "minibuffer-submit"))
            (cancel-hook (limn/dispatch:event-hook-name "minibuffer-cancel"))
            (cancel2-hook (limn/dispatch:event-hook-name "minibuffer/candidates-cancel")))
        
        (funcall add-hook-fn next-hook   #'on-next)
        (funcall add-hook-fn prev-hook   #'on-prev)
        (funcall add-hook-fn input-hook  #'on-input)
        (funcall add-hook-fn submit-hook #'on-submit)
        (funcall add-hook-fn cancel-hook #'on-cancel)
        (funcall add-hook-fn cancel2-hook #'on-cancel)
        
        (unwind-protect
            (progn
              ;; 開啟 minibuffer
              (funcall call-fn "minibuffer/open" :|prompt| prompt)
              ;; 設定初始文字（若有 initial-input）
              (when initial-input
                (funcall call-fn "minibuffer/set-text" :|text| initial-input))
              ;; 傳送初始候選
              (send-candidates)
              
              ;; blocking wait 直到 submitted 被設定
              (limn/dispatch:wait-for-event
               session (lambda () submitted)
               :timeout 300.0)
              
              ;; 根據結果回傳
              (case submitted
                (:submit selected)
                (:cancel (error quit-cond))))
          
          ;; cleanup：總是關閉 minibuffer 並移除 hooks
          (ignore-errors (funcall call-fn "minibuffer/close"))
          (funcall remove-hook-fn submit-hook #'on-submit)
          (funcall remove-hook-fn cancel-hook #'on-cancel)
          (funcall remove-hook-fn cancel2-hook #'on-cancel)
          (funcall remove-hook-fn input-hook  #'on-input)
          (funcall remove-hook-fn next-hook   #'on-next)
          (funcall remove-hook-fn prev-hook   #'on-prev))))))
