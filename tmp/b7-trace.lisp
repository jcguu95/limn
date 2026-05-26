;;;; B7 trace driver — replicate W22 setup but trace every step of the
;;;; dispatch chain to find where mode-buffer resolution breaks.

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir* (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defun xdotool (&rest args)
  (zerop (sb-ext:process-exit-code
           (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))))

(defun wait-for-window (n)
  (let ((d (+ (get-universal-time) 5)))
    (loop (when (zerop (sb-ext:process-exit-code
                         (sb-ext:run-program "xdotool" (list "search" "--name" n)
                                              :search t :wait t :output nil)))
            (return t))
          (when (> (get-universal-time) d) (return nil))
          (sleep 0.1))))

(defun safe-call (cmd &rest args)
  (handler-case (cons :ok (limn/bridge:response-data (apply #'limn:call cmd args)))
    (error (e) (cons :err e))))

(defparameter *out-dir* "/host-tmp/receipts/b7-trace/")
(ensure-directories-exist *out-dir*)

;; Write a clean init.lisp that defines a v binding (same as W22)
(ensure-directories-exist "/tmp/.limn/")
(with-open-file (s "/tmp/.limn/init.lisp" :direction :output :if-exists :supersede)
  (write-string ";;;; B7 trace init
(in-package :cl-user)
(defun my-v-canary ()
  (with-open-file (s \"/tmp/b7-canary\" :direction :output :if-exists :supersede)
    (write-string \"V_FIRED\" s)))
(limn/map-macro:map! :mode 'pdf-mode \"v\" 'my-v-canary)
" s))
(sb-posix:setenv "LIMN_INIT" "/tmp/.limn/init.lisp" 1)
(ignore-errors (delete-file "/tmp/b7-canary"))

(format t "~%── B7 trace: map! :mode 'pdf-mode \"v\" 'my-v-canary ──~%")

(let* ((sock (format nil "/tmp/limn-b7-~a" (sb-posix:getpid)))
       (limn-bin "/limn/sioyek/limn")
       (proc (sb-ext:run-program limn-bin (list "--test-mode" "--socket" sock)
                                  :wait nil :search nil
                                  :output "/tmp/limn-b7.log" :if-output-exists :supersede
                                  :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn")
  (sleep 0.5)
  (xdotool "search" "--name" "Limn" "windowactivate")
  (sleep 0.3)

  ;; Open PDF
  (let* ((r (safe-call "bridge/engine-load" :|engine| "mupdf"
                        :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1"))
         (bid (and (eq (car r) :ok) (getf (cdr r) :|buffer-id|))))
    (sleep 0.5)
    (format t "  engine-load → buffer-id = ~s~%" bid)

    ;; ── Inspect each layer of the dispatch chain ──
    (format t "~%── Inspecting dispatch chain layers ──~%")

    ;; (a) Does the v binding exist in pdf-mode's keymap?
    (let* ((pm (limn/mode:find-mode 'pdf-mode))
           (km (and pm (limn/mode:mode-keymap pm))))
      (format t "  (a) pdf-mode object: ~a~%" pm)
      (format t "      pdf-mode keymap: ~a~%" (and km t))
      (when km
        (let ((binding (limn/keys:lookup km "v")))
          (format t "      keymap 'v' lookup: ~a~%" binding))))

    ;; (b) Is there a mode-buffer registered for this buffer-id?
    (let* ((find-mb (find-symbol "FIND-MODE-BUFFER" :limn/runtime))
           (mb (and find-mb bid (funcall find-mb bid))))
      (format t "  (b) find-mode-buffer ~s → ~a~%" bid (and mb t)))

    ;; (c) mode-buffer-for-window "w1" — the dispatch entry point
    (let* ((mbfw (find-symbol "MODE-BUFFER-FOR-WINDOW" :limn/runtime))
           (mb (and mbfw (funcall mbfw "w1"))))
      (format t "  (c) mode-buffer-for-window \"w1\" → ~a~%" (and mb t))
      (when mb
        ;; What modes are active on it?
        (let ((mm (limn/mode:major-mode mb))
              (mn (limn/mode:minor-modes mb)))
          (format t "      major-mode: ~a~%" mm)
          (format t "      minor-modes: ~a~%" mn))
        ;; Lookup v on this mode-buffer
        (let ((lk (limn/mode:lookup-key mb "v")))
          (format t "      lookup-key 'v' on this mb: ~a~%" lk))))

    ;; (d) window-active-buffer "w1" — does it return the right bid?
    (let* ((wab (find-symbol "WINDOW-ACTIVE-BUFFER" :limn/runtime))
           (b (and wab (funcall wab "w1"))))
      (format t "  (d) window-active-buffer \"w1\" → ~s (expected ~s)~%" b bid))

    ;; (e) Simulate the actual dispatch:
    (format t "~%── Simulating dispatch via xdotool key v ──~%")
    (xdotool "key" "--clearmodifiers" "v")
    (sleep 0.5)
    (let ((c (with-open-file (s "/tmp/b7-canary" :if-does-not-exist nil)
               (when s (let ((b (make-string (file-length s))))
                         (read-sequence b s) b)))))
      (format t "  canary file content: ~s~%" c)
      (format t "  RESULT: ~a~%" (if c "PASS — v fired" "FAIL — v didn't fire"))))

  (let ((log (with-open-file (s "/tmp/limn-b7.log" :if-does-not-exist nil)
               (when s (let ((b (make-string (file-length s))))
                         (read-sequence b s) b)))))
    (when log
      (with-open-file (s (concatenate 'string *out-dir* "limn.log")
                          :direction :output :if-exists :supersede)
        (write-sequence log s))))
  (ignore-errors
    (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t)))

(sb-ext:exit :code 0)
