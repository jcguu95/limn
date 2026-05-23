;;;; Batch 26: v0.16 CJK 三件套 — OS-level e2e.
;;;;
;;;; Goal: verify under real Qt + Xvfb that:
;;;;   1. Codepoint-based cursor unit survives the whole xdotool → Qt
;;;;      KeyEvent → LimnInputFilter → text-engine cursor pipeline.
;;;;   2. ime-preedit / ime-commit events fire and dispatch into the
;;;;      minibuffer when injected via the test wire primitives.
;;;;
;;;; What's NOT tested here:
;;;;   - Real fcitx → Qt inputMethodEvent → events pipeline. Container
;;;;     fcitx setup is a heavyweight infrastructure piece; SPEC §12 v0.16
;;;;     mentions it but it can ship as v0.16.1 once the simpler injection
;;;;     primitives are proven. xdotool can type Unicode (including non-BMP
;;;;     emoji) directly via X11 — that exercises the Qt KeyEvent path
;;;;     end-to-end, which is what these tests rely on.

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-cjk"))

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

;;; ── primitive wrappers ────────────────────────────────────────────────

(defun mb-open  (prompt)
  (limn:call "minibuffer/open" :|prompt| prompt))
(defun mb-close ()
  (limn:call "minibuffer/close"))
(defun mb-get   ()
  (limn/bridge:response-data (limn:call "minibuffer/get")))
(defun mb-text  ()  (getf (mb-get) :|text|))
(defun mb-cursor () (getf (mb-get) :|cursor|))
(defun mb-set-text (s)
  (limn:call "minibuffer/set-text" :|text| s))

;;; ── session start ─────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-cjk-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-cjk.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── Ω1: xdotool type BMP CJK → cursor=char count ────────────────

    (format t "~%── Ω1: xdotool type '中文' into minibuffer ──~%")
    (mb-open "test: ")
    (mb-set-text "")
    (sleep 0.2)
    (xdotool "type" "--window" (write-to-string wid) "--delay" "30" "中文")
    (sleep 0.4)
    (let ((txt (mb-text)) (cur (mb-cursor)))
      (check (format nil "Ω1a — minibuffer text == '中文' (got ~s)" txt)
             (and (stringp txt) (string= txt "中文")))
      (check (format nil "Ω1b — cursor == 2 (codepoint count) (got ~a)" cur)
             (eql cur 2)))
    (mb-close)

;;; ── Ω2: xdotool type non-BMP emoji → cursor=1 codepoint ─────────
;;;
;;; RED until v0.16: pre-v0.16 cursor would be 2 (UTF-16 surrogate
;;; pair counts as two QString indices).

    (format t "~%── Ω2: xdotool type '🌟' → cursor=1 codepoint ──~%")
    (mb-open "test: ")
    (mb-set-text "")
    (sleep 0.2)
    (xdotool "type" "--window" (write-to-string wid) "--delay" "30" "🌟")
    (sleep 0.4)
    (let ((txt (mb-text)) (cur (mb-cursor)))
      (check (format nil "Ω2a — minibuffer text == '🌟' (got ~s)" txt)
             (and (stringp txt) (string= txt "🌟")))
      (check (format nil "Ω2b — cursor == 1 codepoint (got ~a; pre-v0.16 = 2)" cur)
             (eql cur 1)))
    (mb-close)

;;; ── Ω3: mixed BMP + non-BMP cursor arithmetic ──────────────────

    (format t "~%── Ω3: xdotool type 'a🌟b' → cursor=3 codepoints ──~%")
    (mb-open "test: ")
    (mb-set-text "")
    (sleep 0.2)
    (xdotool "type" "--window" (write-to-string wid) "--delay" "30" "a🌟b")
    (sleep 0.4)
    (let ((cur (mb-cursor)))
      (check (format nil "Ω3 — cursor == 3 codepoints (got ~a; pre-v0.16 = 4)" cur)
             (eql cur 3)))
    (mb-close)

;;; ── Ω4: test/inject-ime-commit → minibuffer text (dispatch wiring) ─
;;;
;;; ime-commit must flow through limn-dispatch and land in minibuffer
;;; text. Pre-v0.16 there is no ime-commit handler — minibuffer stays
;;; empty.

    (format t "~%── Ω4: ime-commit dispatches into minibuffer text ──~%")
    (mb-open "test: ")
    (mb-set-text "")
    (sleep 0.2)
    (limn:call "test/inject-ime-commit" :|text| "中文" :|frame-id| "f1")
    (sleep 0.3)
    (let ((txt (mb-text)) (cur (mb-cursor)))
      (check (format nil "Ω4a — minibuffer text == '中文' after ime-commit (got ~s)" txt)
             (and (stringp txt) (string= txt "中文")))
      (check (format nil "Ω4b — cursor == 2 codepoints (got ~a)" cur)
             (eql cur 2)))
    (mb-close)

;;; ── Ω5: test/inject-ime-preedit fires event observable by client ─
;;;
;;; v0.16 adds test/inject-ime-preedit primitive that pushes an
;;; ime-preedit event with composition :text. RED until primitive
;;; exists.

    (format t "~%── Ω5: test/inject-ime-preedit pushes ime-preedit event ──~%")
    (let ((r (limn:call "test/inject-ime-preedit"
                         :|text| "にほん" :|frame-id| "f1")))
      (check "Ω5a — test/inject-ime-preedit responds ok"
             (eq (limn/bridge:response-ok r) t))
      (sleep 0.2)
      ;; Drain events from the client side; look for ime-preedit
      (let* ((evs (limn/bridge:drain-events))
             (pre (find "ime-preedit" evs
                        :key (lambda (e) (getf e :|event|))
                        :test #'string=)))
        (check (format nil "Ω5b — ime-preedit event received (text=~s)"
                       (and pre (getf pre :|text|)))
               (and pre (string= "にほん" (getf pre :|text|))))))

;;; ── Ω6: ime-preedit + ime-commit typical flow (no double-commit) ──
;;;
;;; User composes "に" → "にほ" → "にほん" via preedits, then commits
;;; to "日本". The minibuffer should NOT contain "にほん" (preedit is
;;; in-progress display), only "日本" after commit.

    (format t "~%── Ω6: preedit doesn't pollute buffer, only commit lands ──~%")
    (mb-open "test: ")
    (mb-set-text "")
    (sleep 0.2)
    (limn:call "test/inject-ime-preedit" :|text| "に")
    (limn:call "test/inject-ime-preedit" :|text| "にほ")
    (limn:call "test/inject-ime-preedit" :|text| "にほん")
    (sleep 0.2)
    (let ((txt-mid (mb-text)))
      (check (format nil "Ω6a — minibuffer empty during preedit (got ~s)" txt-mid)
             (and (stringp txt-mid) (string= txt-mid ""))))
    (limn:call "test/inject-ime-commit" :|text| "日本")
    (sleep 0.3)
    (let ((txt-after (mb-text)))
      (check (format nil "Ω6b — minibuffer == '日本' after commit (got ~s)" txt-after)
             (and (stringp txt-after) (string= txt-after "日本"))))
    (mb-close)

    ;; ── summary ─────────────────────────────────────────────────
    (format t "~%~%── cjk-ime e2e results ──~%")
    (if (null *failures*)
        (format t "✓ ALL CHECKS PASSED~%")
        (progn
          (format t "✗ ~a FAILURE(s):~%" (length *failures*))
          (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
    (limn:stop)
    (sb-ext:process-kill proc 15)
    (sb-ext:process-wait proc)
    (sb-ext:exit :code (if *failures* 1 0))))
