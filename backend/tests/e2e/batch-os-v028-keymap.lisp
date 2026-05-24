;;;; v0.28 — keymap (text-nav + map! + which-key) OS-tier via Xvfb
;;;;
;;;; Single file covering all three §A/§B/§C subsystems through real
;;;; xdotool keypresses, exercising the full pipeline:
;;;;   xdotool → Qt key event → C++ bridge → "key" event → background
;;;;   pump → Lisp dispatch → keymap lookup → bound function → text-nav.
;;;;
;;;; Buffer layout for navigation tests (offsets are codepoints):
;;;;
;;;;     "abcdef\nXY\n1234567\n"
;;;;      0123456 789 01234567
;;;;                1111111
;;;;
;;;;   Line 1 "abcdef"  (6 chars), \n at 6
;;;;   Line 2 "XY"      (2 chars), \n at 9
;;;;   Line 3 "1234567" (7 chars), \n at 17
;;;;
;;;; Ω1   C-n from offset 3 → cursor at 9 (EOL of line 2, col 3 clamped)
;;;; Ω2   C-n again → cursor at 13 (col 3 in line 3, *goal-column* preserved)
;;;; Ω3   C-p × 2 → cursor back at 3
;;;; Ω4   C-a → cursor at 0 (BOL of line 1)
;;;; Ω5   C-e → cursor at 6 (EOL of line 1)
;;;; Ω6   M-< → cursor at 0 (beginning of buffer)
;;;; Ω7   M-> → cursor at 18 (end of buffer)
;;;; Ω8   M-f from 0 in "alpha beta\n" → cursor at 5 (end of "alpha")
;;;; Ω9   M-b from 5 → cursor at 0 (back to "alpha" start)
;;;; Ω10  C-k from BOL → kill-ring head = line text + buffer line gone
;;;;        (cross-module v0.24 kill ↔ v0.28 text-nav)
;;;; Ω11  map! :prefix "C-x" "g" → C-x g triggers bound command
;;;; Ω12  which-key: C-x prefix → *echo-log* populated
;;;; Ω13  which-key-mode off → no further echo on prefix

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v028km"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-kill.lisp" "limn-text-nav.lisp"
             "limn-map-macro.lisp" "limn-which-key.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun buf-text (bid)
  (let ((r (limn:call "buffer/text" :|buffer-id| bid)))
    (and (ok? r) (getf (data r) :|text|))))

(defun buf-cursor (bid)
  (or (getf (data (limn:call "buffer/cursor-get" :|buffer-id| bid))
            :|offset|)
      0))

(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t :output nil :error nil))

(defun key (k) (xdotool "key" k) (sleep 0.15))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool"
                                             '("search" "--name" "Limn")
                                             :search t :wait t
                                             :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
          do (return found)
        do (sleep 0.1)))

(format t "~%=== batch-os-v028-keymap ===~%")

;;; Held by closures inside command bindings.  Mutated when we switch
;;; between test buffers (text-nav corpus vs forward-word corpus).
(defparameter *test-bid* nil)

;;; Side-effect counters touched by bound commands.
(defparameter *cx-g-fired* 0)
(defparameter *echo-log*   nil)

;;; Command thunks.  All take (ev) per limn dispatch contract.
(defun v028-cn  (ev) (declare (ignore ev)) (limn/text-nav:next-line *test-bid*))
(defun v028-cp  (ev) (declare (ignore ev)) (limn/text-nav:previous-line *test-bid*))
(defun v028-ca  (ev) (declare (ignore ev)) (limn/text-nav:move-beginning-of-line *test-bid*))
(defun v028-ce  (ev) (declare (ignore ev)) (limn/text-nav:move-end-of-line *test-bid*))
(defun v028-mlt (ev) (declare (ignore ev)) (limn/text-nav:beginning-of-buffer *test-bid*))
(defun v028-mgt (ev) (declare (ignore ev)) (limn/text-nav:end-of-buffer *test-bid*))
(defun v028-mf  (ev) (declare (ignore ev)) (limn/text-nav:forward-word *test-bid*))
(defun v028-mb  (ev) (declare (ignore ev)) (limn/text-nav:backward-word *test-bid*))
(defun v028-ck  (ev) (declare (ignore ev)) (limn/text-nav:kill-line *test-bid*))
(defun v028-cxg (ev) (declare (ignore ev)) (incf *cx-g-fired*))

