;;;; v0.36 — indent-region + indent-rigidly + buffer-local *tab-width* on
;;;; real wire. v0.36 §B 實作前 RED。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v036ir"))

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
(defun ipkg () (find-package '#:limn/indent))
(defun isym (n) (and (ipkg) (find-symbol n (ipkg))))
(defun xpkg () (find-package '#:limn/excursion))
(defun xsym (n) (and (xpkg) (find-symbol n (xpkg))))
(defun lpkg () (find-package '#:limn/local))
(defun lsym (n) (and (lpkg) (find-symbol n (lpkg))))

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
  (when (ipkg)
    (let ((bt    (isym "*BUFFER-TEXT-FN*"))
          (ins   (isym "*BUFFER-INSERT-FN*"))
          (del   (isym "*BUFFER-DELETE-FN*"))
          (pt    (isym "*POINT-FN*"))
          (spt   (isym "*SET-POINT-FN*"))
          (btlen (isym "*BUFFER-TEXT-LEN-FN*")))
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

(let* ((sock (format nil "/tmp/limn-e2e-v036ir-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v036ir.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (sleep 0.3) (wait-for-window)

  (check "limn/indent loaded" (ipkg))

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
      (wire-up)

      (let ((sblv (lsym "SET-BUFFER-LOCAL-VALUE")))
        (when sblv
          (funcall sblv (intern "*INDENT-TABS-MODE*" :cl-user) nil buf)))

      ;; indent-rigidly +2 across whole buffer
      (let ((irig (isym "INDENT-RIGIDLY")))
        (cond
          ((not irig)
           (check "indent-rigidly present" nil "RED"))
          (t
           (buf-set-text buf (format nil "alpha~Cbeta~Cgamma" #\Newline #\Newline))
           (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
           (let ((len (length (buf-text buf))))
             (funcall irig 0 len 2))
           (sleep 0.1)
           (check "indent-rigidly +2 → '  alpha\\n  beta\\n  gamma'"
                  (equal (buf-text buf)
                         (format nil "  alpha~C  beta~C  gamma"
                                 #\Newline #\Newline))))))

      ;; indent-rigidly negative
      (let ((irig (isym "INDENT-RIGIDLY")))
        (when irig
          (buf-set-text buf (format nil "    alpha~C    beta" #\Newline))
          (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
          (let ((len (length (buf-text buf))))
            (funcall irig 0 len -2))
          (sleep 0.1)
          (check "indent-rigidly -2 strips leading whitespace"
                 (equal (buf-text buf)
                        (format nil "  alpha~C  beta" #\Newline)))))

      ;; current-column with buffer-local *tab-width* change
      (let ((cc  (isym "CURRENT-COLUMN"))
            (sblv (lsym "SET-BUFFER-LOCAL-VALUE")))
        (when (and cc sblv)
          (buf-set-text buf (string #\Tab))
          (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 1)
          (funcall sblv (intern "*TAB-WIDTH*" :cl-user) 4 buf)
          (sleep 0.05)
          (check "tab-width=4 buffer-local → current-column = 4"
                 (eql (funcall cc) 4))
          (funcall sblv (intern "*TAB-WIDTH*" :cl-user) 8 buf)
          (sleep 0.05)
          (check "tab-width=8 buffer-local → current-column = 8"
                 (eql (funcall cc) 8))))

      (ignore-errors (limn:call "buffer/close" :|buffer-id| buf))))

  (format t "~%── v036 indent-region results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn (format t "✗ ~a FAILURE(s):~%" (length *failures*))
             (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15) (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
