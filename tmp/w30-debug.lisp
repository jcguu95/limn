;;;; W30 debug — inspect file-notify state during a write.
(in-package :cl-user)
(require :sb-posix)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *path* (format nil "/tmp/w30dbg-~a.txt" (sb-posix:getpid)))

(with-open-file (s *path* :direction :output :if-exists :supersede)
  (write-string "old" s))

(let* ((sock (format nil "/tmp/limn-w30dbg-~a" (sb-posix:getpid)))
       (limn-bin "/limn/sioyek/limn")
       (proc (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock)
                                  :wait nil :search nil
                                  :output "/tmp/limn-w30dbg.log"
                                  :if-output-exists :supersede
                                  :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.5)

  (let ((bid (limn/file:find-file *path*)))
    (format t "~%── debug ──~%")
    (format t "bid=~s, path=~s~%" bid *path*)

    ;; Enable auto-revert
    (limn/auto-revert:auto-revert-mode bid)
    (format t "after enable: *entries*=~s~%" limn/auto-revert::*entries*)
    (format t "*watches*=~a item(s)~%" (length limn/file-notify::*watches*))
    (format t "*helper-proc*=~s~%" limn/file-notify::*helper-proc*)
    (format t "*file-notify-backend*=~s~%"
            limn/file-notify:*file-notify-backend*)
    (format t "helper-respawn-count=~a~%"
            (limn/file-notify:helper-respawn-count))

    ;; Write IMMEDIATELY (matching W30 driver — no sleep between
    ;; auto-revert-mode and external write)
    (format t "~%--- external write 'new' (no sleep) ---~%")
    (with-open-file (s *path* :direction :output :if-exists :supersede)
      (write-string "new content here" s))
    (format t "  (sync...)~%")

    ;; Watch events for 5 seconds
    (dotimes (i 25)
      (sleep 0.2)
      (let* ((b (gethash bid limn/file::*bufs*))
             (c (limn/file::fbuf-content b)))
        (format t "  t=~,2f content=~s~%" (* i 0.2) c)
        (when (search "new" c)
          (format t "  ==> reverted!~%")
          (return))))

    (format t "~%final state:~%")
    (let* ((b (gethash bid limn/file::*bufs*))
           (c (limn/file::fbuf-content b)))
      (format t "  fbuf-content=~s~%" c)))

  ;; What did limn-w30dbg.log say?
  (format t "~%--- LIMN BINARY LOG ---~%")
  (with-open-file (s "/tmp/limn-w30dbg.log" :if-does-not-exist nil)
    (when s
      (let ((buf (make-string (file-length s))))
        (read-sequence buf s)
        (write-string buf))))

  (ignore-errors (delete-file *path*))
  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn")
                                      :search t :wait t)))

(sb-ext:exit :code 0)