(let* ((sock     (format nil "/tmp/limn-e2e-v028km-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v028km.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  ;;; ── primary nav corpus ──────────────────────────────────────────────
  (let* ((r   (limn:call "bridge/engine-load"
                          :|engine| "text" :|path| "" :|win-id| "w1"))
         (bid (and (ok? r) (getf (data r) :|buffer-id|))))
    (check "engine-load text buffer" (and bid (stringp bid)))

    (when bid
      (setf *test-bid* bid)

      ;;; ── wire text-nav vtable ─────────────────────────────────────────
      (setf limn/text-nav:*buffer-text-fn*
            (lambda (b) (or (buf-text b) "")))
      (setf limn/text-nav:*buffer-cursor-fn*
            (lambda (b) (buf-cursor b)))
      (setf limn/text-nav:*buffer-set-cursor-fn*
            (lambda (b off)
              (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| off)))
      (setf limn/text-nav:*buffer-insert-fn*
            (lambda (b off str)
              (limn:call "buffer/insert" :|buffer-id| b :|at| off :|text| str)))
      (setf limn/text-nav:*buffer-delete-fn*
            (lambda (b from to)
              (limn:call "buffer/delete" :|buffer-id| b :|from| from :|to| to)))
      ;; Cross-module wire: kill-line should push into kill-ring.
      (setf limn/text-nav:*kill-new-fn* #'limn/kill:kill-new)
      (setf limn/kill:*kill-ring* nil)

      ;;; ── bindings via map! ────────────────────────────────────────────
      ;; §B coverage: map! handles a flat block of pairs into the global keymap.
      (limn/map-macro:map! :map limn:*global-keymap*
        "C-n" #'v028-cn
        "C-p" #'v028-cp
        "C-a" #'v028-ca
        "C-e" #'v028-ce
        "C-k" #'v028-ck
        "M-<" #'v028-mlt
        "M->" #'v028-mgt
        "M-f" #'v028-mf
        "M-b" #'v028-mb)

      ;;; ── §B cont.: map! :prefix variant for Ω11 ──────────────────────
      (limn/map-macro:map! :map limn:*global-keymap* :prefix "C-x"
        "g" #'v028-cxg)

      ;;; ── Ω1 + Ω2: C-n × 2 with goal-column ────────────────────────────
      (limn:call "buffer/insert" :|buffer-id| bid :|at| 0
                  :|text| "abcdef
XY
1234567
")
      (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 3)
      (setf limn/text-nav:*goal-column* nil)   ; reset

      (format t "~%── Ω1+Ω2: C-n × 2 with goal-column ──~%")
      (key "ctrl+n")
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω1 C-n from 3 → cursor 9 (got ~a)" c)
               (= c 9)))
      (key "ctrl+n")
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω2 C-n again → cursor 13 (goal-column 3 preserved; got ~a)" c)
               (= c 13)))

      ;;; ── Ω3: C-p × 2 ──────────────────────────────────────────────────
      (format t "~%── Ω3: C-p × 2 ──~%")
      (key "ctrl+p") (key "ctrl+p")
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω3 C-p × 2 → cursor back at 3 (got ~a)" c)
               (= c 3)))

      ;;; ── Ω4 + Ω5: C-a / C-e ───────────────────────────────────────────
      (format t "~%── Ω4+Ω5: C-a / C-e ──~%")
      (key "ctrl+a")
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω4 C-a → BOL = 0 (got ~a)" c) (= c 0)))
      (key "ctrl+e")
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω5 C-e → EOL of line 1 = 6 (got ~a)" c) (= c 6)))

      ;;; ── Ω6 + Ω7: M-< / M-> ───────────────────────────────────────────
      (format t "~%── Ω6+Ω7: M-< / M-> ──~%")
      (key "alt+less")
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω6 M-< → 0 (got ~a)" c) (= c 0)))
      (key "alt+greater")
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω7 M-> → end of buffer = 18 (got ~a)" c) (= c 18)))

      ;;; ── Ω8 + Ω9: M-f / M-b ───────────────────────────────────────────
      ;; Use a dedicated corpus on the same buffer: clear and refill.
      (let* ((cur (or (buf-text bid) "")))
        (when (> (length cur) 0)
          (limn:call "buffer/delete" :|buffer-id| bid
                      :|from| 0 :|to| (length cur))))
      (limn:call "buffer/insert" :|buffer-id| bid :|at| 0 :|text| "alpha beta")
      (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
      (setf limn/text-nav:*goal-column* nil)

      (format t "~%── Ω8+Ω9: M-f / M-b ──~%")
      (key "alt+f")
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω8 M-f from 0 → end of \"alpha\" = 5 (got ~a)" c)
               (= c 5)))
      (key "alt+b")
      (let ((c (buf-cursor bid)))
        (check (format nil "Ω9 M-b from 5 → start of \"alpha\" = 0 (got ~a)" c)
               (= c 0)))

      ;;; ── Ω10: C-k cross-module (text-nav → kill-ring) ─────────────────
      ;; Refill with a line we'll kill.
      (let* ((cur (or (buf-text bid) "")))
        (when (> (length cur) 0)
          (limn:call "buffer/delete" :|buffer-id| bid
                      :|from| 0 :|to| (length cur))))
      (limn:call "buffer/insert" :|buffer-id| bid :|at| 0
                  :|text| "kill me please")
      (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
      (setf limn/kill:*kill-ring* nil)

      (format t "~%── Ω10: C-k cross-module ──~%")
      (key "ctrl+k")
      (let ((txt  (buf-text bid))
            (ring limn/kill:*kill-ring*))
        (check (format nil "Ω10a buffer line gone after C-k (got ~s)" txt)
               (or (null txt) (zerop (length txt))))
        (check (format nil "Ω10b kill-ring head = killed line (ring=~s)" ring)
               (and (consp ring) (equal (car ring) "kill me please"))))

      ;;; ── Ω11: map! :prefix → C-x g ────────────────────────────────────
      (format t "~%── Ω11: map! :prefix (C-x g) ──~%")
      (setf *cx-g-fired* 0)
      (key "ctrl+x")
      (key "g")
      (check (format nil "Ω11 C-x g binding fired (~a times)" *cx-g-fired*)
             (= *cx-g-fired* 1))

      ;;; ── Ω12 + Ω13: which-key ─────────────────────────────────────────
      ;; Install which-key with synchronous timer-fn and capturing echo-fn.
      (setf limn/which-key:*timer-fn*
            (lambda (delay cb) (declare (ignore delay)) (funcall cb)))
      (setf limn/which-key:*echo-fn*
            (lambda (str) (push str *echo-log*)))
      (limn/which-key:which-key-mode)
      (limn/which-key:install)

      (format t "~%── Ω12+Ω13: which-key ──~%")
      (setf *echo-log* nil)
      (key "ctrl+x")   ; triggers prefix → event/key-prefix-changed → echo
      (sleep 0.2)
      (check (format nil "Ω12 echo-fn called on C-x prefix (log=~s)" *echo-log*)
             (consp *echo-log*))

      ;; Cancel the pending prefix sequence so the next test starts clean.
      (key "Escape")
      (sleep 0.1)

      ;; Now flip mode off and try again.
      (setf limn/which-key:*which-key-mode* nil)
      (setf *echo-log* nil)
      (key "ctrl+x")
      (sleep 0.2)
      (check (format nil "Ω13 mode off → no echo (log=~s)" *echo-log*)
             (null *echo-log*))
      (key "Escape")))

  (ignore-errors (limn:stop))
  (sleep 0.1)
  (handler-case (sb-ext:process-kill proc 15) (error () nil))
  (handler-case (sb-ext:process-wait proc) (error () nil)))

(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failure(s))~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
