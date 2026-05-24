;;;; v0.36 — CJK char-display-width + current-column + move-to-column on
;;;; real wire. v0.36 §C 實作前 RED.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v036cjk"))

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

(let* ((sock (format nil "/tmp/limn-e2e-v036cjk-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v036cjk.log"
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

      ;; CJK column counts
      (let ((cc  (isym "CURRENT-COLUMN"))
            (mtc (isym "MOVE-TO-COLUMN")))
        (cond
          ((not (and cc mtc))
           (check "current-column / move-to-column present" nil "RED"))
          (t
           ;; 中文ABC日本語 — char widths: 2 2 1 1 1 2 2 2 = 13 total
           (buf-set-text buf
                         (concatenate 'string
                                      (string (code-char #x4E2D)) ; 中
                                      (string (code-char #x6587)) ; 文
                                      "ABC"
                                      (string (code-char #x65E5)) ; 日
                                      (string (code-char #x672C)) ; 本
                                      (string (code-char #x8A9E)))) ; 語
           ;; Cursor at end (offset 8 codepoints)
           (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 8)
           (sleep 0.05)
           (check "current-column at end = 13 (CJK 2+2 + ABC 3 + CJK 2+2+2)"
                  (eql (funcall cc) 13))

           ;; Cursor at offset 3 (中文A) → column 5
           (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 3)
           (sleep 0.05)
           (check "current-column at offset 3 (中文A) = 5"
                  (eql (funcall cc) 5))

           ;; move-to-column 10 :force t — should land at a sensible offset
           ;; (10 columns into "中文ABC日本語" = past 中(2)+文(2)+A(1)+B(1)+C(1)=7, plus 日(2)=9, then 本 starts at col 9. We want col 10 — middle of 本 → cannot split, lands either at 5 (start of 本) or 6 (end of 本).
           (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
           (funcall mtc 10 t)
           (sleep 0.05)
           (let* ((r (limn:call "buffer/cursor-get" :|buffer-id| buf))
                  (off (and (ok? r) (getf (data r) :|offset|))))
             (check (format nil "move-to-column 10 lands on grapheme boundary (got offset ~a)" off)
                    (and (integerp off) (member off '(5 6))))))))

      (ignore-errors (limn:call "buffer/close" :|buffer-id| buf))))

  (format t "~%── v036 cjk-column results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn (format t "✗ ~a FAILURE(s):~%" (length *failures*))
             (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15) (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
