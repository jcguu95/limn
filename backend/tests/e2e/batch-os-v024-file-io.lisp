;;;; v0.24 §E+F+H — find-file / save-buffer / recentf OS-tier
;;;;
;;;; Exercises the filesystem I/O layer against a real binary:
;;;;   – find-file reads a /tmp file and populates a C++ text buffer
;;;;     via *buffer-set-content-fn* (verified with buffer/text wire).
;;;;   – save-buffer writes modified content to a different /tmp path
;;;;     (verified by reading the file back from disk).
;;;;   – Hooks fire at the right moments.
;;;;   – recentf-push is wired through *find-file-hook* and the list
;;;;     is populated correctly.
;;;;
;;;; No Xvfb needed — pure wire + filesystem.
;;;;
;;;; Ω1a  *find-file-hook* fires after find-file
;;;; Ω1b  content reaches C++ text buffer (buffer/text wire verify)
;;;; Ω2   save-buffer writes to disk (probe-file + slurp verify)
;;;; Ω3   *after-save-hook* fires
;;;; Ω4   recentf-list records the opened path

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v024fi"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-file.lisp" "limn-recentf.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun slurp (path)
  (with-open-file (s path :direction :input :if-does-not-exist :error)
    (let ((buf (make-string (file-length s))))
      (read-sequence buf s)
      buf)))

(format t "~%=== batch-os-v024-file-io ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v024fi-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v024fi.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── C++ text buffer: content will be injected here ────────────────────
  (let* ((cpp-r   (limn:call "bridge/engine-load"
                              :|engine| "text" :|path| "" :|win-id| "w1"))
         (cpp-bid (and (ok? cpp-r) (getf (data cpp-r) :|buffer-id|))))
    (check "engine-load text → cpp-bid" (and cpp-bid (stringp cpp-bid)))

    (when cpp-bid
      ;;; ── tmp source file ───────────────────────────────────────────────
      (let* ((src-path "/tmp/limn-v024-fio-src.txt")
             (src-content "Hello from v024 file-io test\n")
             (out-path "/tmp/limn-v024-fio-saved.txt"))

        ;; write source file to disk
        (with-open-file (s src-path :direction :output
                                    :if-exists :supersede
                                    :if-does-not-exist :create)
          (write-string src-content s))

        ;; clean up any leftover saved file from previous runs
        (ignore-errors (delete-file out-path))

        ;;; ── wire *buffer-set-content-fn* → buffer/insert on cpp-bid ─────
        ;; This is what makes Ω1b testable: find-file calls this after
        ;; reading the file, and we forward the content into the C++ buffer.
        (setf limn/file:*buffer-set-content-fn*
              (lambda (bid content)
                (declare (ignore bid))
                (when (> (length content) 0)
                  (limn:call "buffer/insert"
                             :|buffer-id| cpp-bid :|at| 0 :|text| content))))

        ;;; ── hook counters ─────────────────────────────────────────────────
        (let ((find-count 0)
              (save-count  0))

          ;; *find-file-hook* fn (bid path): record + push to recentf
          (push (lambda (bid path)
                  (declare (ignore bid))
                  (incf find-count)
                  (limn/recentf:recentf-push path))
                limn/file:*find-file-hook*)

          ;; *after-save-hook* fn (bid): just count
          (push (lambda (bid)
                  (declare (ignore bid))
                  (incf save-count))
                limn/file:*after-save-hook*)

          ;;; ── Ω1: find-file ─────────────────────────────────────────────
          (format t "~%── Ω1: find-file ──~%")
          (let ((fbid (limn/file:find-file src-path)))

            (check (format nil "Ω1a *find-file-hook* fired (count=~a)" find-count)
                   (= find-count 1))

            (let* ((tr       (limn:call "buffer/text" :|buffer-id| cpp-bid))
                   (cpp-text (and (ok? tr) (getf (data tr) :|text|))))
              (check (format nil "Ω1b content in C++ buffer (got ~s)" cpp-text)
                     (equal cpp-text src-content)))

            ;;; ── Ω2: save-buffer ─────────────────────────────────────────
            (format t "~%── Ω2: save-buffer ──~%")
            ;; limn/file tracks its own fbuf-content (separate from C++ buffer).
            ;; save-buffer writes that content to disk.
            (limn/file:save-buffer fbid out-path)
            (check (format nil "Ω2 saved file exists at ~a" out-path)
                   (probe-file out-path))
            (when (probe-file out-path)
              (let ((saved (slurp out-path)))
                (check (format nil "Ω2 saved content correct (got ~s)" saved)
                       (equal saved src-content))))

          ;;; ── Ω3: after-save-hook ───────────────────────────────────────
          (format t "~%── Ω3: after-save-hook ──~%")
          (check (format nil "Ω3 *after-save-hook* fired (count=~a)" save-count)
                 (= save-count 1))

          ;;; ── Ω4: recentf ───────────────────────────────────────────────
          (format t "~%── Ω4: recentf ──~%")
          (check (format nil "Ω4 recentf-list has src-path (list=~a)"
                         limn/recentf:*recentf-list*)
                 (member src-path limn/recentf:*recentf-list* :test #'equal))

          ;; cleanup tmp files
          (ignore-errors (delete-file src-path))
          (ignore-errors (delete-file out-path)))))))

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
