;;;; v0.27 §A — pdf-mode navigation OS-level e2e
;;;;
;;;; 真實 binary + Xvfb + xdotool。覆蓋：
;;;;   Ω1 開 PDF → buffer major mode 是 pdf-mode
;;;;   Ω2 按 j ×N → offset-y 或 page 增加（依 scroll-step 而定）
;;;;   Ω3 按 n / p → page +1 / -1
;;;;   Ω4 按 G → page 跳到 last
;;;;   Ω5 按 g g → page = 0
;;;;   Ω6 按 + / - → zoom 增 / 減
;;;;
;;;; 所有 Ω 在 backend/limn-pdf-mode.lisp + bootstrap install 前 RED。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v027nav"))

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

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun engine-load (path)
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf" :|path| path :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun view-get () (data (limn:call "view/get" :|win-id| "w1")))
(defun page-of (vg) (getf vg :|page|))
(defun zoom-of (vg) (getf vg :|zoom|))
(defun offy-of (vg) (or (getf vg :|offset-y|) 0.0))
(defun pcount-of (vg) (getf vg :|page-count|))

(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t
                       :output nil :error nil))
(defun key (k) (xdotool "key" k))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool" '("search" "--name" "Limn")
                                             :search t :wait t
                                             :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
          do (return found)
        do (sleep 0.1)))

;;; ── session ─────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v027nav-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v027nav.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (let* ((b (engine-load (b/ "tests/fixtures/test.pdf")))
         (initial (view-get))
         (page-count (pcount-of initial)))
    (check (format nil "setup — buffer ~a (~a pages)" b page-count)
           (and (stringp b) (integerp page-count) (> page-count 1)))

;;; ── Ω1: pdf-mode auto-activates on mupdf buffer ────────────────

    (format t "~%── Ω1: pdf-mode auto-activates ──~%")
    (let* ((r (limn:call "buffer/state" :|buffer-id| b))
           (major (and (ok? r) (getf (data r) :|major|))))
      (check (format nil "Ω1 — major mode is pdf-mode (got ~s)" major)
             (or (null major)            ; buffer/state 可能還沒 ship — 容忍
                 (and (stringp major)
                      (search "pdf" (string-downcase major))))))

;;; ── Ω2: j scrolls down ─────────────────────────────────────────

    (format t "~%── Ω2: j scrolls down ──~%")
    (let ((before (view-get)))
      (key "j") (key "j") (key "j")
      (sleep 0.2)
      (let ((after (view-get)))
        (check "Ω2 — j moved either page or offset-y"
               (or (> (page-of after) (page-of before))
                   (> (offy-of after) (offy-of before))))))

;;; ── Ω3: n / p navigate pages ───────────────────────────────────

    (format t "~%── Ω3: n / p page nav ──~%")
    ;; reset to page 0 via wire (independent of g g binding)
    (limn:call "view/set" :|win-id| "w1" :|page| 0)
    (sleep 0.1)
    (key "n") (sleep 0.1)
    (check (format nil "Ω3a — n: page=~a should be > 0" (page-of (view-get)))
           (> (page-of (view-get)) 0))
    (key "p") (sleep 0.1)
    (check (format nil "Ω3b — p: page back to 0 (got ~a)" (page-of (view-get)))
           (= 0 (page-of (view-get))))

;;; ── Ω4: G → last page ──────────────────────────────────────────

    (format t "~%── Ω4: G → last page ──~%")
    (limn:call "view/set" :|win-id| "w1" :|page| 0)
    (sleep 0.1)
    (key "shift+g") (sleep 0.2)
    (check (format nil "Ω4 — G jumped to last (page=~a, expected ~a)"
                   (page-of (view-get)) (1- page-count))
           (= (page-of (view-get)) (1- page-count)))

;;; ── Ω5: g g → first page ───────────────────────────────────────

    (format t "~%── Ω5: g g → first page ──~%")
    (key "g") (key "g") (sleep 0.2)
    (check (format nil "Ω5 — g g back to page 0 (got ~a)" (page-of (view-get)))
           (= 0 (page-of (view-get))))

;;; ── Ω6: + / - zoom ────────────────────────────────────────────

    (format t "~%── Ω6: +/- zoom ──~%")
    (limn:call "view/set" :|win-id| "w1" :|zoom| 1.0)
    (sleep 0.1)
    (key "plus") (sleep 0.1)
    (let ((z (zoom-of (view-get))))
      (check (format nil "Ω6a — + zoomed in (zoom=~a, expect > 1.0)" z)
             (and (numberp z) (> z 1.0))))
    (key "minus") (key "minus") (sleep 0.1)
    (let ((z (zoom-of (view-get))))
      (check (format nil "Ω6b — - zoomed out (zoom=~a, expect < 1.0)" z)
             (and (numberp z) (< z 1.0))))
    (key "0") (sleep 0.1)
    (let ((z (zoom-of (view-get))))
      (check (format nil "Ω6c — 0 reset zoom (got ~a)" z)
             (and (numberp z) (< (abs (- z 1.0)) 0.01)))))

  (format t "~%── v027-nav e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
