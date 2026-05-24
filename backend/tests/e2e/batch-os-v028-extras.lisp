;;;; v0.28 — keymap (text-nav + map! + which-key) OS-tier extras
;;;;
;;;; Companion to batch-os-v028-keymap.lisp. That file covers happy-path
;;;; navigation + the :map / :prefix map! variants + which-key mode
;;;; toggle. This file picks up the dropped scope:
;;;;
;;;;   §A text-nav: the three uncovered fns (newline / delete-forward-char
;;;;                / kill-word), buffer-boundary clamping, CJK word
;;;;                navigation
;;;;   §B map!:     :leader and :mode variants + one error path
;;;;   §C which-key: stale prefix cancellation (the real reason the
;;;;                 module exists), empty prefix doesn't fire
;;;;   integration: text-nav editing → isearch from new cursor; kill-word
;;;;                + kill-line both push to the same v0.24 kill-ring
;;;;
;;;; No Xvfb needed — all keypress paths in v028-keymap; here we exercise
;;;; the Lisp surface in a real binary process, which is enough for the
;;;; behaviours we care about (boundary checks, hook + closure semantics,
;;;; cross-module vtable wiring).
;;;;
;;;; Ω1   newline at middle of line splits into two lines
;;;; Ω2   delete-forward-char deletes char at point; at EOL deletes the \n
;;;; Ω3   kill-word kills next word and pushes to kill-ring
;;;; Ω4   C-n on last line: cursor doesn't move
;;;; Ω5   C-p on first line: cursor doesn't move
;;;; Ω6   forward-word at end of buffer / backward-word at start clamp
;;;; Ω7   CJK forward-word walks 你好 as a single word (cp > 127)
;;;; Ω8   map! :leader binds into limn/keys:*leader-keymap*
;;;; Ω9   map! :mode 'M binds into M's keymap
;;;; Ω10  map! odd-pairs expansion → runtime error
;;;; Ω11  which-key stale prefix cancellation: deferred CB for old
;;;;        prefix does NOT echo after *current-prefix* changes
;;;; Ω12  which-key empty prefix → no timer scheduled at all
;;;; Ω13  text-nav newline + isearch: edit then start search from new pos
;;;; Ω14  kill-word + kill-line both accumulate in *kill-ring*

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v028ex"))

;; Load order matters: limn-kill BEFORE limn-text-nav so the latter's
;; (install) call at load-time can auto-wire *kill-new-fn*.
(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-kill.lisp" "limn-text-nav.lisp"
             "limn-map-macro.lisp" "limn-which-key.lisp"
             "limn-isearch.lisp"))
  (load (b/ f)))

;; Belt-and-suspenders: re-run text-nav install in case load order
;; ever changes.
(limn/text-nav:install)

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

(defun fresh-text-buf ()
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "text" :|path| "" :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun fill-buf (bid str)
  (let ((cur (or (buf-text bid) "")))
    (when (> (length cur) 0)
      (limn:call "buffer/delete" :|buffer-id| bid
                  :|from| 0 :|to| (length cur))))
  (when (> (length str) 0)
    (limn:call "buffer/insert" :|buffer-id| bid :|at| 0 :|text| str)))

