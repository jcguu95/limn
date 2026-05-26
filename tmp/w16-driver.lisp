;;;; W16 — CJK 編輯
(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))
(defun xdotool (&rest args) (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))
(defun wait-for-window (n) (let ((d (+ (get-universal-time) 5))) (loop (when (zerop (sb-ext:process-exit-code (sb-ext:run-program "xdotool" (list "search" "--name" n) :search t :wait t :output nil))) (return t)) (when (> (get-universal-time) d) (return nil)) (sleep 0.1))))
(ensure-directories-exist "/host-tmp/receipts/16/")
(defparameter *path* (format nil "/tmp/w16-cjk-~a.org" (sb-posix:getpid)))
(defparameter *results* nil)
(defun check (l ok &optional (d "")) (push (cons l ok) *results*) (format t "  ~a ~a~a~%" (if ok "✓" "✗") l (if (string= d "") "" (format nil "   [~a]" d))))

(format t "~%── W16 CJK 編輯 ──~%")
(with-open-file (s *path* :direction :output :if-exists :supersede :element-type '(unsigned-byte 8))
  (let ((bytes (sb-ext:string-to-octets "測試中文編輯能力" :external-format :utf-8)))
    (write-sequence bytes s)))

(let* ((sock (format nil "/tmp/limn-w16-~a" (sb-posix:getpid))) (limn-bin "/limn/sioyek/limn")
       (proc (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock) :wait nil :search nil :output "/tmp/limn-w16.log" :if-output-exists :supersede :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock) (wait-for-window "Limn") (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate") (sleep 0.3)
  (let ((bid (limn/file:find-file *path*)))
    (check "A.1 CJK file open"
           (and bid t)
           (format nil "bid=~a" bid))
    ;; v0.39: xdotool's `type` for CJK relies on X11 XSendKeyEvent
    ;; which strips Unicode in headless Xvfb — no IME, no
    ;; Latin-1-equivalent keysym for CJK glyphs.  That's an X11
    ;; quirk, NOT a Limn editing-pipeline gap.  Use the kill-ring
    ;; path (same wire C-y goes through) to prove buffer/insert +
    ;; buffer/save survive multi-byte UTF-8 unchanged.
    (limn/kill:kill-new "新增中文段落")
    (sleep 0.1)
    (xdotool "key" "--clearmodifiers" "ctrl+y")
    (sleep 0.4)
    (handler-case (limn/file:save-buffer bid) (error () nil))
    (sleep 0.3)
    (let ((content (when (probe-file *path*) (with-open-file (s *path* :element-type '(unsigned-byte 8))
                                                (let ((b (make-array (file-length s) :element-type '(unsigned-byte 8))))
                                                  (read-sequence b s)
                                                  (sb-ext:octets-to-string b :external-format :utf-8))))))
      (check "A.2 file contains new CJK content"
             (and content (search "新增中文段落" content) t)
             (format nil "content=~s" content))))
  (ignore-errors (delete-file *path*))
  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t)))
(let* ((rev (reverse *results*)) (pass (count-if #'cdr rev)) (total (length rev)))
  (format t "~%── W16 result: ~a / ~a pass ──~%" pass total)
  (sb-ext:exit :code (if (= pass total) 0 1)))
