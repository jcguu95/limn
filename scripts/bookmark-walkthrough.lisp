;;;; bookmark-walkthrough.lisp — interactive REPL checklist for
;;;; v0.37 "bookmark everywhere".
;;;;
;;;; Loaded by scripts/bookmark-walkthrough.sh, which handles ulimit,
;;;; nix shell, LIMN_BIN auto-detect (and auto-build), and the Limn
;;;; spawn.  This file is just the step engine + the steps.
;;;;
;;;; Per step:
;;;;   1. Title + the Lisp form that will be evaluated
;;;;   2. Expected result (English)
;;;;   3. [SPC] inject / [s] skip / [q] quit            ← you type this
;;;;   4. (form runs, result printed)
;;;;   5. Match expected? [y] / [n] / [s]                ← you type this
;;;;   6. Verdict recorded
;;;;
;;;; At the end: a copy-pasteable summary block.

(in-package #:cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

;;; ── silent backend bring-up ────────────────────────────────────────

(defvar *walkthrough-muffle*
  (lambda (w)
    (let ((m (princ-to-string w)))
      (when (or (and (search "found several entries" m)
                     (search "lib/sbcl" m))
                (search "redefining" m))
        (muffle-warning w)))))

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (error "scripts/bookmark-walkthrough.sh did not export LIMN_BACKEND_DIR")))

;; Two separate forms so the reader doesn't choke on ASDF symbols
;; before (require :asdf) has run.  Same split as backend/repl.lisp.
(handler-bind ((warning *walkthrough-muffle*))
  (require :asdf))

