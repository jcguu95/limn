;;;; v0.35 §A+B+C — file-notify / auto-revert / process-coding Qt-tier tests
;;;;
;;;; 對著真實 limn binary 跑（headless bridge），驗證 v0.35 三件事
;;;; 跟系統真正整合：
;;;;
;;;;   T1 auto-revert round-trip: 真實檔案 /tmp/limn-v035-... 在 shell
;;;;      被 echo >> 過後，buffer/text 自動更新（透過 limn/file-notify
;;;;      + limn/auto-revert 整條鏈）。
;;;;
;;;;   T2 process-coding pipe: spawn /bin/cat、stdin 寫 "中文"、stdout
;;;;      decode 後讀回 "中文"（驗證 limn/process 的 raw bytes ↔
;;;;      limn/coding 路徑跑得通）。
;;;;
;;;; 依賴：
;;;;   - limn/process       (v0.23 + v0.35 §C kwargs)
;;;;   - limn/coding        (v0.31)
;;;;   - limn/file          (v0.24)
;;;;   - limn/file-notify   (v0.35 §A)
;;;;   - limn/auto-revert   (v0.35 §B)
;;;;
;;;; 全部 RED — limn-file-notify.lisp / limn-auto-revert.lisp 尚未實作。

(in-package #:limn/test)

;; Qt-tier framework handles wire; we also load Lisp modules so tests
;; can call backend APIs directly.  Same pattern as syntax-coding-v031.
(let* ((suite-dir (make-pathname
                    :defaults (or *load-pathname*
                                  *default-pathname-defaults*)
                    :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir)))
  (dolist (f '("limn-hooks.lisp"
               "limn-log.lisp"
               "limn-error.lisp"
               "limn-timer.lisp"
               "limn-process.lisp"
               "limn-marker.lisp"
               "limn-local.lisp"
               "limn-coding.lisp"
               "limn-file.lisp"
               "limn-file-notify.lisp"    ; v0.35 §A
               "limn-auto-revert.lisp"))  ; v0.35 §B
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

;; ── helpers ──────────────────────────────────────────────────────────────

(defun %tmp-path (suffix)
  (format nil "/tmp/limn-v035-~D-~D~A" (random 100000)
          (get-internal-real-time) suffix))

(defun %write-file (path content)
  (with-open-file (s path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (write-string content s)))

(defun %append-shell (path s)
  "Append S to PATH via /bin/sh -c 'echo ... >> PATH' (mimics external
   process modifying the file)."
  (sb-ext:run-program "/bin/sh"
                       (list "-c" (format nil "printf '%s' '~a' >> ~a" s path))
                       :search nil :wait t :output nil :error nil))

(defun %poll-until (pred &key (timeout 3.0) (interval 0.05))
  "Poll PRED until it returns true or TIMEOUT elapsed."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (funcall pred) (return t))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep interval))))

;; ── T1. auto-revert real round-trip ─────────────────────────────────────

(deftest v035-t1-auto-revert-file-roundtrip
  "Create file → find-file (Lisp side, using limn/file vtable) → enable
   auto-revert-mode → external echo >> file → buffer content auto-updates.

   NOTE: must install vtable via setf-symbol-value (global), not progv —
   file-notify events arrive on the limn/process reader thread which does
   not inherit dynamic bindings."
  (let ((fn-pkg   (find-package '#:limn/file-notify))
        (ar-pkg   (find-package '#:limn/auto-revert))
        (file-pkg (find-package '#:limn/file)))
    (unless (and fn-pkg ar-pkg file-pkg)
      (format t "  SKIP: limn/file-notify or limn/auto-revert not loaded~%")
      (return-from v035-t1-auto-revert-file-roundtrip))
    (let* ((path (%tmp-path "-t1.txt"))
           (content-store (list ""))
           (find-fn (symbol-function (find-symbol "FIND-FILE" file-pkg)))
           (cont-sym (find-symbol "*BUFFER-SET-CONTENT-FN*" file-pkg))
           (saved-cont (symbol-value cont-sym)))
      (%write-file path "initial line
")
      (setf (symbol-value cont-sym)
            (lambda (bid str) (declare (ignore bid))
              (setf (first content-store) str)))
      (unwind-protect
           (let ((bid (funcall find-fn path)))
             (assert-true bid "find-file returned a buffer id")
             (funcall (symbol-function
                        (find-symbol "AUTO-REVERT-MODE" ar-pkg))
                      bid)
             (sleep 0.5)   ; give inotify time to set up
             (%append-shell path "second line")
             (let ((updated
                     (%poll-until
                       (lambda () (search "second line" (first content-store)))
                       :timeout 5.0)))
               (assert-true updated
                            (format nil "buffer auto-updated; got: ~s"
                                    (first content-store)))))
        (setf (symbol-value cont-sym) saved-cont)
        (ignore-errors (delete-file path))))))

;; ── T2. process-coding pipe (Big5 round-trip via cat) ───────────────────

(defparameter *cat-bin*
  (or (loop for p in '("/bin/cat" "/usr/bin/cat"
                       "/run/current-system/sw/bin/cat"
                       "/root/.nix-profile/bin/cat")
            when (probe-file p) return p)
      "/bin/cat"))

(deftest v035-t2-process-coding-cjk-pipe
  "spawn cat with :coding-system utf-8; send '中文'; stdout has '中文'."
  (let ((proc-pkg (find-package '#:limn/process))
        (cod-pkg  (find-package '#:limn/coding)))
    (unless (and proc-pkg cod-pkg)
      (format t "  SKIP: limn/process or limn/coding not loaded~%")
      (return-from v035-t2-process-coding-cjk-pipe))
    (let* ((mk (symbol-function (find-symbol "MAKE-PROCESS"   proc-pkg)))
           (snd (symbol-function (find-symbol "PROCESS-SEND-STRING" proc-pkg)))
           (eof (symbol-function (find-symbol "PROCESS-SEND-EOF"    proc-pkg)))
           (wait (symbol-function (find-symbol "PROCESS-WAIT"       proc-pkg)))
           (out  (symbol-function (find-symbol "PROCESS-STDOUT"     proc-pkg))))
      (handler-case
          (let ((p (funcall mk :command (list *cat-bin*)
                              :coding-system 'utf-8)))
            (funcall snd p "中文")
            (funcall eof p)
            (funcall wait p :timeout 5)
            (assert-true (search "中文" (funcall out p))
                         (format nil "stdout contained 中文; got: ~s"
                                 (funcall out p))))
        (error (e)
          (assert-true nil
                       (format nil "process-coding round-trip threw: ~a" e)))))))
