;;;; v0.32 — current-buffer / save-excursion / narrow Qt-tier tests
;;;;
;;;; 對著真實 limn binary 跑、走實際 wire 命令，驗證 v0.32 純 Lisp 控制流
;;;; 跟底層 buffer 系統真正整合得起來。
;;;;
;;;; SPEC §12.v0.32 規定 ~2 Qt tests，我們做兩個：
;;;;   T1. with-current-buffer "*messages*" 寫字 → *messages* 真的有內容、
;;;;       原 buffer 沒被動到 point。
;;;;   T2. narrow-to-region 後 (point-max) clip；widen 後 restore。
;;;;
;;;; 全部 RED — limn-excursion.lisp 還沒實作。

(in-package #:limn/test)

;; Qt-tier framework 預設只走 wire；v0.32 跨 wire+Lisp，所以 in-process 載入
;; backend modules，同 v0.30 marker / v0.23 buffer-undo 的 pattern。
(let* ((suite-dir (make-pathname :defaults (or *load-pathname*
                                                *default-pathname-defaults*)
                                  :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir)))
  (dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
               "limn-marker.lisp" "limn-local.lisp" "limn-mark.lisp"
               "limn-excursion.lisp"))
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

;; 把 buffer-modified event 接到 marker fixup（idempotent）。
(when (find-package '#:limn/marker)
  (let ((install (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER" '#:limn/marker)))
    (when install (funcall install))))

(defmacro with-text-buffer-events ((buf-var) &body body)
  "Open a fresh text buffer + drain events + reset marker / local / mark
   state for this buf-id."
  `(let* ((r0 (send! "bridge/engine-load"
                     :|win-id| "w1" :|engine| "text" :|path| ""))
          (,buf-var (json-get* r0 :|data| :|buffer-id|)))
     (drain-events)
     (dolist (pkg-name '(#:limn/marker #:limn/local #:limn/mark))
       (let ((pkg (find-package pkg-name)))
         (when pkg
           (let ((reset (or (find-symbol "RESET-MARKERS" pkg)
                            (find-symbol "RESET-BUFFER-LOCALS" pkg)
                            (find-symbol "RESET-MARKS" pkg))))
             (when reset (funcall reset ,buf-var))))))
     (unwind-protect (progn ,@body)
       (when ,buf-var
         (ignore-errors (send! "buffer/close" :|buffer-id| ,buf-var))))))

(defun %fan-out-event (ev)
  (let ((etype (getf ev :|event|))
        (run-hook (find-symbol "RUN-HOOK" '#:limn/hooks)))
    (when (and etype run-hook)
      (funcall run-hook (concatenate 'string "event/" etype) ev))))

(defun %wait-and-fan (etype timeout)
  (let ((ev (read-event :type etype :timeout timeout)))
    (when ev (%fan-out-event ev))
    ev))

;;; ── T1. with-current-buffer "*messages*" — isolation ─────────────────

(deftest v032-qt-with-current-buffer-messages-isolation
  "with-current-buffer \"*messages*\" 內 insert → *messages* 真的有新內容、
   原 buffer 的 point 完全沒被動。"
  (with-text-buffer-events (buf)
    ;; seed 原 buffer 內容＋ point 在中間
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world")
    (%wait-and-fan "buffer-modified" 2.0)
    (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 5)
    (let ((point-before (json-get* (send! "buffer/cursor-get"
                                          :|buffer-id| buf)
                                   :|data| :|offset|)))
      (assert-equal 5 point-before "init point = 5")
      ;; 透過 v0.32 in-process 切到 *messages* 寫字
      (let ((xpkg (find-package '#:limn/excursion)))
        (unless xpkg
          (return-from v032-qt-with-current-buffer-messages-isolation
            (assert-true nil "limn/excursion not loaded — expected RED")))
        (let ((with-current (find-symbol "WITH-CURRENT-BUFFER" xpkg))
              (current      (find-symbol "CURRENT-BUFFER-ID" xpkg))
              (set-buf      (find-symbol "SET-BUFFER" xpkg)))
          (unless (and with-current current set-buf)
            (return-from v032-qt-with-current-buffer-messages-isolation
              (assert-true nil "v0.32 API missing — expected RED")))
          ;; let v0.32 sees `buf` as current first
          (funcall set-buf buf)
          ;; eval the macro form via (eval ...) so the test file doesn't
          ;; need the symbol at read time.
          (eval `(,with-current "*messages*"
                  (send! "buffer/insert"
                         :|buffer-id| "*messages*"
                         :|text| "qt-test-line\n")))
          (%wait-and-fan "buffer-modified" 2.0)
          ;; 驗證 1：*messages* 真的多了內容
          (let* ((mtext-r (send! "buffer/text" :|buffer-id| "*messages*"))
                 (mtext   (json-get* mtext-r :|data| :|text|)))
            (assert-true (and (stringp mtext)
                              (search "qt-test-line" mtext))
                         "*messages* contains injected line"))
          ;; 驗證 2：原 buffer 的 point 還在 5
          (let ((point-after (json-get* (send! "buffer/cursor-get"
                                               :|buffer-id| buf)
                                        :|data| :|offset|)))
            (assert-equal 5 point-after "original buffer point unchanged"))
          ;; 驗證 3：with-current-buffer 結束後 current 還是 buf
          (assert-equal buf (funcall current)
                        "current-buffer-id restored to original"))))))

;;; ── T2. narrow-to-region clips point-max; widen restores ──────────────

(deftest v032-qt-narrow-clips-point-max
  "buffer 有 11 字，narrow-to-region 2 5 → point-max=5；widen 後 point-max=11。"
  (with-text-buffer-events (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello world")
    (%wait-and-fan "buffer-modified" 2.0)
    (let ((xpkg (find-package '#:limn/excursion)))
      (unless xpkg
        (return-from v032-qt-narrow-clips-point-max
          (assert-true nil "limn/excursion not loaded — expected RED")))
      (let ((narrow    (find-symbol "NARROW-TO-REGION" xpkg))
            (widen     (find-symbol "WIDEN" xpkg))
            (point-min (find-symbol "POINT-MIN" xpkg))
            (point-max (find-symbol "POINT-MAX" xpkg))
            (set-buf   (find-symbol "SET-BUFFER" xpkg)))
        (unless (and narrow widen point-min point-max set-buf)
          (return-from v032-qt-narrow-clips-point-max
            (assert-true nil "v0.32 narrow API missing — expected RED")))
        (funcall set-buf buf)
        (funcall narrow 2 5)
        (assert-equal 2 (funcall point-min)
                      "narrow → point-min = 2")
        (assert-equal 5 (funcall point-max)
                      "narrow → point-max = 5")
        (funcall widen)
        (assert-equal 0 (funcall point-min)
                      "widen → point-min = 0")
        (assert-equal 11 (funcall point-max)
                      "widen → point-max = 11")))))