(handler-bind ((warning *walkthrough-muffle*))
  (pushnew (truename *bdir*) asdf:*central-registry* :test #'equal)
  (asdf:initialize-source-registry)
  (let ((*standard-output* (make-broadcast-stream)))   ; muffle ASDF chatter
    (asdf:load-system :limn)))

;;; ── step framework ─────────────────────────────────────────────────

(defparameter *line*
  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

(defvar *results* '()
  "List of (number title verdict) tuples, oldest-first via push+nreverse.")

(defun read-key (&key (allowed nil))
  "Read a line, return the first non-space char (lowercase).
   If ALLOWED is a list of chars and input isn't in it, reprompt.
   ENTER alone defaults to the first char in ALLOWED (or #\space)."
  (force-output)
  (loop
    (let ((line (read-line *standard-input* nil nil)))
      (when (null line) (return :eof))
      (let* ((s (string-trim '(#\space #\tab) line))
             (c (cond
                  ((zerop (length s))
                   (if allowed (char-downcase (first allowed)) #\space))
                  (t (char-downcase (char s 0))))))
        (when (or (null allowed) (member c allowed :test #'char=))
          (return c))
        (format t "  (enter one of: ~{~a~^ / ~}) > " allowed)))))

(defun banner (num total title)
  (format t "~%~a~%  Step ~a/~a — ~a~%~a~%" *line* num total title *line*))

(defun show-form (form)
  (let ((*print-pretty* t) (*print-right-margin* 70))
    (format t "~&  Form:~%")
    (with-input-from-string (s (with-output-to-string (o)
                                 (write form :stream o)))
      (loop for line = (read-line s nil nil) while line
            do (format t "    ~a~%" line)))))

(defun show-expected (text)
  (format t "~&  Expected:~%    ~a~%" text))

(defun show-result (label value)
  (let ((*print-length* 20) (*print-level* 5) (*print-pretty* nil))
    (format t "  ~a ~s~%" label value)))

(defun prompt-eval ()
  (format t "~&  [SPC] inject  [s] skip  [q] quit > ")
  (case (read-key :allowed '(#\space #\s #\q))
    (#\space :eval) (#\s :skip) (#\q :quit) (t :eval)))

(defun prompt-verdict ()
  (format t "~&  Match expected? [y] yes  [n] no  [s] skip > ")
  (case (read-key :allowed '(#\y #\n #\s))
    (#\y :pass) (#\n :fail) (#\s :skip) (t :skip)))

(defun record (num title verdict)
  (push (list num title verdict) *results*)
  (format t "  recorded: ~a~%"
          (ecase verdict (:pass "✓ PASS") (:fail "✗ FAIL") (:skip "· skip"))))

(defun step* (num total title expected thunk display-form)
  "Run one walkthrough step.  Returns :continue or :quit."
  (banner num total title)
  (show-form display-form)
  (show-expected expected)
  (case (prompt-eval)
    (:quit (return-from step* :quit))
    (:skip (record num title :skip) (return-from step* :continue))
    (:eval
     (let ((result (handler-case (funcall thunk)
                     (error (e)
                       (format *error-output* "  ✗ ERROR during eval: ~a~%" e)
                       (list :error (princ-to-string e))))))
       (show-result "→ result:" result)
       (case (prompt-verdict)
         (:pass (record num title :pass))
         (:fail (record num title :fail))
         (:skip (record num title :skip))))))
  :continue)

(defmacro defstep (num total title expected form)
  "Sugar for step*: capture FORM both as a thunk (eval) and as data
   (display).  Returns :continue or :quit; caller dispatches."
  `(step* ,num ,total ,title ,expected
          (lambda () ,form)
          ',form))

(defun summary ()
  (let* ((res  (nreverse *results*))
         (pass (count :pass res :key #'third))
         (fail (count :fail res :key #'third))
         (skip (count :skip res :key #'third))
         (total (length res)))
    (format t "~%~%~a~%  SUMMARY: ~a pass / ~a fail / ~a skip  (~a steps)~%~a~%"
            *line* pass fail skip total *line*)
    (format t "~%Copy-paste below ↓↓↓ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─~%~%")
    (format t "v0.37 bookmark-everywhere walkthrough:~%")
    (dolist (r res)
      (destructuring-bind (n title verdict) r
        (format t "  ~2d. [~a] ~a~%" n
                (ecase verdict (:pass "✓") (:fail "✗") (:skip "·"))
                title)))
    (format t "  ─~%  total: ~a/~a pass~%" pass total)
    (format t "~%─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─~%")))

;;; ── Limn spawn + connect ──────────────────────────────────────────

(defparameter *fixture-pdf*
  (or (sb-posix:getenv "LIMN_FIXTURE")
      (error "scripts/bookmark-walkthrough.sh did not export LIMN_FIXTURE")))

(defparameter *limn-bin*
  (or (sb-posix:getenv "LIMN_BIN")
      (error "scripts/bookmark-walkthrough.sh did not export LIMN_BIN")))

(defparameter *sock* (format nil "/tmp/limn-walk-~a" (sb-posix:getpid)))
(defparameter *tmp-txt* (format nil "/tmp/limn-walk-~a.txt" (sb-posix:getpid)))
(defparameter *tmp-side* (format nil "/tmp/limn-walk-~a.lisp" (sb-posix:getpid)))
(defparameter *proc* nil)

(defun spawn-and-connect ()
  (with-open-file (out *tmp-txt* :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
    (write-sequence "hello bookmark world" out))
  (setf *proc*
        (sb-ext:run-program (namestring *limn-bin*)
                             (list "--test-mode" "--socket" *sock*)
                             :wait nil :search nil
                             :output "/tmp/limn-walk.log"
                             :if-output-exists :supersede :error :output))
  (loop repeat 100 until (probe-file *sock*) do (sleep 0.05))
  (limn:start *sock*)
  (sleep 0.2))

(defun cleanup ()
  (ignore-errors (limn:stop))
  (sleep 0.1)
  (when *proc*
    (handler-case (sb-ext:process-kill *proc* 15) (error () nil))
    (handler-case (sb-ext:process-wait *proc*) (error () nil)))
  (ignore-errors (delete-file *tmp-txt*))
  (ignore-errors (delete-file *tmp-side*)))

;;; ── intro ──────────────────────────────────────────────────────────

(defun intro ()
  (format t "~%~a~%" *line*)
  (format t "  v0.37 bookmark-everywhere — interactive walkthrough~%")
  (format t "~a~%" *line*)
  (format t "~%  Per step you'll see a Lisp form + what it should return.~%")
  (format t "  Type a key + ENTER:~%")
  (format t "    [SPC] inject / run the form     (or just ENTER)~%")
  (format t "    [s]   skip this step~%")
  (format t "    [q]   quit early (still prints summary)~%")
  (format t "  After the result prints:~%")
  (format t "    [y]   matches expectation~%")
  (format t "    [n]   does not match~%")
  (format t "    [s]   not sure, skip~%")
  (format t "~%  Press ENTER to begin…")
  (force-output)
  (read-line *standard-input* nil nil))

;;; ── helpers used inside steps (avoid noise in displayed forms) ─────

(defun %ok? (r) (eq (getf r :|ok|) t))
(defun %data (r) (getf r :|data|))

(defparameter *bid* nil
  "Bound by step 3 to the mupdf buffer-id; later steps read it.")
(defparameter *fbuf* nil
  "Bound by step 9 to the text fbuf id.")
(defparameter *pdf-record* nil
  "Bound by step 5 to the captured PDF record (path/page/offsets);
   step 7 jumps back via this exact plist — matches real usage where
   the record carries real offsets, not artificial 0.0 (which C++
   reads as doc-absolute coord, undoing the page set).")

;;; ── the walkthrough ───────────────────────────────────────────────

(defparameter *total-steps* 14)

(defun walkthrough ()
  (intro)
  (spawn-and-connect)
  (unwind-protect
   (block w
     (macrolet ((stp (n title expected form)
                  `(when (eq (defstep ,n *total-steps* ,title ,expected ,form)
                             :quit)
                     (return-from w :quit))))

       ;; ── A. sanity / module presence ────────────────────────────
       (stp 1 "limn/bookmark package is loaded"
            "Returns T (struct + 3 exports all present)."
         (and (find-package '#:limn/bookmark)
              (fboundp 'limn/bookmark:bookmark-add)
              (fboundp 'limn/bookmark:bookmark-jump)
              (fboundp 'limn/bookmark:bookmarks-save)
              t))

       (stp 2 "install handlers (text + org + pdf)"
            "Returns T; all 3 handlers registered against cl-user mode symbols."
         (and (limn/bookmark-handlers:install)
              (limn/bookmark:handler-registered-p
               (intern "TEXT-MODE" :cl-user))
              (limn/bookmark:handler-registered-p
               (intern "ORG-MODE"  :cl-user))
              (limn/bookmark:handler-registered-p
               (intern "PDF-MODE"  :cl-user))))

       ;; ── B. PDF: open + record + jump ───────────────────────────
       (stp 3 "open fixture PDF via mupdf engine"
            "Returns a string buffer-id (e.g. \"b1\")."
         (let ((r (limn:call "bridge/engine-load"
                              :|win-id| "w1"
                              :|engine| "mupdf"
                              :|path|   *fixture-pdf*)))
           (setf *bid* (and (%ok? r) (getf (%data r) :|buffer-id|)))
           (setf (gethash *bid* limn/pdf-mode::*buffer-id-to-path*)
                 *fixture-pdf*)
           *bid*))

       (stp 4 "navigate to page 2 (0-indexed)"
            "Returns a plist with :|ok| T (wire ack)."
         (limn:call "view/set" :|win-id| "w1" :|page| 2))

       (stp 5 "default-pdf-record captures (:path :page 2 :y-offset :x-offset)"
            "Returns a plist where :PATH = fixture, :PAGE = 2, :Y-OFFSET numeric (~ thousands at page 2)."
         (progn (setf *pdf-record*
                      (limn/bookmark-handlers:default-pdf-record))
                *pdf-record*))

       (stp 6 "save the record, then wander to page 0"
            "Returns a plist with :|ok| T."
         (limn:call "view/set" :|win-id| "w1" :|page| 0))

       (stp 7 "default-pdf-jump on the *captured* record → back to page 2"
            "Returns T after wire round-trip.  Uses real y-offset from step 5 (not artificial 0.0)."
         (limn/bookmark-handlers:default-pdf-jump *pdf-record*))

       (stp 8 "verify page is now 2"
            "Returns 2 (integer)."
         (getf (%data (limn:call "view/get" :|win-id| "w1")) :|page|))

       ;; ── C. text: open + record + jump ─────────────────────────
       (stp 9 "find-file the tmp text fixture"
            "Returns a buffer-id string (e.g. \"limn-file-buf-2\")."
         (progn (setf *fbuf* (limn/file:find-file *tmp-txt*))
                *fbuf*))

       (stp 10 "move cursor to offset 11 in the text buffer"
             "Returns a plist with :|ok| T."
         (let ((wire (limn/file:buffer-wire-id *fbuf*)))
           (limn:call "buffer/cursor-set"
                      :|buffer-id| wire :|offset| 11)))

       (stp 11 "default-text-record captures (:file :position 11)"
             "Returns a plist :FILE = tmp path, :POSITION = 11."
         (limn/bookmark-handlers:default-text-record))

       (stp 12 "default-text-jump with :position 0 → cursor moves to 0"
             "Returns T; cursor is at offset 0 afterward."
         (progn
           (limn/bookmark-handlers:default-text-jump
            (list :file *tmp-txt* :position 0))
           (let ((wire (limn/file:buffer-wire-id *fbuf*)))
             (getf (%data (limn:call "buffer/cursor-get"
                                      :|buffer-id| wire))
                   :|offset|))))

       ;; ── D. persistence round-trip with CJK ────────────────────
       (stp 13 "save CJK-named bookmark → clear → load → still there"
             "Returns the bookmark struct with :name 第一章 🌟, :handler PDF-MODE."
         (progn
           (limn/bookmark:bookmark-clear)
           (limn/bookmark:bookmark-add
            (limn/bookmark:make-bookmark
             :name "第一章 🌟"
             :handler (intern "PDF-MODE" :cl-user)
             :record (list :path *fixture-pdf* :page 1
                           :y-offset 0.0 :x-offset 0.0)))
           (limn/bookmark:bookmarks-save *tmp-side*)
           (limn/bookmark:bookmark-clear)
           (limn/bookmark:bookmarks-load *tmp-side*)
           (limn/bookmark:bookmark-find "第一章 🌟")))

       ;; ── E. M-x integration (text-mode — focus is on the text buf
       ;; from steps 9–12, so we bookmark text here; PDF flow is
       ;; covered by steps 4–8) ──────────────────────────────────
       (stp 14 "M-x bookmark-set 'foo via mocked minibuffer → added to store"
             "Returns the bookmark struct for \"foo\" with handler = TEXT-MODE."
         (let ((mb   (limn/mode:make-mode-buffer))
               (tm   (intern "TEXT-MODE" :cl-user))
               (wire (limn/file:buffer-wire-id *fbuf*)))
           (when (limn/mode:find-mode tm)
             (limn/mode:activate mb tm))
           (limn/runtime:register-mode-buffer wire mb)
           (limn/runtime:set-window-active-buffer "w1" wire)
           (limn/bookmark:bookmark-clear)
           (let ((limn/cmd:*minibuffer-read*
                  (lambda (p) (declare (ignore p)) "foo")))
             (limn/cmd:call-interactively
              (find-symbol "BOOKMARK-SET" :cl-user)))
           (limn/bookmark:bookmark-find "foo")))))

   (cleanup))
  (summary))

;;; ── go ────────────────────────────────────────────────────────────

(walkthrough)
(sb-ext:exit :code 0)
