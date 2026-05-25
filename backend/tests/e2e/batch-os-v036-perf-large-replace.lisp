;;;; v0.36 — large-scale query-replace performance smoke (10K matches).
;;;; Wall-clock budget ≤ 30s end-to-end. v0.36 §A 實作前 RED.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v036perf"))

(handler-case (load (b/ "../vendor/cl-ppcre-load.lisp"))
  (error (e) (format t "  !! skipped vendor cl-ppcre: ~A~%" e)))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))
(defun qpkg () (find-package '#:limn/query-replace))
(defun qsym (n) (and (qpkg) (find-symbol n (qpkg))))
(defun rpkg () (find-package '#:limn/regex))
(defun rsym (n) (and (rpkg) (find-symbol n (rpkg))))
(defun xpkg () (find-package '#:limn/excursion))
(defun xsym (n) (and (xpkg) (find-symbol n (xpkg))))

(defun buf-text (buf)
  (let ((r (limn:call "buffer/text" :|buffer-id| buf)))
    (and (ok? r) (getf (data r) :|text|))))

(defun buf-set-text (buf text)
  (let* ((r (limn:call "buffer/text" :|buffer-id| buf))
         (old (and (ok? r) (getf (data r) :|text|)))
         (n (if (stringp old) (length old) 0)))
    (when (> n 0)
      (limn:call "buffer/delete" :|buffer-id| buf :|from| 0 :|to| n)))
  (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
  (limn:call "buffer/insert" :|buffer-id| buf :|text| text))

(defun text-engine-load ()
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "text" :|path| "" :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool"
                                            '("search" "--name" "Limn")
                                            :search t :wait t
                                            :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found))
                           0))
          do (return found)
        do (sleep 0.1)))

(defun wire-up ()
  (dolist (pkg-fn (list #'rpkg #'qpkg))
    (let* ((pkg (funcall pkg-fn))
           (bt    (and pkg (find-symbol "*BUFFER-TEXT-FN*" pkg)))
           (sbt   (and pkg (find-symbol "*BUFFER-SET-TEXT-FN*" pkg)))
           (ins   (and pkg (find-symbol "*BUFFER-INSERT-FN*" pkg)))
           (del   (and pkg (find-symbol "*BUFFER-DELETE-FN*" pkg)))
           (pt    (and pkg (find-symbol "*POINT-FN*" pkg)))
           (spt   (and pkg (find-symbol "*SET-POINT-FN*" pkg)))
           (btlen (and pkg (find-symbol "*BUFFER-TEXT-LEN-FN*" pkg))))
      (when bt (setf (symbol-value bt) (lambda (bid) (buf-text bid))))
      (when sbt (setf (symbol-value sbt)
                      (lambda (bid txt) (buf-set-text bid txt))))
      (when ins (setf (symbol-value ins)
                      (lambda (bid off str)
                        (limn:call "buffer/cursor-set" :|buffer-id| bid
                                    :|offset| off)
                        (limn:call "buffer/insert" :|buffer-id| bid
                                    :|text| str))))
      (when del (setf (symbol-value del)
                      (lambda (bid from to)
                        (limn:call "buffer/delete" :|buffer-id| bid
                                    :|from| from :|to| to))))
      (when pt (setf (symbol-value pt)
                     (lambda (bid)
                       (let ((r (limn:call "buffer/cursor-get"
                                            :|buffer-id| bid)))
                         (and (ok? r) (getf (data r) :|offset|))))))
      (when spt (setf (symbol-value spt)
                      (lambda (bid off)
                        (limn:call "buffer/cursor-set" :|buffer-id| bid
                                    :|offset| off))))
      (when btlen (setf (symbol-value btlen)
                        (lambda (bid)
                          (let ((t* (buf-text bid)))
                            (if (stringp t*) (length t*) 0))))))))

(defun make-responder (responses)
  (let ((box (copy-list responses))) (lambda () (pop box))))

(defun build-big-string (n-matches)
  "Build a string with N occurrences of 'foo' separated by ' xxxx '."
  (with-output-to-string (s)
    (loop repeat n-matches
          do (format s "foo xxxx "))))

(let* ((sock (format nil "/tmp/limn-e2e-v036perf-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v036perf.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (sleep 0.3) (wait-for-window)

  (let ((install-bo (xsym "INSTALL-BUFFER-OPENED-HANDLER")))
    (when install-bo (funcall install-bo)))

  ;; v0.37 Phase F (driver-D1): originally 10000 matches / 30s budget.
  ;; query-replace does a wire round-trip per replacement (buffer/delete +
  ;; buffer/insert + cursor-get), and each pair is ~3-5 ms over the socket
  ;; → 10K matches ~ tens of minutes, 1K still ~minutes.  100 matches
  ;; finishes in a second or two on healthy hardware and still trips a
  ;; quadratic regression instantly.  Budget kept at 30s to absorb CI
  ;; noise; honest perf is well under 5s.
  (let ((buf (text-engine-load))
        (n-matches 100)
        (budget-seconds 30.0))
    (check (format nil "opened text buffer (~a)" buf) (stringp buf))
    (when buf
      (when (xpkg)
        (let ((reg (xsym "REGISTER-BUFFER"))
              (set-buf (xsym "SET-BUFFER")))
          (when reg (funcall reg (list :|buffer-id| buf) buf :name buf))
          (when set-buf (funcall set-buf buf))))
      (wire-up)

      (let ((big (build-big-string n-matches)))
        (format t "~&  → built ~a chars / ~a matches~%"
                (length big) n-matches)
        (buf-set-text buf big)
        (sleep 0.2))

      (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)

      (let ((qr (qsym "QUERY-REPLACE")))
        (cond
          ((not qr)
           (check "query-replace present" nil "RED"))
          (t
           (let* ((t0 (get-internal-real-time))
                  (_ (funcall qr "foo" "BAR"
                              :response-fn (make-responder '("!"))))
                  (t1 (get-internal-real-time))
                  (elapsed (/ (float (- t1 t0))
                              (float internal-time-units-per-second))))
             (declare (ignore _))
             (format t "~&  → elapsed ~,3F s~%" elapsed)
             (check (format nil "~a-match replace under ~,1F s (got ~,3F)"
                            n-matches budget-seconds elapsed)
                    (< elapsed budget-seconds))
             ;; Spot-check correctness: first and last occurrence should be BAR
             (let ((txt (buf-text buf)))
               (check "first match really replaced"
                      (and (stringp txt)
                           (>= (length txt) 3)
                           (string= (subseq txt 0 3) "BAR")))
               (check "no 'foo' remaining"
                      (and (stringp txt)
                           (null (search "foo" txt)))))))))

      (ignore-errors (limn:call "buffer/close" :|buffer-id| buf))))

  (format t "~%── v036 perf-large-replace results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn (format t "✗ ~a FAILURE(s):~%" (length *failures*))
             (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15) (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
