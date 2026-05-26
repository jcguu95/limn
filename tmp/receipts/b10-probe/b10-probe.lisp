;; B10 probe: open empty text buffer, send one xdotool key, check if it went in.
(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)
(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest args)
  (zerop (sb-ext:process-exit-code
           (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))

(defun wait-for-window (n &key (timeout 5))
  (let ((d (+ (get-universal-time) timeout)))
    (loop (when (zerop (sb-ext:process-exit-code
                         (sb-ext:run-program "xdotool" (list "search" "--name" n)
                                              :search t :wait t :output nil)))
            (return t))
          (when (> (get-universal-time) d) (return nil))
          (sleep 0.1))))

(defparameter *path* (format nil "/tmp/b10-~a.txt" (sb-posix:getpid)))
(with-open-file (s *path* :direction :output) (write-string "" s))

(let* ((sock (format nil "/tmp/limn-b10-~a" (sb-posix:getpid)))
       (limn-bin "/limn/sioyek/limn"))
  (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock)
                       :wait nil :search nil
                       :output "/tmp/limn-b10.log" :if-output-exists :supersede
                       :error :output)
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn" :timeout 5)
  (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate")
  (sleep 0.3)

  (let ((bid (limn/file:find-file *path*)))
    (format t "find-file returned: ~a~%" bid)
    (sleep 0.5)
    (xdotool "key" "--clearmodifiers" "x")
    (sleep 0.4)
    ;; Read buffer content via wire
    (let ((r (handler-case
                 (limn/bridge:response-data (limn:call "buffer/text" :|buffer-id| bid))
               (error (e) (format nil "err: ~a" e)))))
      (format t "buffer/text after x: ~s~%" r))
    (handler-case (limn/file:save-buffer bid) (error () nil))
    (sleep 0.3)
    (format t "disk content: ~s~%"
            (with-open-file (s *path* :if-does-not-exist nil)
              (when s (let ((b (make-string (file-length s))))
                        (read-sequence b s) b))))))
