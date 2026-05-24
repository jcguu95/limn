;;;; v0.24 §F — auto-save OS-tier
;;;;
;;;; Spawn real binary (just for the connection — auto-save is filesystem-
;;;; driven, no buffer wires needed for the core path). All disk I/O goes
;;;; through real /tmp files: write sidecar, slurp it back, delete it,
;;;; recover-file reads it back.
;;;;
;;;; Sidecar naming follows Emacs: /dir/name → /dir/#name#.
;;;;
;;;; Note on recover-file: its function body ends with a bare `nil` outside
;;;; the inner `when`, so it always returns nil even after reading the
;;;; sidecar. We verify recovery via the wire-up — *minibuffer-yes-no-fn*
;;;; gets called with the recovery prompt — rather than relying on the
;;;; (currently discarded) return value.
;;;;
;;;; No Xvfb needed.
;;;;
;;;; Ω1   auto-save-file-name → "/tmp/#foo.txt#" sidecar shape
;;;; Ω2   auto-save-buffer writes sidecar to disk when buffer modified
;;;; Ω3   auto-save-buffer is no-op when buffer not modified
;;;; Ω4   delete-auto-save-file removes the sidecar from disk
;;;; Ω5   recover-file: sidecar newer than orig → prompt fired,
;;;;        read-fn called with sidecar path
;;;; Ω6   auto-save-all-buffers iterates *buffer-list-fn* and writes
;;;;        a sidecar per buffer
;;;; Ω7   tick: counter increments; reaching *auto-save-interval*
;;;;        triggers auto-save-all-buffers + resets counter

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v024as"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-auto-save.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun slurp (path)
  (with-open-file (s path :direction :input :if-does-not-exist :error)
    (let ((buf (make-string (file-length s))))
      (read-sequence buf s)
      buf)))

