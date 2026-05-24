;;;; v0.32 — buffer lifecycle wrappers (OS-tier)
;;;;
;;;; 真實 limn binary。驗證 get-buffer-create / kill-buffer / buffer-list
;;;; / rename-buffer 真接到底層 wire 命令 + Lisp registry。
;;;;
;;;; Ω1 起始 buffer-list 含一個 text-engine buffer。
;;;; Ω2 get-buffer-create "scratch-v032" → 新建、buffer-list 多一條。
;;;; Ω3 get-buffer-create "scratch-v032" 第二次 → 回同一個 (eq)、count 不變。
;;;; Ω4 rename-buffer "renamed-v032" → buffer-name 換、get-buffer 用新名找得到。
;;;; Ω5 kill-buffer → buffer-list 不含、get-buffer 回 nil。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v032life"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-timer.lisp" "limn-process.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-undo.lisp" "limn-buffer-undo.lisp"
             "limn-keys.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp"
             "limn-text-mode.lisp"
             "limn-marker.lisp"
             "limn-local.lisp"
             "limn-mark.lisp"
             "limn-excursion.lisp"
             "limn.lisp"))
  (handler-case (load (b/ f))
    (error (e) (format t "  !! skipped ~A: ~A~%" f e))))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun text-engine-load ()
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "text" :|path| "" :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool" '("search" "--name" "Limn")
                                             :search t :wait t
                                             :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
          do (return found)
        do (sleep 0.1)))

(defun xpkg () (find-package '#:limn/excursion))
(defun xsym (n) (and (xpkg) (find-symbol n (xpkg))))

(defun id-of (buf-obj)
  "Try a few ways to extract the buffer-id from whatever buffer-list
   returns: mode-buffer struct, plist, or a bare string id."
  (cond
    ((stringp buf-obj) buf-obj)
    ((and (listp buf-obj) (getf buf-obj :|buffer-id|))
     (getf buf-obj :|buffer-id|))
    (t
     ;; try (buffer-name buf-obj) via xpkg
     (let ((bn (xsym "BUFFER-NAME")))
       (and bn (funcall bn buf-obj))))))

;;; ── session ─────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v032life-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v032life.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (unless (xpkg)
    (format t "✗ FATAL: limn/excursion not loaded — RED expected~%")
    (push "limn/excursion not loaded" *failures*))

  (let ((buf (text-engine-load)))
    (check (format nil "setup — opened text buffer (~a)" buf)
           (stringp buf))

    (unless buf
      (limn:stop) (sb-ext:process-kill proc 15)
      (sb-ext:process-wait proc) (sb-ext:exit :code 2))

;;; ── Ω1: buffer-list contains the loaded buffer ──────────────────────

    (format t "~%── Ω1: buffer-list contains loaded text buffer ──~%")
    (let ((blist (xsym "BUFFER-LIST")))
      (cond
        ((not blist) (check "buffer-list present" nil "RED"))
        (t
         (let* ((bufs (funcall blist))
                (names (mapcar #'id-of bufs)))
           (check (format nil "list non-empty (got ~a entries)" (length bufs))
                  (and (listp bufs) (>= (length bufs) 1)))
           (check (format nil "list contains loaded buf-id ~s; names=~s" buf names)
                  (find buf names :test #'equal))))))

;;; ── Ω2: get-buffer-create creates new entry ─────────────────────────

    (format t "~%── Ω2: get-buffer-create 'scratch-v032' creates entry ──~%")
    (let ((blist (xsym "BUFFER-LIST"))
          (gbc   (xsym "GET-BUFFER-CREATE")))
      (cond
        ((not (and blist gbc))
         (check "buffer-list / get-buffer-create present" nil "RED"))
        (t
         (let ((before (length (funcall blist))))
           (funcall gbc "scratch-v032")
           (let* ((after  (length (funcall blist)))
                  (names  (mapcar #'id-of (funcall blist))))
             (check (format nil "count grew: ~a → ~a" before after)
                    (>= after (1+ before)))
             (check (format nil "list contains 'scratch-v032'; names=~s" names)
                    (find "scratch-v032" names :test #'equal)))))))

;;; ── Ω3: get-buffer-create idempotent ─────────────────────────────────

    (format t "~%── Ω3: get-buffer-create same name → same buffer + count stable ──~%")
    (let ((blist (xsym "BUFFER-LIST"))
          (gbc   (xsym "GET-BUFFER-CREATE")))
      (cond
        ((not (and blist gbc))
         (check "API present" nil "RED"))
        (t
         (let* ((b1 (funcall gbc "scratch-v032"))
                (n-before (length (funcall blist)))
                (b2 (funcall gbc "scratch-v032"))
                (n-after  (length (funcall blist))))
           (check "second call returns eq buffer" (eq b1 b2))
           (check (format nil "list size stable: ~a → ~a" n-before n-after)
                  (eql n-before n-after))))))

;;; ── Ω4: rename-buffer changes lookup name ────────────────────────────

    (format t "~%── Ω4: rename-buffer 'scratch-v032' → 'renamed-v032' ──~%")
    (let ((gb     (xsym "GET-BUFFER"))
          (wcb    (xsym "WITH-CURRENT-BUFFER"))
          (rename (xsym "RENAME-BUFFER")))
      (cond
        ((not (and gb wcb rename))
         (check "rename API present" nil "RED"))
        (t
         (eval `(,wcb "scratch-v032" (,rename "renamed-v032")))
         (let ((by-new (funcall gb "renamed-v032"))
               (by-old (funcall gb "scratch-v032")))
           (check "lookup by new name works" by-new)
           (check "lookup by old name returns nil" (null by-old))))))

;;; ── Ω5: kill-buffer removes entry ─────────────────────────────────────

    (format t "~%── Ω5: kill-buffer 'renamed-v032' → removed from list ──~%")
    (let ((blist (xsym "BUFFER-LIST"))
          (gb    (xsym "GET-BUFFER"))
          (kill  (xsym "KILL-BUFFER")))
      (cond
        ((not (and blist gb kill))
         (check "kill API present" nil "RED"))
        (t
         (let ((target (funcall gb "renamed-v032")))
           (when target (funcall kill target)))
         (let* ((bufs  (funcall blist))
                (names (mapcar #'id-of bufs)))
           (check (format nil "'renamed-v032' gone from list; names=~s" names)
                  (null (find "renamed-v032" names :test #'equal))))
         (check "get-buffer 'renamed-v032' = nil"
                (null (funcall gb "renamed-v032")))))))

  (format t "~%── v032 buffer lifecycle e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
