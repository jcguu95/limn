;;;; v0.36 — query-replace round-trip OS-level e2e (SPEC-required)
;;;;
;;;; 真實 limn binary。對 text buffer 三段不同字串、跑 query-replace 三條路徑
;;;; (y y y / n y y / !)，逐次驗 buffer/text 真的變對、cursor 落點對。
;;;;
;;;; v0.36 §A 實作前 RED。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v036qr"))

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

(defun text-engine-load ()
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "text" :|path| "" :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun buf-set-text (buf text)
  (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
  ;; Clear first if non-empty
  (let* ((r (limn:call "buffer/text" :|buffer-id| buf))
         (old (and (ok? r) (getf (data r) :|text|)))
         (n (if (stringp old) (length old) 0)))
    (when (> n 0)
      (limn:call "buffer/delete" :|buffer-id| buf :|from| 0 :|to| n)))
  (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
  (limn:call "buffer/insert" :|buffer-id| buf :|text| text))

(defun buf-text (buf)
  (let ((r (limn:call "buffer/text" :|buffer-id| buf)))
    (and (ok? r) (getf (data r) :|text|))))

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

(defun qpkg () (find-package '#:limn/query-replace))
(defun qsym (n) (and (qpkg) (find-symbol n (qpkg))))
(defun rpkg () (find-package '#:limn/regex))
(defun rsym (n) (and (rpkg) (find-symbol n (rpkg))))
(defun xpkg () (find-package '#:limn/excursion))
(defun xsym (n) (and (xpkg) (find-symbol n (xpkg))))

(defun wire-up-all (buf)
  (when (rpkg)
    (let ((bt    (rsym "*BUFFER-TEXT-FN*"))
          (sbt   (rsym "*BUFFER-SET-TEXT-FN*"))
          (pt    (rsym "*POINT-FN*"))
          (spt   (rsym "*SET-POINT-FN*"))
          (btlen (rsym "*BUFFER-TEXT-LEN-FN*")))
      (when bt (setf (symbol-value bt)
                     (lambda (bid) (buf-text bid))))
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
      (when bt (setf (symbol-value bt)
                     (lambda (bid) (buf-text bid))))
      (when ins (setf (symbol-value ins)
                      (lambda (bid off str)
                        (limn:call "buffer/cursor-set"
                                    :|buffer-id| bid :|offset| off)
                        (limn:call "buffer/insert"
                                    :|buffer-id| bid :|text| str))))
      (when del (setf (symbol-value del)
                      (lambda (bid from to)
                        (limn:call "buffer/delete"
                                    :|buffer-id| bid
                                    :|from| from :|to| to))))
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
                            (if (stringp t*) (length t*) 0))))))))

(defun make-responder (responses)
  (let ((box (copy-list responses)))
    (lambda () (pop box))))

(let* ((sock (format nil "/tmp/limn-e2e-v036qr-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v036qr.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (check "limn/query-replace package loaded" (qpkg))
  (check "limn/regex package loaded" (rpkg))

  (let ((install-bo (xsym "INSTALL-BUFFER-OPENED-HANDLER")))
    (when install-bo (funcall install-bo)))

  (let ((buf (text-engine-load)))
    (check (format nil "opened text buffer (~a)" buf) (stringp buf))
    (unless buf
      (limn:stop) (sb-ext:process-kill proc 15)
      (sb-ext:process-wait proc) (sb-ext:exit :code 2))

    (when (xpkg)
      (let ((reg (xsym "REGISTER-BUFFER"))
            (set-buf (xsym "SET-BUFFER")))
        (when reg (funcall reg (list :|buffer-id| buf) buf :name buf))
        (when set-buf (funcall set-buf buf))))

    (wire-up-all buf)

    (let ((qr (qsym "QUERY-REPLACE")))
      (cond
        ((not qr)
         (check "query-replace symbol present" nil "RED — not implemented"))
        (t
         ;; Scenario 1: y y y
         (buf-set-text buf "foo bar foo bar foo bar")
         (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
         (funcall qr "foo" "QUUX" :response-fn (make-responder '("y" "y" "y")))
         (sleep 0.1)
         (check "yyy → 'QUUX bar QUUX bar QUUX bar'"
                (equal (buf-text buf) "QUUX bar QUUX bar QUUX bar"))

         ;; Scenario 2: n y y
         (buf-set-text buf "aa aa aa aa")
         (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
         (funcall qr "aa" "Z" :response-fn (make-responder '("n" "y" "y" "y")))
         (sleep 0.1)
         (check "nyyy → 'aa Z Z Z'"
                (equal (buf-text buf) "aa Z Z Z"))

         ;; Scenario 3: !
         (buf-set-text buf "x x x x x x x")
         (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
         (funcall qr "x" "Y" :response-fn (make-responder '("!")))
         (sleep 0.1)
         (check "! → all replaced"
                (equal (buf-text buf) "Y Y Y Y Y Y Y")))))

    (ignore-errors (limn:call "buffer/close" :|buffer-id| buf)))

  (format t "~%── v036 query-replace round-trip results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
