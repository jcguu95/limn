;;;; v0.36 — query-replace-regexp OS-level e2e
;;;;
;;;; 真實 limn binary。驗 query-replace-regexp + group references end-to-end
;;;; 在 production SBCL runtime 上 byte-perfect。v0.36 §A 實作前 RED。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v036qrr"))

(handler-case (load (b/ "../vendor/cl-ppcre-load.lisp"))
  (error (e) (format t "  !! skipped vendor cl-ppcre: ~A~%" e)))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-timer.lisp" "limn-process.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-undo.lisp" "limn-buffer-undo.lisp"
             "limn-keys.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp"
             "limn-text-mode.lisp"
             "limn-marker.lisp" "limn-local.lisp"
             "limn-mark.lisp" "limn-excursion.lisp"
             "limn-regex.lisp" "limn-indent.lisp"
             "limn-query-replace.lisp"
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

(defun wire-up (buf)
  (declare (ignore buf))
  (when (rpkg)
    (let ((bt    (rsym "*BUFFER-TEXT-FN*"))
          (sbt   (rsym "*BUFFER-SET-TEXT-FN*"))
          (pt    (rsym "*POINT-FN*"))
          (spt   (rsym "*SET-POINT-FN*"))
          (btlen (rsym "*BUFFER-TEXT-LEN-FN*")))
      (when bt (setf (symbol-value bt) (lambda (bid) (buf-text bid))))
      (when sbt (setf (symbol-value sbt)
                      (lambda (bid txt) (buf-set-text bid txt))))
      (when pt (setf (symbol-value pt)
                     (lambda (bid)
                       (let ((r (limn:call "buffer/cursor-get"
                                            :|buffer-id| bid)))
                         (and (ok? r) (getf (data r) :|offset|))))))
      (when spt (setf (symbol-value spt)
                      (lambda (bid off)
                        (limn:call "buffer/cursor-set"
                                    :|buffer-id| bid :|offset| off))))
      (when btlen (setf (symbol-value btlen)
                        (lambda (bid)
                          (let ((t* (buf-text bid)))
                            (if (stringp t*) (length t*) 0)))))))
  (when (qpkg)
    (let ((bt   (qsym "*BUFFER-TEXT-FN*"))
          (ins  (qsym "*BUFFER-INSERT-FN*"))
          (del  (qsym "*BUFFER-DELETE-FN*"))
          (pt   (qsym "*POINT-FN*"))
          (spt  (qsym "*SET-POINT-FN*"))
          (btlen (qsym "*BUFFER-TEXT-LEN-FN*")))
      (when bt (setf (symbol-value bt) (lambda (bid) (buf-text bid))))
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

(let* ((sock (format nil "/tmp/limn-e2e-v036qrr-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v036qrr.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (sleep 0.3) (wait-for-window)

  (check "limn/query-replace loaded" (qpkg))

  (let ((install-bo (xsym "INSTALL-BUFFER-OPENED-HANDLER")))
    (when install-bo (funcall install-bo)))

  (let ((buf (text-engine-load)))
    (check (format nil "opened text buffer (~a)" buf) (stringp buf))
    (when buf
      (when (xpkg)
        (let ((reg (xsym "REGISTER-BUFFER"))
              (set-buf (xsym "SET-BUFFER")))
          (when reg (funcall reg (list :|buffer-id| buf) buf :name buf))
          (when set-buf (funcall set-buf buf))))
      (wire-up buf)

      (let ((qrr (qsym "QUERY-REPLACE-REGEXP")))
        (cond
          ((not qrr)
           (check "query-replace-regexp present" nil "RED"))
          (t
           ;; \(\d+\)px → \1em on 4 matches
           (buf-set-text buf "12px 34px 56px 78px")
           (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
           (funcall qrr "\\([0-9]+\\)px" "\\1em"
                    :response-fn (make-responder '("!")))
           (sleep 0.1)
           (check "regex group ref ! → '12em 34em 56em 78em'"
                  (equal (buf-text buf) "12em 34em 56em 78em"))

           ;; Group swap: \(a\)\(b\) → \2\1
           (buf-set-text buf "ab ab ab")
           (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
           (funcall qrr "\\(a\\)\\(b\\)" "\\2\\1"
                    :response-fn (make-responder '("!")))
           (sleep 0.1)
           (check "regex group swap → 'ba ba ba'"
                  (equal (buf-text buf) "ba ba ba"))

           ;; Word boundary
           (buf-set-text buf "foo foobar foo bar")
           (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
           (funcall qrr "\\bfoo\\b" "X"
                    :response-fn (make-responder '("!")))
           (sleep 0.1)
           (check "\\bfoo\\b → 'X foobar X bar'"
                  (equal (buf-text buf) "X foobar X bar"))

           ;; Mixed y n
           (buf-set-text buf "1 2 3 4")
           (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
           (funcall qrr "[0-9]" "X"
                    :response-fn (make-responder '("y" "n" "y" "n")))
           (sleep 0.1)
           (check "y n y n on 4 digits → 'X 2 X 4'"
                  (equal (buf-text buf) "X 2 X 4")))))

      (ignore-errors (limn:call "buffer/close" :|buffer-id| buf))))

  (format t "~%── v036 query-replace-regexp results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn (format t "✗ ~a FAILURE(s):~%" (length *failures*))
             (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15) (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
