;;;; limn-embark — Context-aware action dispatcher（minad Embark 的 Lisp 等價）
;;;;
;;;; Embark = 情境感知的動作派發器。
;;;;   embark-actions-for(candidate category) → alist of (action-name . action-fn)
;;;;   embark-execute(action-name candidate) → 執行 action，回傳 result
;;;;
;;;; 支援的 category：
;;;;   :file   → actions: open-file, copy-path
;;;;   :buffer → actions: switch-to-buffer, kill-buffer
;;;;
;;;; 純後端、headless 可驗。action-fn 為 mock（回傳 :ok 或類似結果），
;;;; 實際 side effect（開啟檔案、切換 buffer）由前端 Qt tier 實作。

(defpackage #:limn/embark
  (:use #:cl)
  (:export #:embark-actions-for
           #:embark-execute
           #:embark-action-names
           #:*embark-action-registry*))

(in-package #:limn/embark)

;;; ─── 動作註冊表 ──────────────────────────────────────────────────────

;; *embark-action-registry* 是一個 alist：
;;   ((:category . ((action-name . action-fn) ...)) ...)
;; 預設 pre-populated 支援 :file 與 :buffer。

(defvar *embark-action-registry*
  `((:file
     (:open-file . ,(lambda (candidate)
                      (declare (ignore candidate))
                      :ok))
     (:copy-path . ,(lambda (candidate)
                      ;; mock: 複製路徑到剪貼簿
                      (declare (ignore candidate))
                      :ok))
     (:delete-file . ,(lambda (candidate)
                        (declare (ignore candidate))
                        :ok)))
    (:buffer
     (:switch-to-buffer . ,(lambda (candidate)
                             (declare (ignore candidate))
                             :ok))
     (:kill-buffer . ,(lambda (candidate)
                        (declare (ignore candidate))
                        :ok)))))

;;; ─── 查詢動作 ────────────────────────────────────────────────────────

(defun embark-actions-for (candidate category)
  "回傳 CANDIDATE 在 CATEGORY 下的可用動作 alist。
   格式：((action-name . action-fn) ...)
   若 CATEGORY 不存在，回傳 nil。"
  (declare (ignore candidate))
  (cdr (assoc category *embark-action-registry*)))

(defun embark-action-names (category)
  "回傳 CATEGORY 下所有 action-name 的 list（方便 UI 顯示）。"
  (mapcar #'car (cdr (assoc category *embark-action-registry*))))

;;; ─── 執行動作 ────────────────────────────────────────────────────────

(defun embark-execute (action-name candidate &optional (category nil))
  "執行 ACTION-NAME 對 CANDIDATE 的動作。
   若提供 CATEGORY，只在該 category 下查找；
   否則在所有 category 中查找第一個匹配的 action-name。
   回傳 action-fn 的結果；若找不到 action，回傳 :not-found。"
  (flet ((try-category (cat)
           (let* ((entry (assoc cat *embark-action-registry*))
                  (actions (cdr entry))
                  (pair (assoc action-name actions)))
             (when pair
               (funcall (cdr pair) candidate)))))
    (if category
        (let ((result (try-category category)))
          (if result result :not-found))
        ;; 無 category：搜尋所有
        (let ((found nil))
          (dolist (cat-entry *embark-action-registry*)
            (let ((result (try-category (car cat-entry))))
              (when result
                (setf found result)
                (return))))
          (if found found :not-found)))))
