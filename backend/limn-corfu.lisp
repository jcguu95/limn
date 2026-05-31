;;;; limn-corfu — In-buffer completion popup (minad Corfu 的 Lisp 等價)
;;;;
;;;; Corfu = in-buffer completion-at-point 的 popup UI，與 minibuffer 的
;;;; Vertico 平行。游標位置 + prefix → 後端提供 candidates → Corfu 建
;;;; 狀態機管理選取。
;;;;
;;;; 核心 API（照抄 minad Corfu）：
;;;;   make-corfu-session(candidates prefix) → corfu-state
;;;;   corfu-move(state delta) → state
;;;;   corfu-commit(state) → replacement-string
;;;;   corfu-update-prefix(state new-prefix) → state
;;;;
;;;; 純後端、headless 可驗。前端 popup 渲染留增量。

(defpackage #:limn/corfu
  (:use #:cl)
  (:export #:make-corfu-session
           #:corfu-move
           #:corfu-commit
           #:corfu-update-prefix
           #:corfu-state-p
           #:corfu-state-candidates
           #:corfu-state-prefix
           #:corfu-state-index
           #:corfu-state-count))

(in-package #:limn/corfu)

;;; ─── Corfu 狀態結構 ──────────────────────────────────────────────────

;; corfu-state 是一個 plist：
;;   :candidates  — 候選字串 list
;;   :prefix      — 當前前綴字串
;;   :index       — 當前選中 index（0-based，nil 表示無選取）
;;   :scroll-offset — 捲動偏移（保留供前端使用）

(defun corfu-state-p (state)
  "檢查 STATE 是否為合法的 corfu-state plist。"
  (and (listp state)
       ;; :candidates 必須為 list（可為 nil/empty）
       (listp (getf state :candidates))
       (stringp (getf state :prefix))
       (or (null (getf state :index))
           (integerp (getf state :index)))
       (or (null (getf state :scroll-offset))
           (integerp (getf state :scroll-offset)))))

(defun corfu-state-candidates (state)
  (getf state :candidates))

(defun corfu-state-prefix (state)
  (getf state :prefix))

(defun corfu-state-index (state)
  (getf state :index))

(defun corfu-state-count (state)
  "回傳候選總數。"
  (length (getf state :candidates)))

;;; ─── 建構 session ────────────────────────────────────────────────────

(defun make-corfu-session (candidates prefix)
  "建立 Corfu session state。
   CANDIDATES 為候選字串 list；PREFIX 為當前補全前綴。
   初始 index 設為 0（若候選非空）或 nil。"
  (let ((state (list :candidates candidates
                     :prefix prefix
                     :index (if candidates 0 nil)
                     :scroll-offset 0)))
    state))

;;; ─── 移動選取 ────────────────────────────────────────────────────────

(defun corfu-move (state delta)
  "移動選取 index 增減 DELTA（+1 向下，-1 向上）。
   回傳新的 state（不可變風格：回傳修改後的副本）。
   若無候選，index 維持 nil。"
  (let* ((candidates (getf state :candidates))
         (cnt (length candidates))
         (idx (getf state :index)))
    (if (or (null idx) (zerop cnt))
        state
        (let* ((new-idx (mod (+ idx delta) cnt))
               (new-state (copy-list state)))
          (setf (getf new-state :index) new-idx)
          new-state))))

;;; ─── 提交選取 ────────────────────────────────────────────────────────

(defun corfu-commit (state)
  "提交目前選中的候選，回傳 replacement-string。
   Caller 負責用此字串替換 buffer 中的 prefix。
   若無候選或無選取，回傳 prefix 本身（= 無變更）。"
  (let ((idx (getf state :index))
        (candidates (getf state :candidates)))
    (if (and idx candidates (>= idx 0) (< idx (length candidates)))
        (nth idx candidates)
        (getf state :prefix))))

;;; ─── 更新前綴（incremental filtering） ──────────────────────────────

(defun corfu-update-prefix (state new-prefix)
  "根據 NEW-PREFIX 重新過濾候選，回傳新的 state。
   過濾規則：候選必須以 new-prefix 開頭（case-insensitive）。
   若 orderless 可用，也支援 orderless 風格比對（當 prefix 含空白時）。
   重設 index 為 0（若仍有候選）或 nil。"
  (let* ((all-candidates (getf state :candidates))
         (filtered
           (if (or (null new-prefix) (zerop (length new-prefix)))
               all-candidates
               (let ((ci-prefix (string-downcase new-prefix))
                     (pref-len (length new-prefix)))
                 (remove-if-not
                  (lambda (c)
                    (and (>= (length c) pref-len)
                         ;; prefix match (case-insensitive)
                         (string= ci-prefix (string-downcase c)
                                  :end2 pref-len)))
                  all-candidates)))))
    ;; 如有 orderless，支援空白分隔的 component 過濾
    (when (and (find-package '#:limn/orderless)
               new-prefix
               (> (length new-prefix) 0)
               (find #\Space new-prefix))
      (let ((of-sym (find-symbol "ORDERLESS-FILTER" '#:limn/orderless)))
        (when (and of-sym (fboundp of-sym))
          (let ((of-result (funcall of-sym new-prefix all-candidates)))
            (when of-result
              (setf filtered of-result))))))
    (list :candidates filtered
          :prefix new-prefix
          :index (if filtered 0 nil)
          :scroll-offset 0)))