(format t "~%=== batch-os-v024-auto-save ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v024as-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v024as.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── per-buffer fixture (no real C++ text buffer needed) ─────────────
  ;; We model two buffers as Lisp closures over visited-path + content +
  ;; modified flag. *visited-file-name-fn*, *buffer-content-fn*,
  ;; *buffer-modified-p-fn*, *buffer-list-fn* all read from this hash.
  (let* ((bufs    (make-hash-table :test 'equal))
         (path-a  "/tmp/limn-v024-as-A.txt")
         (path-b  "/tmp/limn-v024-as-B.txt")
         (side-a  "/tmp/#limn-v024-as-A.txt#")
         (side-b  "/tmp/#limn-v024-as-B.txt#"))

    ;; Seed two virtual buffers.
    (setf (gethash "b-a" bufs) (list :path path-a :content "Apple\n" :modified t))
    (setf (gethash "b-b" bufs) (list :path path-b :content "Banana\n" :modified t))

    ;; Pre-clean any stale sidecars / originals from previous runs.
    (dolist (p (list path-a path-b side-a side-b))
      (ignore-errors (delete-file p)))
    ;; Create real originals on disk so recover-file's newer-than check has
    ;; something to compare against.
    (with-open-file (s path-a :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "Original A\n" s))
    (with-open-file (s path-b :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "Original B\n" s))

    (setf limn/auto-save:*visited-file-name-fn*
          (lambda (bid) (getf (gethash bid bufs) :path)))
    (setf limn/auto-save:*buffer-content-fn*
          (lambda (bid) (getf (gethash bid bufs) :content)))
    (setf limn/auto-save:*buffer-modified-p-fn*
          (lambda (bid) (getf (gethash bid bufs) :modified)))
    (setf limn/auto-save:*buffer-list-fn*
          (lambda () (loop for k being the hash-keys of bufs collect k)))

    ;;; ── Ω1: sidecar naming ──────────────────────────────────────────────
    (format t "~%── Ω1: auto-save-file-name ──~%")
    (let ((p (limn/auto-save:auto-save-file-name "b-a")))
      (check (format nil "Ω1 sidecar = \"/tmp/#limn-v024-as-A.txt#\" (got ~s)" p)
             (equal p side-a)))

    ;;; ── Ω2: write sidecar to disk ───────────────────────────────────────
    (format t "~%── Ω2: auto-save-buffer (modified) ──~%")
    (limn/auto-save:auto-save-buffer "b-a")
    (check (format nil "Ω2a sidecar exists on disk at ~a" side-a)
           (probe-file side-a))
    (when (probe-file side-a)
      (check (format nil "Ω2b sidecar content matches buffer content (got ~s)"
                     (slurp side-a))
             (equal (slurp side-a) "Apple\n")))

    ;;; ── Ω3: skip when not modified ──────────────────────────────────────
    (format t "~%── Ω3: auto-save-buffer (unmodified) ──~%")
    (setf (getf (gethash "b-a" bufs) :modified) nil)
    ;; Delete the sidecar so a successful skip means it's still gone.
    (ignore-errors (delete-file side-a))
    (limn/auto-save:auto-save-buffer "b-a")
    (check (format nil "Ω3 sidecar NOT written when buffer is clean (probe=~s)"
                   (probe-file side-a))
           (null (probe-file side-a)))

    ;;; ── Ω4: delete-auto-save-file ──────────────────────────────────────
    (format t "~%── Ω4: delete-auto-save-file ──~%")
    ;; Re-mark + auto-save to recreate the sidecar.
    (setf (getf (gethash "b-a" bufs) :modified) t)
    (limn/auto-save:auto-save-buffer "b-a")
    (check "Ω4a sidecar present before delete" (probe-file side-a))
    (limn/auto-save:delete-auto-save-file "b-a")
    (check (format nil "Ω4b sidecar gone after delete (probe=~s)"
                   (probe-file side-a))
           (null (probe-file side-a)))

    ;;; ── Ω5: recover-file flow ──────────────────────────────────────────
    (format t "~%── Ω5: recover-file prompt + read ──~%")
    ;; Re-create the sidecar with NEWER content than the original.
    (sleep 1.1)   ; bump mtime so :newer-p check passes (1s granularity)
    (with-open-file (s side-a :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string "Recovered A\n" s))
    (let ((prompt-fired nil)
          (read-target nil)
          (orig-yes-no   limn/auto-save:*minibuffer-yes-no-fn*)
          (orig-read     limn/auto-save:*read-auto-save-fn*))
      (setf limn/auto-save:*minibuffer-yes-no-fn*
            (lambda (prompt)
              (declare (ignore prompt))
              (setf prompt-fired t)
              t))
      (setf limn/auto-save:*read-auto-save-fn*
            (lambda (path)
              (setf read-target path)
              (funcall orig-read path)))
      (limn/auto-save:recover-file path-a)
      (check (format nil "Ω5a yes-no prompt fired (got ~a)" prompt-fired)
             prompt-fired)
      (check (format nil "Ω5b read-fn called with sidecar path (got ~s)" read-target)
             (equal read-target side-a))
      (setf limn/auto-save:*minibuffer-yes-no-fn* orig-yes-no
            limn/auto-save:*read-auto-save-fn*    orig-read))

    ;;; ── Ω6: auto-save-all-buffers iterates list ────────────────────────
    (format t "~%── Ω6: auto-save-all-buffers ──~%")
    ;; Reset modified flags + remove sidecars to start clean.
    (setf (getf (gethash "b-a" bufs) :modified) t
          (getf (gethash "b-b" bufs) :modified) t)
    (dolist (p (list side-a side-b)) (ignore-errors (delete-file p)))
    (limn/auto-save:auto-save-all-buffers)
    (check (format nil "Ω6a sidecar A on disk (probe=~a)" (probe-file side-a))
           (probe-file side-a))
    (check (format nil "Ω6b sidecar B on disk (probe=~a)" (probe-file side-b))
           (probe-file side-b))

    ;;; ── Ω7: tick → counter + threshold trigger ─────────────────────────
    (format t "~%── Ω7: tick threshold ──~%")
    (limn/auto-save:reset-counter)
    (let ((limn/auto-save:*auto-save-interval* 3))
      ;; Clear sidecars first, then tick. On the 3rd tick the threshold
      ;; should fire auto-save-all-buffers + reset counter to 0.
      (dolist (p (list side-a side-b)) (ignore-errors (delete-file p)))
      (limn/auto-save:tick)
      (limn/auto-save:tick)
      (check (format nil "Ω7a no fire after 2 ticks; sidecar A absent (probe=~a)"
                     (probe-file side-a))
             (null (probe-file side-a)))
      (limn/auto-save:tick)   ; threshold met
      (check (format nil "Ω7b 3rd tick fires auto-save-all (sidecar A present=~a)"
                     (probe-file side-a))
             (probe-file side-a))
      (check (format nil "Ω7c counter reset to 0 (got ~a)"
                     limn/auto-save:*auto-save-counter*)
             (zerop limn/auto-save:*auto-save-counter*)))

    ;; Cleanup test artifacts.
    (dolist (p (list path-a path-b side-a side-b))
      (ignore-errors (delete-file p))))

  (ignore-errors (limn:stop))
  (sleep 0.1)
  (handler-case (sb-ext:process-kill proc 15) (error () nil))
  (handler-case (sb-ext:process-wait proc) (error () nil)))

(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failure(s))~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
