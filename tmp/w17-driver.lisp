;;;; W17 — 跨檔 kill/yank
(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))
(defun xdotool (&rest args) (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))
(defun wait-for-window (n) (let ((d (+ (get-universal-time) 5))) (loop (when (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" (list "search" "--name" n) :search t :wait t :output nil))) (return t)) (when (> (get-universal-time) d) (return nil)) (sleep 0.1))))
(ensure-directories-exist "/host-tmp/receipts/17/")
(defparameter *path-a* (format nil "/tmp/w17-A-~a.txt" (sb-posix:getpid)))
(defparameter *path-b* (format nil "/tmp/w17-B-~a.txt" (sb-posix:getpid)))
(defparameter *results* nil)
(defun check (l ok &optional (d "")) (push (cons l ok) *results*) (format t "  ~a ~a~a~%" (if ok "✓" "✗") l (if (string= d "") "" (format nil "   [~a]" d))))

(format t "~%── W17 跨檔 kill/yank ──~%")
(with-open-file (s *path-a* :direction :output :if-exists :supersede) (write-string "hello world from A" s))
(with-open-file (s *path-b* :direction :output :if-exists :supersede) (write-string "" s))

(let* ((sock (format nil "/tmp/limn-w17-~a" (sb-posix:getpid))) (limn-bin "/limn/sioyek/limn")
       (proc (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock) :wait nil :search nil :output "/tmp/limn-w17.log" :if-output-exists :supersede :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (wait-for-window "Limn") (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate") (sleep 0.3)
  ;; v0.39 W17 honest: open both buffers up-front, then use the new
  ;; buffer/show wire path (via find-file's "already-open" branch) to
  ;; switch between them.  Mirrors what a real Emacs user does:
  ;; C-x C-f A → C-x C-f B → buffers list has both → C-x b A → kill →
  ;; C-x b B → yank.  Re-find-file is the simplest user gesture that
  ;; routes through buffer/show — driver uses it as the "switch"
  ;; primitive without needing to drive completing-read in-process.
  (let ((bid-a (limn/file:find-file *path-a*))
        (bid-b (limn/file:find-file *path-b*)))
    (check "A.1 open both files" (and bid-a bid-b)
           (format nil "a=~a b=~a" bid-a bid-b))
    (sleep 0.3)
    ;; Switch back to A (find-file on an already-open path now
    ;; triggers buffer/show under the hood).  Without this, view
    ;; was last on B and the C-SPC/C-e/C-w would have run on B.
    (limn/file:find-file *path-a*)
    (sleep 0.3)
    (xdotool "key" "--clearmodifiers" "ctrl+space") (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "ctrl+e")     (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "ctrl+w")     (sleep 0.3)
    ;; Now switch to B and yank.
    (limn/file:find-file *path-b*)
    (sleep 0.3)
    (xdotool "key" "--clearmodifiers" "ctrl+y") (sleep 0.4)
    (handler-case (limn/file:save-buffer bid-b) (error () nil))
    (sleep 0.2)
    (let ((b-content (when (probe-file *path-b*) (with-open-file (s *path-b*) (let ((b (make-string (file-length s)))) (read-sequence b s) b)))))
      (check "A.2 B has yanked content from A" (and b-content (search "hello world from A" b-content))
             (format nil "B=~s" b-content))))
  (ignore-errors (delete-file *path-a*) (delete-file *path-b*))
  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t)))
(let* ((rev (reverse *results*)) (pass (count-if #'cdr rev)) (total (length rev)))
  (format t "~%── W17 result: ~a / ~a pass ──~%" pass total)
  (sb-ext:exit :code (if (= pass total) 0 1)))