(defun wire-text-nav (bid)
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
  (setf limn/text-nav:*kill-new-fn* #'limn/kill:kill-new)
  bid)

(format t "~%=== batch-os-v028-extras ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v028ex-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v028ex.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ──────────────────────────────────────────────────────────────────────
  ;;; §A text-nav extras
  ;;; ──────────────────────────────────────────────────────────────────────

  ;;; ── Ω1: newline splits the line ─────────────────────────────────────
  (format t "~%── Ω1: newline ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-text-nav bid)
    (fill-buf bid "abcdef")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 3)
    (limn/text-nav:newline bid)
    (let ((txt (buf-text bid)))
      (check (format nil "Ω1 buffer split: \"abc\\ndef\" (got ~s)" txt)
             (equal txt (format nil "abc~%def")))))

  ;;; ── Ω2: delete-forward-char ─────────────────────────────────────────
  (format t "~%── Ω2: delete-forward-char ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-text-nav bid)
    (fill-buf bid "abcdef")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 2)
    (limn/text-nav:delete-forward-char bid)
    (let ((txt (buf-text bid)))
      (check (format nil "Ω2a after C-d at pos 2: \"abdef\" (got ~s)" txt)
             (equal txt "abdef")))
    ;; At EOL of multi-line: cur=3 in "abc\ndef" (the \n is at index 3,
    ;; len=7). Since cur (3) < len (7), delete \n → "abcdef".
    (fill-buf bid (format nil "abc~%def"))
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 3)
    (limn/text-nav:delete-forward-char bid)
    (let ((txt (buf-text bid)))
      (check (format nil "Ω2b C-d at EOL deletes \\n (got ~s)" txt)
             (equal txt "abcdef")))
    ;; At end of buffer: no-op (cur == len).
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 6)
    (limn/text-nav:delete-forward-char bid)
    (let ((txt (buf-text bid)))
      (check (format nil "Ω2c C-d at EOB is no-op (got ~s)" txt)
             (equal txt "abcdef"))))

  ;;; ── Ω3: kill-word → kill-ring ───────────────────────────────────────
  (format t "~%── Ω3: kill-word + kill-ring ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-text-nav bid)
    (fill-buf bid "hello world foo")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
    (setf limn/kill:*kill-ring* nil)
    (limn/text-nav:kill-word bid)
    (let ((txt  (buf-text bid))
          (head (car limn/kill:*kill-ring*)))
      (check (format nil "Ω3a kill-word from 0 removes \"hello\" (got ~s)" txt)
             (equal txt " world foo"))
      (check (format nil "Ω3b kill-ring head = \"hello\" (got ~s)" head)
             (equal head "hello"))))

  ;;; ── Ω4: C-n on last line — no move ─────────────────────────────────
  (format t "~%── Ω4: next-line clamp at last line ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-text-nav bid)
    (fill-buf bid (format nil "first~%second~%third"))
    ;; offsets: f=0..4 \n=5  s=6..11 \n=12  t=13..17 (no trailing \n)
    ;; cursor at 14 (middle of "third")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 14)
    (setf limn/text-nav:*goal-column* nil)
    (limn/text-nav:next-line bid)
    (check (format nil "Ω4 C-n on last line: cursor unchanged 14 (got ~a)"
                   (buf-cursor bid))
           (= (buf-cursor bid) 14)))

  ;;; ── Ω5: C-p on first line — no move ────────────────────────────────
  (format t "~%── Ω5: previous-line clamp at first line ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-text-nav bid)
    (fill-buf bid (format nil "first~%second"))
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 2)
    (setf limn/text-nav:*goal-column* nil)
    (limn/text-nav:previous-line bid)
    (check (format nil "Ω5 C-p on first line: cursor unchanged 2 (got ~a)"
                   (buf-cursor bid))
           (= (buf-cursor bid) 2)))

  ;;; ── Ω6: forward / backward-word clamp at buffer edges ──────────────
  (format t "~%── Ω6: word-nav clamp ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-text-nav bid)
    (fill-buf bid "alpha")
    ;; M-f from middle of last word → should reach length (5), not beyond
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 3)
    (limn/text-nav:forward-word bid)
    (check (format nil "Ω6a M-f clamps at length 5 (got ~a)" (buf-cursor bid))
           (= (buf-cursor bid) 5))
    ;; Another M-f at the end → stays at 5
    (limn/text-nav:forward-word bid)
    (check (format nil "Ω6b M-f at EOB is no-op (got ~a)" (buf-cursor bid))
           (= (buf-cursor bid) 5))
    ;; M-b from middle → 0
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 3)
    (limn/text-nav:backward-word bid)
    (check (format nil "Ω6c M-b clamps at 0 (got ~a)" (buf-cursor bid))
           (= (buf-cursor bid) 0))
    ;; Another M-b at start → stays at 0
    (limn/text-nav:backward-word bid)
    (check (format nil "Ω6d M-b at BOB is no-op (got ~a)" (buf-cursor bid))
           (= (buf-cursor bid) 0)))

  ;;; ── Ω7: CJK forward / backward-word ─────────────────────────────────
  (format t "~%── Ω7: CJK word navigation ──~%")
  ;; "你好 世界 hello"
  ;; codepoints: 你=0 好=1 (space)=2 世=3 界=4 (space)=5 h=6 e=7 l=8 l=9 o=10
  ;; (length 11)
  (let ((bid (fresh-text-buf)))
    (wire-text-nav bid)
    (fill-buf bid "你好 世界 hello")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
    (setf limn/text-nav:*goal-column* nil)
    ;; M-f from 0: skip non-word (none) → skip word (你好) → stop at 2 (space)
    (limn/text-nav:forward-word bid)
    (check (format nil "Ω7a M-f over 你好 → cursor 2 (got ~a)" (buf-cursor bid))
           (= (buf-cursor bid) 2))
    ;; M-f again: skip space → skip 世界 → stop at 5
    (limn/text-nav:forward-word bid)
    (check (format nil "Ω7b M-f over 世界 → cursor 5 (got ~a)" (buf-cursor bid))
           (= (buf-cursor bid) 5))
    ;; M-f again: skip space → skip "hello" → stop at 11 (length)
    (limn/text-nav:forward-word bid)
    (check (format nil "Ω7c M-f over hello → cursor 11 (got ~a)" (buf-cursor bid))
           (= (buf-cursor bid) 11))
    ;; M-b from 11: skip nothing (h is word) → skip word "hello" back → stop at 6
    (limn/text-nav:backward-word bid)
    (check (format nil "Ω7d M-b back to start of hello → 6 (got ~a)" (buf-cursor bid))
           (= (buf-cursor bid) 6)))

  ;;; ──────────────────────────────────────────────────────────────────────
  ;;; §B map! extras
  ;;; ──────────────────────────────────────────────────────────────────────

  ;;; ── Ω8: :leader variant ─────────────────────────────────────────────
  (format t "~%── Ω8: map! :leader ──~%")
  (defun v028-leader-fn (ev) (declare (ignore ev)) :leader-fired)
  (limn/map-macro:map! :leader "x" #'v028-leader-fn)
  (let ((binding (limn/keys:lookup limn/keys:*leader-keymap* "x")))
    (check (format nil "Ω8 :leader binding stored in *leader-keymap* (got ~s)" binding)
           (functionp binding)))

  ;;; ── Ω9: :mode variant ───────────────────────────────────────────────
  (format t "~%── Ω9: map! :mode ──~%")
  (limn/mode:define-mode 'v028-test-mode)
  ;; Lazily-created keymap slot starts nil — set explicitly before map!.
  (setf (limn/mode:mode-keymap (limn/mode:find-mode 'v028-test-mode))
        (limn/keys:make-keymap))
  (defun v028-mode-fn (ev) (declare (ignore ev)) :mode-fired)
  (limn/map-macro:map! :mode 'v028-test-mode "y" #'v028-mode-fn)
  (let* ((m  (limn/mode:find-mode 'v028-test-mode))
         (km (limn/mode:mode-keymap m))
         (binding (limn/keys:lookup km "y")))
    (check (format nil "Ω9 :mode binding stored in mode's keymap (got ~s)" binding)
           (functionp binding)))

  ;;; ── Ω10: odd-pairs → runtime error ─────────────────────────────────
  (format t "~%── Ω10: map! odd pairs error ──~%")
  ;; The macro expands to (error "map!: odd number of key/action forms")
  ;; — evaluating that expansion at runtime signals.
  (let ((errored
          (handler-case
              (progn (eval '(limn/map-macro:map!
                              :map limn:*global-keymap*
                              "ka" #'v028-leader-fn
                              "kb"))    ; missing value
                     nil)
            (error () t))))
    (check (format nil "Ω10 odd-pairs map! signals at runtime (got ~s)" errored)
           errored))

  ;;; ──────────────────────────────────────────────────────────────────────
  ;;; §C which-key extras
  ;;; ──────────────────────────────────────────────────────────────────────

  ;;; ── Ω11: stale prefix cancellation ─────────────────────────────────
  (format t "~%── Ω11: which-key stale cancellation ──~%")
  ;; Strategy: install a deferring *timer-fn* (queues callbacks instead
  ;; of running them).  Fire prefix change #1 → CB1 queued.  Fire prefix
  ;; change #2 → CB2 queued + *current-prefix* updated.  Run CB1: stale
  ;; check (equal *current-prefix* old-prefix) fails → no echo.  Run CB2:
  ;; passes → echoes.
  (defparameter *v028-pending* nil)
  (defparameter *v028-echo*    nil)
  (setf limn/which-key:*timer-fn*
        (lambda (delay cb) (declare (ignore delay)) (push cb *v028-pending*)))
  (setf limn/which-key:*echo-fn*
        (lambda (str) (push str *v028-echo*)))
  (limn/which-key:which-key-mode)
  ;; Ensure hook is installed (idempotent).
  (limn/which-key:install)

  ;; Reset baseline.
  (limn/keys:set-key-prefix '())
  (setf *v028-pending* nil *v028-echo* nil)

  ;; First prefix change → queues CB1 (closure with prefix=("C-x"))
  (limn/keys:set-key-prefix '("C-x"))
  (check (format nil "Ω11a CB1 queued after C-x prefix (pending=~a)"
                 (length *v028-pending*))
         (= (length *v028-pending*) 1))

  ;; Second prefix change BEFORE CB1 runs → queues CB2 + updates
  ;; *current-prefix* via %on-prefix-changed.
  (limn/keys:set-key-prefix '("C-h"))
  (check (format nil "Ω11b CB2 queued (pending=~a)" (length *v028-pending*))
         (= (length *v028-pending*) 2))

  ;; Now run the OLDER callback (CB1).  Its closure captured prefix=("C-x"),
  ;; but *current-prefix* is now ("C-h") → stale check fails → no echo.
  ;; (list-pop with reverse to run them in FIFO order)
  (let ((cb1 (car (last *v028-pending*))))
    (funcall cb1))
  (check (format nil "Ω11c stale CB1 did NOT echo (echo log=~s)" *v028-echo*)
         (null *v028-echo*))

  ;; Now run the newer CB2 — should echo.
  (let ((cb2 (first *v028-pending*)))
    (funcall cb2))
  (check (format nil "Ω11d fresh CB2 echoed (echo log=~s)" *v028-echo*)
         (and (consp *v028-echo*)
              ;; Echoes the prefix string somehow (impl uses (format nil "~a" prefix))
              (search "C-h" (first *v028-echo*))))

  ;;; ── Ω12: empty prefix → no timer ───────────────────────────────────
  (format t "~%── Ω12: empty prefix doesn't schedule ──~%")
  (setf *v028-pending* nil *v028-echo* nil)
  ;; *key-prefix* is currently ("C-h"); transitioning to '() should fire
  ;; the event but %prefix-empty-p will short-circuit before *timer-fn*.
  (limn/keys:set-key-prefix '())
  (check (format nil "Ω12 no CB queued for empty prefix (pending=~a)"
                 (length *v028-pending*))
         (= (length *v028-pending*) 0))

  ;;; ──────────────────────────────────────────────────────────────────────
  ;;; Integration
  ;;; ──────────────────────────────────────────────────────────────────────

  ;;; ── Ω13: text-nav edit → isearch from new cursor ───────────────────
  (format t "~%── Ω13: edit then isearch ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-text-nav bid)
    (setf limn/isearch:*buffer-text-fn*
          (lambda (b) (or (buf-text b) "")))
    (setf limn/isearch:*buffer-cursor-fn*  (lambda (b) (buf-cursor b)))
    (setf limn/isearch:*buffer-set-cursor-fn*
          (lambda (b off)
            (limn:call "buffer/cursor-set" :|buffer-id| b :|offset| off)))
    (setf limn/isearch:*highlight-fn*       (lambda (b s f) (declare (ignore b s f))))
    (setf limn/isearch:*clear-highlights-fn* (lambda (b) (declare (ignore b))))
    (setf limn/isearch:*history-push-fn*    (lambda (q) (declare (ignore q))))

    (fill-buf bid "needle")
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 6)
    ;; Insert a newline + "needle haystack" via text-nav.
    (limn/text-nav:newline bid)
    (let ((after-newline (buf-cursor bid)))
      ;; newline only inserts \n, doesn't move cursor (per module body).
      ;; Cursor was at 6; insertion at 6 puts cursor still at 6 (because
      ;; *buffer-insert-fn* doesn't auto-advance).  Buffer is "needle\n".
      ;; Actually the wire's buffer/insert moves the C++ cursor; let's
      ;; just record where we ended up and verify isearch picks up.
      (declare (ignorable after-newline)))
    (limn:call "buffer/insert" :|buffer-id| bid :|at| 7 :|text| "needle haystack")
    ;; Buffer now: "needle\nneedle haystack"
    ;; isearch-start from current cursor — both "needle"s should be found.
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 7)   ; start of line 2
    (let* ((st  (limn/isearch:isearch-start bid))
           (st2 (limn/isearch:isearch-update st "needle"))
           (matches (limn/isearch:isearch-matches st2)))
      (check (format nil "Ω13a both needles found after newline-edit (count=~a)"
                     (length matches))
             (= (length matches) 2))
      ;; Saved-cursor was 7; forward search → nearest match >= 7 is offset 7
      (check (format nil "Ω13b cursor at the line-2 needle, offset 7 (got ~a)"
                     (buf-cursor bid))
             (= (buf-cursor bid) 7))))

  ;;; ── Ω14: kill-word + kill-line → kill-ring accumulates ────────────
  (format t "~%── Ω14: cross-fn kill-ring accumulation ──~%")
  (let ((bid (fresh-text-buf)))
    (wire-text-nav bid)
    (setf limn/kill:*kill-ring* nil)
    (fill-buf bid (format nil "alpha beta~%gamma delta"))
    (limn:call "buffer/cursor-set" :|buffer-id| bid :|offset| 0)
    ;; kill-word: removes "alpha" → ring head = "alpha"
    (limn/text-nav:kill-word bid)
    ;; cursor still at 0 in remaining " beta\ngamma delta"
    ;; kill-line: removes " beta" up to \n → ring head shifts: " beta"
    (limn/text-nav:kill-line bid)
    (let ((ring limn/kill:*kill-ring*))
      (check (format nil "Ω14a ring has 2 entries (got ~a; ring=~s)"
                     (length ring) ring)
             (= (length ring) 2))
      ;; Newest first; kill-line was second, so it's the head.
      (check (format nil "Ω14b head = kill-line result \" beta\" (got ~s)"
                     (first ring))
             (equal (first ring) " beta"))
      (check (format nil "Ω14c next = kill-word \"alpha\" (got ~s)" (second ring))
             (equal (second ring) "alpha"))))

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
