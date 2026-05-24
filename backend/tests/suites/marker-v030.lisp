;;;; v0.30 §A — markers Qt-tier tests
;;;;
;;;; Wire-level round-trip：對著真實 limn binary 跑、走實際 buffer/insert
;;;; / buffer/delete 命令，驗證 buffer-modified event → marker fixup 鍊
;;;; 真的串得起來。
;;;;
;;;; v0.30 SPEC 規定 ~2 Qt tests：
;;;;   T1. buffer/insert 在 mark 之前 → mark 自動跟著走
;;;;   T2. buffer-local var 在不同 buffer 設不同值 → 分別正確
;;;;
;;;; 額外加：T3 buffer/delete 蓋過 mark → clamp 行為對。

(in-package #:limn/test)

;; Qt-tier framework 預設只走 wire，不載 backend Lisp。但 v0.30 的整合
;; 點（marker / local）跨 wire＋Lisp，所以我們在 in-process 載入 backend
;; modules，跟 v0.23 buffer-undo-wire 的 dogfood pattern 一樣。
(let* ((suite-dir (make-pathname :defaults (or *load-pathname*
                                                *default-pathname-defaults*)
                                  :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir)))
  (dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
               "limn-marker.lisp" "limn-local.lisp" "limn-mark.lisp"))
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

;; 把 buffer-modified 事件接到 marker fixup。idempotent。
(when (find-package '#:limn/marker)
  (funcall (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER" '#:limn/marker)))

(defmacro with-text-buffer-and-events ((buf-var) &body body)
  "Open a fresh text buffer + drain stale events. Each test runs against
   a fresh buffer so marker/local state stays isolated."
  `(let* ((r0 (send! "bridge/engine-load"
                     :|win-id| "w1" :|engine| "text" :|path| ""))
          (,buf-var (json-get* r0 :|data| :|buffer-id|)))
     (drain-events)
     ;; reset Lisp-side marker / local state for this buf-id
     (when (find-package '#:limn/marker)
       (funcall (find-symbol "RESET-MARKERS" '#:limn/marker) ,buf-var))
     (when (find-package '#:limn/local)
       (funcall (find-symbol "RESET-BUFFER-LOCALS" '#:limn/local) ,buf-var))
     (when (find-package '#:limn/mark)
       (funcall (find-symbol "RESET-MARKS" '#:limn/mark) ,buf-var))
     (unwind-protect (progn ,@body)
       (when ,buf-var
         (ignore-errors (send! "buffer/close" :|buffer-id| ,buf-var))))))

(defun %fan-out-event (ev)
  "Manually fan a wire event through limn/hooks the same way
   limn-dispatch:fire-event would. The Qt-tier framework's
   read-event consumes from its own queue; without this helper,
   subscribers registered with add-hook never see it. (Same pattern
   as v0.23 buffer-undo-wire.)"
  (let ((etype (getf ev :|event|))
        (run-hook (find-symbol "RUN-HOOK" '#:limn/hooks)))
    (when (and etype run-hook)
      (funcall run-hook
               (concatenate 'string "event/" etype)
               ev))))

(defun %wait-and-fan (etype timeout)
  "Block on an event, then fan it out to the in-process hook system
   so marker handlers fire. Returns the event (or nil on timeout)."
  (let ((ev (read-event :type etype :timeout timeout)))
    (when ev (%fan-out-event ev))
    ev))

(defun %wait-for-event (etype timeout)
  "Block until an event of ETYPE arrives or TIMEOUT seconds pass.
   Returns the event plist or nil. Does NOT fan out — use %wait-and-fan
   when you also want hook subscribers to fire."
  (read-event :type etype :timeout timeout))

;;; ── T1. buffer/insert before mark → mark adjusts ─────────────────────

(deftest v030-qt-marker-survives-wire-insert
  "set-mark 5；wire buffer/insert at 0 len=2 → mark 自動變成 7。"
  (with-text-buffer-and-events (buf)
    ;; 先把文字塞進去：「hello world」 (len=11)，cursor 在 0
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world")
    (%wait-for-event "buffer-modified" 2.0)
    ;; cursor-set 到 5（為 set-mark 的 default 預備）
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 5)
    ;; 用 Lisp set-mark 在 pos=5（v0.30 升級會 wrap 成 marker）
    (funcall (find-symbol "SET-MARK" '#:limn/mark) 5 buf)
    ;; 確認初始 mark
    (assert-equal 5 (funcall (find-symbol "MARK" '#:limn/mark) buf)
                "initial mark = 5")
    ;; 把 cursor 移到 0、wire insert "XY" (len=2)
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
    (send! "buffer/insert" :|buffer-id| buf :|text| "XY")
    ;; 等 event 抵達並手動 fan-out（給 process-insert 跑的機會）
    (let ((ev (%wait-and-fan "buffer-modified" 2.0)))
      (assert-true (not (null ev)) "buffer-modified event arrived"))
    ;; 驗證 mark 已被 fixup 從 5 變 7
    (assert-equal 7 (funcall (find-symbol "MARK" '#:limn/mark) buf)
                "mark auto-adjusts 5 → 7 after wire insert at 0 len=2")))

;;; ── T2. buffer-local var per-buffer isolation ────────────────────────

(deftest v030-qt-buffer-local-per-buffer
  "在 buffer A 設 *v-qt-bl* = 80，在 buffer B 設 = 40，分別讀回正確。"
  (with-text-buffer-and-events (buf-a)
    (with-text-buffer-and-events (buf-b)
      (let ((local-pkg (find-package '#:limn/local)))
        (unless local-pkg
          (return-from v030-qt-buffer-local-per-buffer
            (assert-true nil "limn/local not loaded")))
        (let ((defvar-local (find-symbol "DEFVAR-LOCAL"      local-pkg))
              (set!         (find-symbol "SET-BUFFER-LOCAL-VALUE" local-pkg))
              (val-of       (find-symbol "BUFFER-LOCAL-VALUE"     local-pkg))
              (default      (find-symbol "DEFAULT-VALUE"          local-pkg)))
          (declare (ignore defvar-local))
          ;; 用 set-buffer-local-value 顯式指定 buffer-id（避免依賴
          ;; *current-buffer-id*，因為 Qt-tier 還沒切 buffer context）
          (defvar *v-qt-bl* 999)
          (funcall (find-symbol "MAKE-VARIABLE-BUFFER-LOCAL" local-pkg)
                   '*v-qt-bl*)
          (funcall set! '*v-qt-bl* 80 buf-a)
          (funcall set! '*v-qt-bl* 40 buf-b)
          (assert-equal 80 (funcall val-of '*v-qt-bl* buf-a)
                      "buffer A reads 80")
          (assert-equal 40 (funcall val-of '*v-qt-bl* buf-b)
                      "buffer B reads 40")
          (assert-equal 999 (funcall default '*v-qt-bl*)
                      "global default still 999"))))))

;;; ── T3. buffer/delete crossing mark → clamp ──────────────────────────

(deftest v030-qt-marker-clamps-on-wire-delete
  "set-mark 4；wire buffer/delete [1,5) → mark clamp 到 1。"
  (with-text-buffer-and-events (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "abcdefgh")
    (%wait-for-event "buffer-modified" 2.0)
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 4)
    (funcall (find-symbol "SET-MARK" '#:limn/mark) 4 buf)
    (assert-equal 4 (funcall (find-symbol "MARK" '#:limn/mark) buf)
                "initial mark = 4")
    ;; wire delete [1,5)：from=1, to=5
    (send! "buffer/delete" :|buffer-id| buf :|from| 1 :|to| 5)
    (let ((ev (%wait-and-fan "buffer-modified" 2.0)))
      (assert-true (not (null ev)) "delete event arrived"))
    ;; mark 在 [1,5) 內 → clamp 到 1
    (assert-equal 1 (funcall (find-symbol "MARK" '#:limn/mark) buf)
                "mark clamps to FROM (1) when delete range covers it")))
