;;;; v0.24 §A — kill-ring + yank OS-tier roundtrip
;;;;
;;;; Spawn real limn binary, create a text buffer via wire, wire the
;;;; kill-ring module's I/O vtable to buffer/* wire calls, then exercise
;;;; kill-new / kill-region / yank / kill-append / copy-region-as-kill.
;;;;
;;;; No Xvfb needed — pure wire-level.
;;;;
;;;; Ω1  kill-new → *kill-ring* non-empty
;;;; Ω2a kill-region 0..5 → ring head = "Hello"
;;;; Ω2b kill-region 0..5 → buffer remaining = " world"
;;;; Ω3  yank → buffer restored to "Hello world"
;;;; Ω4  kill-append → head grows to "foobar"
;;;; Ω5a copy-region-as-kill → ring head updated
;;;; Ω5b copy-region-as-kill → buffer unchanged

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v024ky"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-kill.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))
(defun buf-text (bid)
  (let* ((r (limn:call "buffer/text" :|buffer-id| bid)))
    (and (ok? r) (getf (data r) :|text|))))

(format t "~%=== batch-os-v024-kill-yank ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v024ky-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v024ky.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  (let* ((r   (limn:call "bridge/engine-load"
                          :|engine| "text" :|path| "" :|win-id| "w1"))
         (bid (and (ok? r) (getf (data r) :|buffer-id|))))
    (check "engine-load text → buffer-id" (and bid (stringp bid)))

    (when bid
      ;;; ── wire vtable ────────────────────────────────────────────────────
      (setf limn/kill:*buffer-text-fn*
            (lambda (b from to)
              (subseq (or (buf-text b) "") from to)))
      (setf limn/kill:*buffer-insert-fn*
            (lambda (b off str)
              (limn:call "buffer/insert" :|buffer-id| b :|at| off :|text| str)))
      (setf limn/kill:*buffer-delete-fn*
            (lambda (b from len)
              (limn:call "buffer/delete"
                         :|buffer-id| b :|from| from :|to| (+ from len))))
      (setf limn/kill:*buffer-cursor-fn*
            (lambda (b)
              (or (getf (data (limn:call "buffer/cursor-get" :|buffer-id| b))
                        :|offset|)
                  0)))
      (setf limn/kill:*buffer-set-cursor-fn*
            (lambda (b off)
              (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| off)))

      ;;; ── seed buffer with "Hello world" ────────────────────────────────
      (limn:call "buffer/insert" :|buffer-id| bid :|at| 0 :|text| "Hello world")
      (setf limn/kill:*kill-ring* nil)

      ;;; ── Ω1: kill-new ──────────────────────────────────────────────────
      (format t "~%── Ω1: kill-new ──~%")
      (limn/kill:kill-new "seed")
      (check "Ω1 kill-new → ring non-empty"
             (consp limn/kill:*kill-ring*))

      ;;; ── Ω2: kill-region 0..5 ──────────────────────────────────────────
      (format t "~%── Ω2: kill-region ──~%")
      (setf limn/kill:*kill-ring* nil)
      (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
      (limn/kill:kill-region bid 0 5)
      (let ((head (car limn/kill:*kill-ring*))
            (txt  (buf-text bid)))
        (check (format nil "Ω2a ring head = \"Hello\" (got ~s)" head)
               (equal head "Hello"))
        (check (format nil "Ω2b buffer remaining = \" world\" (got ~s)" txt)
               (equal txt " world")))

      ;;; ── Ω3: yank ──────────────────────────────────────────────────────
      (format t "~%── Ω3: yank ──~%")
      (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
      (limn/kill:yank bid)
      (let ((txt (buf-text bid)))
        (check (format nil "Ω3 yank → \"Hello world\" (got ~s)" txt)
               (equal txt "Hello world")))

      ;;; ── Ω4: kill-append ───────────────────────────────────────────────
      (format t "~%── Ω4: kill-append ──~%")
      (setf limn/kill:*kill-ring* nil)
      (limn/kill:kill-new "foo")
      (limn/kill:kill-append "bar")
      (let ((head (car limn/kill:*kill-ring*)))
        (check (format nil "Ω4 kill-append → \"foobar\" (got ~s)" head)
               (equal head "foobar")))

      ;;; ── Ω5: copy-region-as-kill ───────────────────────────────────────
      (format t "~%── Ω5: copy-region-as-kill ──~%")
      (setf limn/kill:*kill-ring* nil)
      (let ((before (buf-text bid)))
        (limn/kill:copy-region-as-kill bid 0 5)
        (let ((head  (car limn/kill:*kill-ring*))
              (after (buf-text bid)))
          (check (format nil "Ω5a ring head = \"Hello\" (got ~s)" head)
                 (equal head "Hello"))
          (check (format nil "Ω5b buffer unchanged (got ~s)" after)
                 (equal after before))))))

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
