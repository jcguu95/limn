;;;; B16 trace — pin down why pdf-highlight-selection doesn't write sidecar.

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

(format t "~%── B16 trace: pdf-highlight-selection → sidecar ──~%")

(let* ((sock (format nil "/tmp/limn-b16-~a" (sb-posix:getpid)))
       (proc (sb-ext:run-program "/limn/sioyek/limn"
                                  (list "--test-mode" "--socket" sock)
                                  :wait nil :search nil
                                  :output "/tmp/limn-b16.log" :if-output-exists :supersede
                                  :error :output)))
  (declare (ignore proc))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (wait-for-window "Limn")
  (sleep 0.5)

  ;; Load PDF
  (let* ((r (safe-call "bridge/engine-load" :|engine| "mupdf"
                        :|path| "/limn/sioyek/tutorial.pdf" :|win-id| "w1"))
         (bid (and (eq (car r) :ok) (getf (cdr r) :|buffer-id|))))
    (sleep 0.5)
    (format t "  buffer-id from engine-load = ~s~%" bid)

    ;; ── Step 1: Is *buffer-id-to-path* populated for this bid? ──
    (let ((tab limn/pdf-mode::*buffer-id-to-path*))
      (format t "  *buffer-id-to-path* contents: ")
      (maphash (lambda (k v) (format t "[~s → ~s] " k v)) tab)
      (format t "~%")
      (format t "  → gethash ~s: ~s~%" bid (and bid (gethash bid tab))))

    ;; ── Step 2: %current-pdf-path resolves what? ──
    (let ((p (limn/pdf-mode::%current-pdf-path)))
      (format t "  %current-pdf-path → ~s~%" p))

    ;; ── Step 3: %focused-buffer-id returns what? ──
    (let ((fbid (limn/pdf-mode::%focused-buffer-id)))
      (format t "  %focused-buffer-id → ~s~%" fbid))

    ;; ── Step 4: emulate %add-annotation save manually ──
    (format t "~%── manual save attempt ──~%")
    (safe-call "view/selection-set" :|win-id| "w1"
                :|begin| (list :|page| 0 :|x| 0.2 :|y| 0.2)
                :|end|   (list :|page| 0 :|x| 0.6 :|y| 0.3))
    (sleep 0.2)

    (let ((sel (limn/pdf-mode::%selection)))
      (format t "  %selection → ~s~%" sel)
      (when sel
        (let* ((path (or (limn/pdf-mode::%current-pdf-path) "/tmp/unknown.pdf"))
               (rects (getf sel :|rects|))
               (anno (limn/pdf-mode:make-pdf-annotation
                      :page 0 :rects rects :note "")))
          (format t "  path for save: ~s~%" path)
          (format t "  sidecar-path (path-key fallback): ~s~%"
                  (limn/pdf-mode:pdf-annotations-sidecar-path path))
          (format t "  sidecar-path (content-hash prefer): ~s~%"
                  (limn/pdf-mode:pdf-annotations-content-hash-sidecar-path path))
          (format t "  %effective-sidecar-path: ~s~%"
                  (limn/pdf-mode::%effective-sidecar-path path))
          (handler-case
              (let ((result (limn/pdf-mode:pdf-annotations-save path (list anno))))
                (format t "  save returned: ~s~%" result))
            (error (e)
              (format t "  save ERRORED: ~a~%" e)))
          ;; Check on disk
          (let ((sp (limn/pdf-mode:pdf-annotations-sidecar-path path)))
            (format t "  file exists at ~s: ~a~%" sp (probe-file sp))))))

    ;; ── Step 5: Now try via the actual pdf-highlight-selection wire path ──
    (format t "~%── pdf-highlight-selection (real path) ──~%")
    (xdotool "search" "--name" "Limn" "windowactivate")
    (sleep 0.2)
    (safe-call "view/selection-set" :|win-id| "w1"
                :|begin| (list :|page| 1 :|x| 0.2 :|y| 0.2)
                :|end|   (list :|page| 1 :|x| 0.6 :|y| 0.3))
    (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "h")
    (sleep 0.5)
    (let* ((path-from-cache (limn/pdf-mode::%current-pdf-path))
           (path (or path-from-cache "/tmp/unknown.pdf"))
           (sp (limn/pdf-mode:pdf-annotations-sidecar-path path)))
      (format t "  after h: path-from-cache=~s sidecar=~s exists=~a~%"
              path-from-cache sp (probe-file sp))))

  (ignore-errors (sb-ext:run-program "pkill" '("-9" "-f" "/limn/sioyek/limn") :search t :wait t)))

(sb-ext:exit :code 0)
