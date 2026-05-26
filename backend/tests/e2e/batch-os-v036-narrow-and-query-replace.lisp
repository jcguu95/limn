;;;; v0.36 — query-replace inside narrow-to-region; also verifies markers
;;;; survive replace (v0.30 integration). v0.36 §A 實作前 RED。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v036narrow"))

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
(defun mpkg () (find-package '#:limn/marker))
(defun msym (n) (and (mpkg) (find-symbol n (mpkg))))

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
  ;; v0.37 Phase F: wire vtables on ALL packages that consume buffer
  ;; text — limn/regex, limn/query-replace, limn/excursion AND
  ;; limn/marker.  Without limn/marker:*buffer-text-len-fn*, %clamp
  ;; defaults to (lambda (bid) 0) → every set-marker call clamps the
  ;; new position to 0.  That breaks the narrow markers
  ;; (point-min/max both come back 0) AND the test's m-after marker
  ;; (sits at 0 instead of 32, so the post-replace fixup check
  ;; "32 → 28" fails with got=0).
  (dolist (pkg-fn (list #'rpkg #'qpkg #'xpkg #'mpkg))
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

(let* ((sock (format nil "/tmp/limn-e2e-v036narrow-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v036narrow.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (sleep 0.3) (wait-for-window)

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

      (let ((qr      (qsym "QUERY-REPLACE"))
            (narrow  (xsym "NARROW-TO-REGION"))
            (widen   (xsym "WIDEN"))
            (mk-mark (msym "MAKE-MARKER")))
        (cond
          ((not (and qr narrow widen))
           (check "query-replace + narrow + widen all present" nil "RED"))
          (t
           ;; Setup: "before foo middle foo middle foo after"
           ;; Narrow to "middle foo middle foo " region
           (buf-set-text buf "before foo middle foo middle foo after")
           ;; Create a marker pointing at the "after" word (offset 32 in
           ;; the original).  After replace shrinks the buffer by 4 chars
           ;; the marker should fix up to 28.
           (let* ((set-marker (msym "SET-MARKER"))
                  (set-it (msym "SET-MARKER-INSERTION-TYPE"))
                  (m-after (when (and mk-mark set-marker)
                             (let ((mk (funcall mk-mark)))
                               (funcall set-marker mk 32 buf)
                               ;; v0.37 Phase F: insertion-type :after so
                               ;; an insert at the marker's position
                               ;; pushes the marker right (matching what
                               ;; the "32 → 28" expectation assumes).
                               ;; Default :before would leave it at 27
                               ;; after the second replace's insert-at-27.
                               (when set-it (funcall set-it mk :after))
                               mk))))
             (declare (ignorable m-after))
             (progn
               ;; v0.37 Phase F: narrow must reach 32 (end-exclusive) to
               ;; include the third "foo" (at 29-31) along with the
               ;; second (at 18-20).  Original (narrow 11 31) excluded
               ;; the third because cl-ppcre:scan rejects matches that
               ;; cross the upper bound — so only 1 foo got replaced,
               ;; never the expected 2.
               (funcall narrow 11 32)
               (unwind-protect
                    (progn
                      (limn:call "buffer/cursor-set" :|buffer-id| buf
                                  :|offset| 11)
                      (funcall qr "foo" "X"
                               :response-fn (make-responder '("!")))
                      (sleep 0.1))
                 (funcall widen))

               ;; After widen + replace: "before foo middle X middle X after"
               ;; Length shrank by 2*2 = 4 chars.
               (check "narrowed query-replace touched only inner region"
                      (equal (buf-text buf)
                             "before foo middle X middle X after"))
               (check "first foo (outside narrow) untouched"
                      (search "before foo " (buf-text buf)))

               ;; Marker was at 32 ("after"); buffer shrank by 4 ("foo"→"X"
               ;; × 2 = -4); marker should now be at 28.
               (when (and m-after (msym "MARKER-POSITION"))
                 (let ((pos (funcall (msym "MARKER-POSITION") m-after)))
                   (check (format nil "marker fixed up: 32 → 28 (got ~a)" pos)
                          (eql pos 28)))))))))

      (ignore-errors (limn:call "buffer/close" :|buffer-id| buf))))

  (format t "~%── v036 narrow + query-replace results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn (format t "✗ ~a FAILURE(s):~%" (length *failures*))
             (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15) (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
