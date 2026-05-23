;;;; Batch 2: 滑鼠完整 sweep — B1/B2/B3/B6 系統釘住每種 mouse 行為。
;;;;
;;;; batch 1.5/1.6/1.7 已蓋過：
;;;;   - 1.5 γ1: ctrl+click → mods=[ctrl]
;;;;   - 1.6 λ1: button enum 4-9 preservation
;;;;   - 1.7-fix: drag wire (mouse-drag event from OS path)
;;;;
;;;; 這個 driver 是「驗收」性質、釘住每 button / direction / count 的
;;;; SPEC 對應：
;;;;
;;;;   B1  right (button 3) + middle (button 2) click → button id 正確
;;;;   B2  double click → 兩個 mouse-click event 各帶 button
;;;;   B3  scroll up (4) / down (5) → dy 方向正確
;;;;   B6  drag from A→B → mouse-drag event 帶 dx/dy

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defun xdotool (&rest args)
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "xdotool ~{~a~^ ~} exited non-zero" args))))

(defun xdotool-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "xdotool" args :search t
                                  :wait t :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "xdotool ~{~a~^ ~} exited non-zero" args)))))

(defun wait-for-window-by-name (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((s (string-trim '(#\Space #\Newline #\Tab)
                             (handler-case
                                 (xdotool-stdout "search" "--name" name)
                               (error () "")))))
        (unless (zerop (length s))
          (return (parse-integer
                   (subseq s 0 (or (position #\Newline s) (length s)))))))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-mouse"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defparameter *click-events* nil)
(defparameter *scroll-events* nil)
(defparameter *drag-events*   nil)

(defun drain ()
  (setf *click-events* nil
        *scroll-events* nil
        *drag-events* nil)
  (sleep 0.05))

(let* ((sock (format nil "/tmp/limn-e2e-mouse-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-mouse.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

    (limn:on-event "mouse-click"
                   (lambda (ev) (push ev *click-events*)))
    (limn:on-event "scroll"
                   (lambda (ev) (push ev *scroll-events*)))
    (limn:on-event "mouse-drag"
                   (lambda (ev) (push ev *drag-events*)))
    (sleep 0.2)

;;; ── B1: right click / middle click ─────────────────────────────────

    (format t "~%── B1: right click (button 3) ──~%")
    (drain)
    (xdotool "mousemove" "600" "400")
    (xdotool "click" "3")
    (sleep 0.3)
    (let* ((ev (first *click-events*))
           (button (and ev (getf ev :|button|))))
      (check "B1 right — event arrived" ev)
      (check (format nil "B1 right — button=3 (got ~a)" button)
             (eql button 3)))

    (format t "~%── B1: middle click (button 2) ──~%")
    (drain)
    (xdotool "click" "2")
    (sleep 0.3)
    (let* ((ev (first *click-events*))
           (button (and ev (getf ev :|button|))))
      (check "B1 middle — event arrived" ev)
      (check (format nil "B1 middle — button=2 (got ~a)" button)
             (eql button 2)))

;;; ── B2: double click ───────────────────────────────────────────────
;;;
;;; xdotool click --repeat 2 sends two button presses in quick
;;; succession. Each emits its own mouse-click event (we don't
;;; coalesce into mouse-double-click — SPEC v0.6 doesn't define one).

    (format t "~%── B2: double click → two mouse-click events ──~%")
    (drain)
    (xdotool "click" "--repeat" "2" "--delay" "80" "1")
    (sleep 0.4)
    (let ((n (length *click-events*)))
      (check (format nil "B2 — two mouse-click events arrived (got ~a)" n)
             (= n 2)))

;;; ── B3: scroll up / down ───────────────────────────────────────────

    (format t "~%── B3: scroll up (button 4) ──~%")
    (drain)
    (xdotool "click" "4")
    (sleep 0.3)
    (let* ((ev (first *scroll-events*))
           (dy (and ev (getf ev :|dy|))))
      (check "B3 up — scroll event arrived" ev)
      (check (format nil "B3 up — dy positive (got ~a)" dy)
             (and (numberp dy) (> dy 0))
             "scroll up should yield positive dy"))

    (format t "~%── B3: scroll down (button 5) ──~%")
    (drain)
    (xdotool "click" "5")
    (sleep 0.3)
    (let* ((ev (first *scroll-events*))
           (dy (and ev (getf ev :|dy|))))
      (check "B3 down — scroll event arrived" ev)
      (check (format nil "B3 down — dy negative (got ~a)" dy)
             (and (numberp dy) (< dy 0))
             "scroll down should yield negative dy"))

;;; ── B6: drag from A to B ───────────────────────────────────────────
;;;
;;; mousedown + mousemove + mouseup; mouse-drag event should fire on
;;; the move with the anchor (A) coords and delta (B−A).

    (format t "~%── B6: drag (300,300) → (600,500) ──~%")
    (drain)
    (xdotool "mousemove" "300" "300")
    (xdotool "mousedown" "1")
    (xdotool "mousemove" "600" "500")
    (xdotool "mouseup" "1")
    (sleep 0.3)
    (let ((ev (first *drag-events*)))
      (check "B6 — mouse-drag event arrived" ev)
      (when ev
        (let ((dx (getf ev :|dx|))
              (dy (getf ev :|dy|))
              (button (getf ev :|button|)))
          (check (format nil "B6 — button=1 (got ~a)" button)
                 (eql button 1))
          ;; dx/dy 可能是 page-norm 小數或 pixel 整數、看 anchor 是不是
          ;; 在 PDF 頁面內。只 assert 非零 + 同號方向（dx > 0、dy > 0）。
          (check (format nil "B6 — dx > 0 (got ~a)" dx)
                 (and (numberp dx) (> dx 0)))
          (check (format nil "B6 — dy > 0 (got ~a)" dy)
                 (and (numberp dy) (> dy 0))))))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 2 mouse sweep all green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-mouse")
        (rename-file "/tmp/.limn/init.lisp.stash-mouse" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
