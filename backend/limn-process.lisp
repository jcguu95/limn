;;;; limn-process — subprocess primitive.
;;;;
;;;; Pure Lisp, sits on sb-ext:run-program. Thread-safe. v0.23 §A.
;;;;
;;;; API matches Emacs `make-process` shape: each process has named
;;;; stdout/stderr streams, an optional :sentinel called on exit, an
;;;; optional :filter called per stdout chunk. kill-process is always
;;;; non-blocking, even against already-dead handles.
;;;;
;;;; Encoding: streams decoded as :latin-1 so arbitrary bytes never
;;;; raise decode errors. ASCII text round-trips cleanly; non-ASCII
;;;; output is preserved byte-for-byte (user can re-decode if they
;;;; know the actual encoding).

(defpackage #:limn/process
  (:use #:cl)
  (:export #:make-process
           #:process-p
           #:process-status #:process-exit-code #:process-signal-num
           #:process-stdout #:process-stderr
           #:process-pid #:process-name
           #:process-live-p
           #:process-send-string #:process-send-eof
           #:process-wait
           #:kill-process
           #:list-processes
           #:shell-command
           #:process-error))

(in-package #:limn/process)

(define-condition process-error (error)
  ((message :initarg :message :reader process-error-message)
   (cause   :initarg :cause   :initform nil :reader process-error-cause))
  (:report (lambda (c s)
             (format s "process-error: ~A~@[ (cause: ~A)~]"
                     (process-error-message c)
                     (process-error-cause c)))))

(defstruct (process (:constructor %make-process)
                    (:predicate process-p))
  name
  command
  sb-proc                ; underlying sb-ext:process
  pid
  (stdout-spec :buffer)  ; :buffer / :discard / :file / function / :user-buffer
  (stderr-spec :buffer)  ; :buffer / :discard / :stdout / function
  (stdout-acc (make-array 0 :element-type 'character
                            :adjustable t :fill-pointer 0))
  (stderr-acc (make-array 0 :element-type 'character
                            :adjustable t :fill-pointer 0))
  user-stdout-buffer
  filter-fn
  stderr-filter-fn
  sentinel
  exit-code
  signal-num
  (status :run)          ; :run / :exit / :signal
  stdout-thread
  stderr-thread
  reaper-thread
  exit-semaphore)

(defvar *registry* '())
(defvar *registry-lock* (sb-thread:make-mutex :name "limn/process-registry"))

(defun %register (p)
  (sb-thread:with-mutex (*registry-lock*) (push p *registry*)))

(defun %unregister (p)
  (sb-thread:with-mutex (*registry-lock*)
    (setf *registry* (remove p *registry* :test #'eq))))

(defun list-processes ()
  (sb-thread:with-mutex (*registry-lock*) (copy-list *registry*)))

;;; ─── Stream readers ──────────────────────────────────────────────────

(defun %read-loop (stream on-chunk)
  "Read STREAM and dispatch chunks. Uses READ-SEQUENCE for bulk;
   the reaper closes the stream after the child exits, which causes
   blocked READ-SEQUENCE to return short with EOF."
  (when (and stream (open-stream-p stream))
    (let ((buf (make-string 4096)))
      (handler-case
          (loop
            (let ((n (handler-case (read-sequence buf stream)
                       (end-of-file () 0)
                       (error () 0))))
              (cond ((zerop n) (return))
                    (t (funcall on-chunk (subseq buf 0 n))))))
        (error () nil)))))

(defun %make-stdout-thread (p)
  (let ((stream (sb-ext:process-output (process-sb-proc p))))
    (when stream
      (sb-thread:make-thread
       (lambda ()
         (let ((spec (process-stdout-spec p)))
           (%read-loop
            stream
            (lambda (chunk)
              (cond ((functionp spec) (funcall spec p chunk))
                    ((eq spec :user-buffer)
                     (let ((b (process-user-stdout-buffer p)))
                       (loop for c across chunk
                             do (vector-push-extend c b))))
                    ((eq spec :buffer)
                     (loop for c across chunk
                           do (vector-push-extend c (process-stdout-acc p))))
                    (t nil))))))
       :name "limn/process-stdout"))))

(defun %make-stderr-thread (p)
  (let ((stream (sb-ext:process-error (process-sb-proc p)))
        (out-stream (sb-ext:process-output (process-sb-proc p))))
    ;; When :stderr :stdout (merged), SBCL returns the same stream
    ;; for process-error as for process-output. Spawning a second
    ;; reader on it would race; skip and let the stdout reader take
    ;; everything.
    (when (and stream (not (eq stream out-stream)))
      (sb-thread:make-thread
       (lambda ()
         (let ((spec (process-stderr-spec p)))
           (%read-loop
            stream
            (lambda (chunk)
              (cond ((functionp spec) (funcall spec p chunk))
                    ((eq spec :buffer)
                     (loop for c across chunk
                           do (vector-push-extend c (process-stderr-acc p))))
                    (t nil))))))
       :name "limn/process-stderr"))))

(defun %make-reaper-thread (p)
  (sb-thread:make-thread
   (lambda ()
     (handler-case
         (progn
           (sb-ext:process-wait (process-sb-proc p))
           ;; Drain readers. If the child fork'd (e.g. via shell)
           ;; and the grandchild still holds the pipe write end,
           ;; the reader will never see EOF naturally — fall back
           ;; to closing the stream from our side after a join
           ;; timeout, which forces EOF.
           (flet ((finish-reader (thread stream)
                    (when thread
                      (let ((joined (handler-case
                                        (sb-thread:join-thread thread :timeout 1)
                                      (sb-thread:join-thread-error () :timeout)
                                      (error () :err))))
                        (when (or (eq joined :timeout) (eq joined :err))
                          (when (and stream (open-stream-p stream))
                            (handler-case (close stream) (error () nil)))
                          (handler-case
                              (sb-thread:join-thread thread :timeout 2)
                            (error () nil)))))))
             (finish-reader (process-stdout-thread p)
                            (sb-ext:process-output (process-sb-proc p)))
             (finish-reader (process-stderr-thread p)
                            (sb-ext:process-error (process-sb-proc p))))
           ;; Capture exit status.
           (let* ((sb (process-sb-proc p))
                  (status (sb-ext:process-status sb))
                  (code   (sb-ext:process-exit-code sb)))
             (case status
               (:exited (setf (process-status p) :exit
                              (process-exit-code p) code))
               (:signaled (setf (process-status p) :signal
                                (process-signal-num p) code))
               (t (setf (process-status p) :exit
                        (process-exit-code p) code))))
           (sb-thread:signal-semaphore (process-exit-semaphore p))
           (%unregister p)
           (when (process-sentinel p)
             (let ((err (find-package '#:limn/error)))
               (if err
                   (funcall (find-symbol "%CALL-WITH-PROTECTION" err)
                            (process-sentinel p) p)
                   (handler-case (funcall (process-sentinel p) p)
                     (error () nil))))))
       (error () nil)))
   :name "limn/process-reaper"))

;;; ─── make-process ────────────────────────────────────────────────────

(defun %coerce-env (env)
  ;; ((\"KEY\" . \"VAL\") ...) → (\"KEY=VAL\" ...) AND merge parent env.
  (let* ((parent (sb-ext:posix-environ))
         (over (loop for (k . v) in env collect (format nil "~A=~A" k v))))
    (append over parent)))

(defun make-process (&key name command
                          (stdout :buffer) (stderr :buffer)
                          (stdin :pipe)
                          stdout-buffer
                          sentinel
                          env cwd
                          timeout)
  (declare (ignore name))
  (unless (and command (listp command))
    (error 'process-error
           :message (format nil "command must be a list, got: ~S" command)))
  (let* ((program (first command))
         (args    (rest command))
         (sb-out
           (cond ((eq stdout :discard) #P"/dev/null")
                 ((pathnamep stdout) stdout)
                 ((stringp stdout) (pathname stdout))
                 (t :stream)))
         (sb-err
           (cond ((eq stderr :stdout) :output)
                 ((eq stderr :discard) #P"/dev/null")
                 (t :stream)))
         (sb-in  (cond ((eq stdin :closed) nil)
                       (t :stream)))
         (sb-env (when env (%coerce-env env))))
    (let ((sb-proc
            (handler-case
                (apply #'sb-ext:run-program
                       program args
                       :wait nil
                       :output sb-out
                       :error sb-err
                       :input sb-in
                       :external-format :latin-1
                       (append
                        (when (pathnamep sb-out)
                          (list :if-output-exists :append))
                        (when (pathnamep sb-err)
                          (list :if-error-exists :append))
                        (when env (list :environment sb-env))
                        (when cwd (list :directory cwd))))
              (error (e)
                (error 'process-error
                       :message (format nil "failed to spawn ~S" command)
                       :cause e)))))
      (unless sb-proc
        (error 'process-error :message (format nil "spawn returned nil: ~S" command)))
      (let ((p (%make-process
                :name (or name (princ-to-string program))
                :command command
                :sb-proc sb-proc
                :pid (sb-ext:process-pid sb-proc)
                :stdout-spec
                (cond (stdout-buffer :user-buffer)
                      ((functionp stdout) stdout)
                      ((or (pathnamep stdout) (stringp stdout)) :file)
                      ((eq stdout :discard) :discard)
                      (t :buffer))
                :stderr-spec
                (cond ((functionp stderr) stderr)
                      ((eq stderr :stdout) :stdout)
                      ((eq stderr :discard) :discard)
                      (t :buffer))
                :user-stdout-buffer stdout-buffer
                :filter-fn (when (functionp stdout) stdout)
                :stderr-filter-fn (when (functionp stderr) stderr)
                :sentinel sentinel
                :exit-semaphore (sb-thread:make-semaphore))))
        (%register p)
        (setf (process-stdout-thread p) (%make-stdout-thread p)
              (process-stderr-thread p) (%make-stderr-thread p)
              (process-reaper-thread p) (%make-reaper-thread p))
        (when (and timeout (numberp timeout) (plusp timeout))
          (sb-thread:make-thread
           (lambda ()
             (handler-case (sleep timeout) (error () nil))
             (when (process-live-p p)
               (handler-case (kill-process p :KILL) (error () nil))))
           :name "limn/process-timeout"))
        p))))

;;; ─── Query API ───────────────────────────────────────────────────────

(defun process-live-p (p)
  (eq (process-status p) :run))

(defun process-stdout (p)
  (cond ((eq (process-stdout-spec p) :buffer) (coerce (process-stdout-acc p) 'string))
        ((eq (process-stdout-spec p) :user-buffer)
         (coerce (process-user-stdout-buffer p) 'string))
        (t "")))

(defun process-stderr (p)
  (cond ((eq (process-stderr-spec p) :buffer) (coerce (process-stderr-acc p) 'string))
        (t "")))

;;; ─── Wait ────────────────────────────────────────────────────────────

(defun process-wait (p &key (timeout 30))
  "Block until P exits or TIMEOUT seconds pass. Returns the final status."
  (sb-thread:wait-on-semaphore (process-exit-semaphore p) :timeout timeout)
  (process-status p))

;;; ─── Send / kill ─────────────────────────────────────────────────────

(defun process-send-string (p str)
  (let ((in (handler-case (sb-ext:process-input (process-sb-proc p))
              (error () nil))))
    (unless (and in (open-stream-p in))
      (error 'process-error :message "stdin not available or closed"))
    (handler-case
        (progn (write-string str in) (force-output in))
      (error (e)
        (error 'process-error :message "write failed" :cause e))))
  nil)

(defun process-send-eof (p)
  (let ((in (handler-case (sb-ext:process-input (process-sb-proc p))
              (error () nil))))
    (when (and in (open-stream-p in))
      (handler-case (close in) (error () nil))))
  nil)

(defun %sig (sig)
  (case sig
    ((:TERM nil) 15)
    (:KILL 9)
    (:HUP 1)
    (:INT 2)
    (otherwise (if (integerp sig) sig 15))))

(defun kill-process (p &optional (signal :TERM))
  "Send SIGNAL to P. Returns immediately. Safe on already-exited /
   stale handles — never blocks, never raises."
  (handler-case
      (let ((sb (process-sb-proc p)))
        (when (and sb (sb-ext:process-alive-p sb))
          (sb-ext:process-kill sb (%sig signal))))
    (error () nil))
  nil)

;;; ─── Shell helper ────────────────────────────────────────────────────

(defun shell-command (cmd)
  "Run CMD via /bin/sh -c. Returns (values stdout stderr exit-code)."
  (let ((p (make-process :command (list "/bin/sh" "-c" cmd))))
    (process-wait p :timeout 30)
    (values (process-stdout p)
            (process-stderr p)
            (process-exit-code p))))
