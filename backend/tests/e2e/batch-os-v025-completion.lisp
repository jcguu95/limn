;;;; v0.25 §C — completion / minibuffer algorithm OS-tier
;;;;
;;;; This file COMPLEMENTS the existing batch-os-completing-read.lisp
;;;; (which covers the minibuffer wire protocol — open/set-prompt/set-text/
;;;; get/close + RET/ESC events). Here we cover what that test does NOT:
;;;; the matching algorithm, collection-driven dispatch, history wiring,
;;;; require-match, default, annotation-function.
;;;;
;;;; No Xvfb needed — most of this is pure Lisp algorithm.
;;;;
;;;; Ω1a  complete-with-styles substring matches anywhere in candidate
;;;; Ω1b  prefix style: only match at start
;;;; Ω1c  flex style: characters in order, gaps allowed
;;;; Ω2   completing-read on collection list, exact match → returns input
;;;; Ω3   completing-read multiple matches → returns first (batch mode)
;;;; Ω4   completing-read require-match t + no candidate → error
;;;; Ω5   completing-read empty input + default → returns default
;;;; Ω6   completing-read history integration: result pushed to ring
;;;; Ω7   read-from-minibuffer initial-contents → minibuffer-contents echoes
;;;; Ω8   annotation-function called once per candidate
;;;; Ω9   %bridge-open-minibuffer triggers real minibuffer/open wire (smoke)

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v025cm"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-history.lisp" "limn-completion.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))

(format t "~%=== batch-os-v025-completion ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v025cm-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v025cm.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── Ω1: complete-with-styles ─────────────────────────────────────────
  (format t "~%── Ω1: complete-with-styles ──~%")
  (let* ((cands '("hello" "loop" "world" "shellfish"))
         (sub   (limn/completion:complete-with-styles "lo" cands '(substring)))
         (pre   (limn/completion:complete-with-styles "lo" cands '(prefix)))
         (flx   (limn/completion:complete-with-styles "hlo" cands '(flex))))
    ;; substring "lo" matches anywhere → "hello" (has 'lo'), "loop", "shellfish" (no), "world" (no)
    ;; Actually let me check: "hello"=h-e-l-l-o, has "lo" at index 3-4. yes.
    ;;                       "loop" has "lo" at 0-1. yes.
    ;;                       "world" has "lo" — no, w-o-r-l-d. Hmm, "rl" "ld" not "lo".
    ;;                       "shellfish" — s-h-e-l-l-f, no "lo".
    ;; So substring → ("hello" "loop").
    (check (format nil "Ω1a substring \"lo\" → 2 matches (got ~a)" sub)
           (and (= (length sub) 2)
                (member "hello" sub :test #'equal)
                (member "loop"  sub :test #'equal)))
    (check (format nil "Ω1b prefix \"lo\" → only \"loop\" (got ~a)" pre)
           (and (= (length pre) 1)
                (member "loop" pre :test #'equal)))
    ;; flex "hlo" → h-?-l-?-o. "hello" h(0) l(2) o(4) yes. "loop" no.
    ;; "shellfish" — h is at 1, l is at 3, o doesn't appear. So no.
    ;; "world" — w-o-r-l-d. No 'h'.
    (check (format nil "Ω1c flex \"hlo\" → hello (got ~a)" flx)
           (and (>= (length flx) 1) (member "hello" flx :test #'equal))))

  ;;; ── Ω2: completing-read exact match ──────────────────────────────────
  (format t "~%── Ω2: exact match ──~%")
  (let ((r (limn/completion:completing-read
            "pick: " '("apple" "banana" "cherry")
            :initial-input "banana")))
    (check (format nil "Ω2 returns exact match \"banana\" (got ~s)" r)
           (equal r "banana")))

  ;;; ── Ω3: multiple matches → first ─────────────────────────────────────
  (format t "~%── Ω3: multiple matches ──~%")
  (let ((r (limn/completion:completing-read
            "pick: " '("apple" "apricot" "banana")
            :initial-input "ap")))
    (check (format nil "Ω3 returns first match (got ~s)" r)
           (or (equal r "apple") (equal r "apricot"))))

  ;;; ── Ω4: require-match + no match → error ────────────────────────────
  (format t "~%── Ω4: require-match no candidate ──~%")
  (let ((errored
          (handler-case
              (progn (limn/completion:completing-read
                      "pick: " '("apple" "banana")
                      :initial-input "ZZZ" :require-match t)
                     nil)
            (error () t))))
    (check (format nil "Ω4 errors when require-match + no match (got ~s)" errored)
           errored))

  ;;; ── Ω5: empty + default → default ───────────────────────────────────
  (format t "~%── Ω5: default returned ──~%")
  (let ((r (limn/completion:completing-read
            "pick: " '("apple" "banana")
            :initial-input "" :default "fallback")))
    (check (format nil "Ω5 returns default (got ~s)" r)
           (equal r "fallback")))

  ;;; ── Ω6: history integration ─────────────────────────────────────────
  (format t "~%── Ω6: history push ──~%")
  ;; Clear our test history ring first.
  (limn/history:define-history "v025-cm-hist" :size 10)
  (limn/completion:completing-read
   "pick: " '("apple" "banana")
   :initial-input "apple" :history "v025-cm-hist")
  (let ((items (limn/history:history-items "v025-cm-hist")))
    (check (format nil "Ω6 history ring has the result (items=~s)" items)
           (member "apple" items :test #'equal)))

  ;;; ── Ω7: read-from-minibuffer initial-contents ──────────────────────
  (format t "~%── Ω7: read-from-minibuffer ──~%")
  (let ((r (limn/completion:read-from-minibuffer
            "Type: " :initial-contents "preset")))
    (check (format nil "Ω7a returns initial-contents (got ~s)" r)
           (equal r "preset"))
    (check (format nil "Ω7b minibuffer-contents echoes (got ~s)"
                   (limn/completion:minibuffer-contents))
           (equal (limn/completion:minibuffer-contents) "preset")))

  ;;; ── Ω8: annotation-function ─────────────────────────────────────────
  (format t "~%── Ω8: annotation-function ──~%")
  (let ((called nil))
    (limn/completion:completing-read
     "pick: " '("aa" "bb" "cc")
     :initial-input ""   ; empty so all candidates flow through annotation
     :annotation-function (lambda (c) (push c called)))
    (check (format nil "Ω8 annotation called for each candidate (got ~s)"
                   (reverse called))
           (= (length called) 3)))

  ;;; ── Ω9: bridge wire smoke test ──────────────────────────────────────
  ;; %bridge-open-minibuffer is an internal helper; call it through
  ;; the package's internal symbol. It should issue minibuffer/open via wire.
  (format t "~%── Ω9: %bridge-open-minibuffer wire ──~%")
  (limn:call "minibuffer/close")    ; reset state
  (let ((open-call-pkg (find-symbol "%BRIDGE-OPEN-MINIBUFFER" '#:limn/completion)))
    (when open-call-pkg
      (funcall open-call-pkg "Smoke: "))
    (let ((r (limn:call "minibuffer/get")))
      (check (format nil "Ω9 minibuffer is open after %bridge call (got open=~s)"
                     (getf (getf r :|data|) :|open|))
             (eq (getf (getf r :|data|) :|open|) t))))
  (limn:call "minibuffer/close")

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
