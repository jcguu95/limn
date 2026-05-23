;;;; Batch 1.5: stronger tests — probe dimensions that batch 1 missed.
;;;;
;;;; batch 1 抓到 2 個 C++ bug、回看都在「沒列舉的 dimension」上：
;;;;   - event 時序（裸 modifier 中間態）
;;;;   - 兩條 code path post-condition 不一致
;;;;
;;;; 這個 driver 在 5 個新 dimension 上加 assertion：
;;;;
;;;;   α  cross-path equivalence    α2  path A vs path B 大小寫一致性
;;;;   β  negative assertion         β1  裸 modifier 不該推 key event
;;;;   γ  cross-modality             γ1  Ctrl+click   γ2  Shift+click
;;;;                                 γ3  Ctrl+drag    γ4  Ctrl+scroll
;;;;   δ  event lifecycle / timing  δ1  modifier 提早 release 中斷 prefix
;;;;   ε  roundtrip / invariant     ε1  bind+inject+where-is sweep
;;;;
;;;; γ 系列預期必紅（讀 limn_input.cpp 可見 mouse-click event 沒插 mods
;;;; 欄位、其他 button event 同理）。β/α/δ/ε 應綠（守住剛修的 invariant
;;;; 或基本 sanity）。

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-stronger"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details)
    (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

;; Event capture helpers — set by hooks installed once at session start.
(defparameter *captured-key-events*    nil)
(defparameter *captured-mouse-events*  nil)
(defparameter *captured-drag-events*   nil)
(defparameter *captured-scroll-events* nil)

(defun drain-captures ()
  (setf *captured-key-events*    nil
        *captured-mouse-events*  nil
        *captured-drag-events*   nil
        *captured-scroll-events* nil)
  (sleep 0.05))

(defun reset-x-state (wid)
  "Force-release any stuck modifier between tests. Without this,
   modifier state leaks across xdotool calls in unpredictable ways."
  (declare (ignorable wid))
  (handler-case (xdotool "keyup" "ctrl") (error () nil))
  (handler-case (xdotool "keyup" "alt") (error () nil))
  (handler-case (xdotool "keyup" "shift") (error () nil))
  (handler-case (xdotool "keyup" "Meta_L") (error () nil))
  (sleep 0.1))

(let* ((sock (format nil "/tmp/limn-e2e-stronger-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-stronger.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    ;; openbox manages focus; no manual windowsize/move/activate.
    ;; Earlier batch-os-click NEEDED them but that's a mouse-click
    ;; test — for key inject openbox + sleep is enough.
    (sleep 0.3)

    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

    ;; Register hooks. NOTE on push vs setf: hooks fire in the pump
    ;; thread; mutating a global plist via push from the hook works
    ;; in SBCL but we keep the most-recent semantic via setf-of-list
    ;; for clarity and to match batch-os-mods that's known to work.
    (limn:on-event "key"
                   (lambda (ev)
                     (setf *captured-key-events*
                           (cons ev *captured-key-events*))))
    (limn:on-event "mouse-click"
                   (lambda (ev)
                     (setf *captured-mouse-events*
                           (cons ev *captured-mouse-events*))))
    (limn:on-event "mouse-drag"
                   (lambda (ev)
                     (setf *captured-drag-events*
                           (cons ev *captured-drag-events*))))
    (limn:on-event "scroll"
                   (lambda (ev)
                     (setf *captured-scroll-events*
                           (cons ev *captured-scroll-events*))))
    (sleep 0.2)
    (format t "  hooks installed for: key, mouse-click, mouse-drag, scroll~%")

;;; Reorder rationale: simple tests first (α2 / ε1 / β1 / δ1) so we
;;; verify baseline event flow works before stressing it with γ
;;; modifier+pointer combos. State reset between every test.

;;; ── α2: case + mods alignment matrix ──────────────────────────────

    ;; SANITY: confirm the event hook actually captures anything at all.
    (reset-x-state wid)
    (format t "~%── sanity: bind key hook, inject 'q', see if captured ──~%")
    (drain-captures)
    (xdotool "key" "--clearmodifiers" "q")
    (sleep 0.3)
    (limn:pump)
    (sleep 0.1)
    (format t "  captured key events: ~s~%" *captured-key-events*)
    ;; Also: query bridge log file directly to see if Limn even saw the q.
    (let ((p (sb-ext:run-program "tail" '("-5" "/tmp/limn-os-stronger.log")
                                  :search t :wait t :output t)))
      (declare (ignore p)))

    (reset-x-state wid)
    (format t "~%── α2: case + mods alignment matrix ──~%")
    (labels ((expect-event (sequence-args expected-key expected-mods label)
               (reset-x-state wid)
               (drain-captures)
               (apply #'xdotool "key" "--clearmodifiers" sequence-args)
               (sleep 0.3)
               (let* ((ev   (first *captured-key-events*))
                      (key  (and ev (getf ev :|key|)))
                      (mods (and ev (getf ev :|mods|))))
                 (check (format nil "α2 ~a: key=~s" label expected-key)
                        (equal key expected-key)
                        (format nil "got key=~s ev=~s" key ev))
                 (check (format nil "α2 ~a: mods=~s" label expected-mods)
                        (and (listp mods)
                             (every (lambda (m) (find m mods :test #'string=))
                                    expected-mods)
                             (every (lambda (m) (find m expected-mods :test #'string=))
                                    mods))
                        (format nil "got mods=~s" mods)))))
      (expect-event '("a")               "a" '()              "a no-mod")
      (expect-event '("shift+a")         "A" '()              "A shift-only")
      (expect-event '("ctrl+a")          "a" '("ctrl")        "a ctrl")
      (expect-event '("ctrl+shift+a")    "A" '("ctrl")        "A ctrl+shift")
      (expect-event '("ctrl+alt+a")      "a" '("ctrl" "alt")  "a ctrl+alt")
      (expect-event '("ctrl+alt+shift+a") "A" '("ctrl" "alt") "A ctrl+alt+shift"))

;;; ── ε1: bind + inject + where-is sweep ──────────────────────────────

    (reset-x-state wid)
    (format t "~%── ε1: bind + inject + where-is sweep ──~%")
    (let ((letters '("a" "b" "c" "d" "e"))
          (results (make-hash-table :test 'equal)))
      (dolist (l letters)
        (let* ((sym (intern (format nil "EPS1-CMD-~a" (string-upcase l)))))
          (eval `(let ((target-key ,l)
                       (target-table ,results))
                   (limn/cmd:defcommand ,sym ()
                     (lambda ()
                       (setf (gethash target-key target-table) t)))))
          (limn:bind (format nil "C-~a" l) sym)))
      (dolist (l letters)
        (reset-x-state wid)
        (xdotool "key" "--clearmodifiers" (format nil "ctrl+~a" l))
        (sleep 0.2))
      (sleep 0.4)
      (let ((missing (remove-if (lambda (l) (gethash l results)) letters)))
        (check "ε1 — every (C-letter → cmd) bound fires when injected"
               (null missing)
               (format nil "did not fire for: ~s; results=~s"
                       missing
                       (loop for l in letters collect (cons l (gethash l results))))))
      ;; introspection roundtrip
      (let ((found-pairs
              (loop for l in letters
                    for sym = (intern (format nil "EPS1-CMD-~a" (string-upcase l)))
                    for keys = (limn/introspect:where-is-command sym)
                    when (find (format nil "C-~a" l) keys :test #'string=)
                      collect l)))
        (check "ε1 — where-is-command sees every binding"
               (equal (sort (copy-list found-pairs) #'string<)
                      (sort (copy-list letters) #'string<))
               (format nil "found-pairs=~s" found-pairs))))

;;; ── β1: bare modifier should NOT emit a key event ────────────────────

    (reset-x-state wid)
    (format t "~%── β1: bare Ctrl press → no key event ──~%")
    (drain-captures)
    (xdotool "keydown" "ctrl")
    (sleep 0.2)
    (xdotool "keyup" "ctrl")
    (sleep 0.3)
    (check "β1 — bare Ctrl down/up: no key events"
           (null *captured-key-events*)
           (format nil "got ~a events: ~s"
                   (length *captured-key-events*)
                   *captured-key-events*))

;;; ── δ1: modifier 提早 release 中斷 prefix ────────────────────────────

    (reset-x-state wid)
    (format t "~%── δ1: ctrl-down, x, ctrl-up, f → not C-x C-f ──~%")
    (let ((fired 0))
      (limn/cmd:defcommand stronger-cxcf-test ()
        (lambda () (incf fired)))
      (limn:bind "C-x C-f" 'stronger-cxcf-test)
      (xdotool "key" "--clearmodifiers" "ctrl+x")
      (sleep 0.2)
      (xdotool "key" "--clearmodifiers" "f")
      (sleep 0.3)
      (check "δ1 — plain f after C-x does NOT trigger C-x C-f"
             (zerop fired)
             (format nil "find-file-test fired ~a times" fired)))

;;; ── γ1: Ctrl + click should carry mods=["ctrl"] ─────────────────────

    (reset-x-state wid)
    (format t "~%── γ1: Ctrl + click → mouse-click w/ mods=[ctrl] ──~%")
    (drain-captures)
    (xdotool "keydown" "ctrl")
    (sleep 0.1)
    (xdotool "mousemove" "600" "400")
    (xdotool "click" "1")
    (sleep 0.1)
    (xdotool "keyup" "ctrl")
    (sleep 0.3)
    (let ((ev (first *captured-mouse-events*)))
      (check "γ1 — mouse-click event arrived"
             ev (format nil "events=~s" *captured-mouse-events*))
      (when ev
        (let ((mods (getf ev :|mods|)))
          (check "γ1 — mouse-click event has :mods field"
                 (not (null mods))
                 (format nil "no :mods field; got ~s" ev))
          (check "γ1 — mods contains \"ctrl\""
                 (and (listp mods) (find "ctrl" mods :test #'string=))
                 (format nil "got mods=~s" mods)))))

;;; ── γ2: Shift + click ───────────────────────────────────────────────

    (reset-x-state wid)
    (format t "~%── γ2: Shift + click → mouse-click w/ mods=[shift] ──~%")
    (drain-captures)
    (xdotool "keydown" "shift")
    (sleep 0.1)
    (xdotool "click" "1")
    (sleep 0.1)
    (xdotool "keyup" "shift")
    (sleep 0.3)
    (let ((ev (first *captured-mouse-events*)))
      (check "γ2 — mouse-click event arrived" ev)
      (when ev
        (let ((mods (getf ev :|mods|)))
          (check "γ2 — mods contains \"shift\""
                 (and (listp mods) (find "shift" mods :test #'string=))
                 (format nil "got mods=~s" mods)))))

;;; ── γ3: Ctrl + drag ─────────────────────────────────────────────────

    (reset-x-state wid)
    (format t "~%── γ3: Ctrl + drag → mouse-drag w/ mods=[ctrl] ──~%")
    (drain-captures)
    (xdotool "keydown" "ctrl")
    (sleep 0.1)
    (xdotool "mousemove" "400" "300")
    (xdotool "mousedown" "1")
    (xdotool "mousemove" "700" "500")
    (xdotool "mouseup" "1")
    (sleep 0.1)
    (xdotool "keyup" "ctrl")
    (sleep 0.3)
    ;; EXPECTED-FAIL γ3: 真實 OS drag 沒接到 mouse-drag event wire——
    ;; 目前 mouse-drag 只由 test/inject-mouse-drag 模擬發送、實際
    ;; QEvent::MouseMove + 按鈕 held → wire event 那條路沒做。屬於
    ;; feature gap、推 v0.11+。informational only, 不算進 *failures*。
    (let ((ev (first *captured-drag-events*)))
      (if (null ev)
          (format t "  ⊘ γ3 (EXPECTED-FAIL) — no mouse-drag event; ~%    drag wire from OS path not implemented yet (v0.11+)~%")
          (let ((mods (getf ev :|mods|)))
            (check "γ3 — drag event has mods=[ctrl] (unexpected: drag wire IS working!)"
                   (and (listp mods) (find "ctrl" mods :test #'string=))
                   (format nil "got mods=~s" mods)))))

;;; ── γ4: Ctrl + scroll ───────────────────────────────────────────────

    (reset-x-state wid)
    (format t "~%── γ4: Ctrl + scroll → scroll w/ mods=[ctrl] ──~%")
    (drain-captures)
    (xdotool "keydown" "ctrl")
    (sleep 0.1)
    (xdotool "click" "4")        ; scroll up = button 4
    (sleep 0.1)
    (xdotool "keyup" "ctrl")
    (sleep 0.3)
    (let ((ev (first *captured-scroll-events*)))
      (check "γ4 — scroll event arrived" ev)
      (when ev
        (let ((mods (getf ev :|mods|)))
          (check "γ4 — scroll event has mods=[ctrl]"
                 (and (listp mods) (find "ctrl" mods :test #'string=))
                 (format nil "got mods=~s" mods)))))

;;; ── final verdict ───────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — all stronger tests green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-stronger")
        (rename-file "/tmp/.limn/init.lisp.stash-stronger" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
