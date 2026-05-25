;;;; demo-init.lisp — v0.8-era demo init used by batch-os-demo,
;;;; batch-os-lisp-runtime, batch-os-user-flow, batch11-demo-init.
;;;;
;;;; v0.37 Phase F (driver-D3): when init.lisp.example was rewritten
;;;; for v0.27+ (which-key + leader keymap, no page-nav defcommands),
;;;; the four drivers above started failing on "next-page defined" /
;;;; "where-is-command 'next-page contains j".  Rather than retrofit
;;;; either the new init.lisp.example or those drivers (each
;;;; demonstrates a different SPEC capability and shouldn't bleed into
;;;; the others), keep both files: the user-facing example is at
;;;; backend/init.lisp.example; the v0.8 stack-exercise content lives
;;;; here, owned by the e2e suite.

(in-package :cl-user)

;;; ── helpers ────────────────────────────────────────────────────────────

(defun %current-page (&optional (win-id "w1"))
  (let ((d (limn/bridge:response-data (limn:call "view/get" :|win-id| win-id))))
    (getf d :|page|)))

(defun %page-count (&optional (win-id "w1"))
  (let ((d (limn/bridge:response-data (limn:call "view/get" :|win-id| win-id))))
    (getf d :|page-count|)))

(defun %goto-page (n &optional (win-id "w1"))
  (limn:call "view/set" :|win-id| win-id :|page| n))

(defun %clamp (n lo hi) (max lo (min n hi)))

;;; ── page-nav commands ──────────────────────────────────────────────────

(limn/cmd:defcommand next-page ()
  (lambda ()
    (let* ((p (%current-page))
           (n (%page-count)))
      (%goto-page (%clamp (1+ p) 0 (1- n))))))

(limn/cmd:defcommand prev-page ()
  (lambda ()
    (%goto-page (%clamp (1- (%current-page)) 0 1000000))))

(limn/cmd:defcommand first-page ()
  (lambda () (%goto-page 0)))

(limn/cmd:defcommand last-page ()
  (lambda () (%goto-page (1- (%page-count)))))

;;; ── search command (minibuffer demo) ──────────────────────────────────
;;;
;;; The "s" interactive spec drives the framework's minibuffer reader.
;;; C-g during the prompt aborts via minibuffer-cancelled (the binding
;;; in limn.lisp catches it so the binding return is clean).
;;;
;;; For v0.8 we just echo the query to *Messages* — wiring real
;;; hit-by-hit navigation is engine-side work for v0.9.

(limn/cmd:defcommand search-here (:interactive "s/")
  (lambda (query)
    (limn:call "message/echo"
                :|text| (format nil "Searching for: ~a (~a chars)"
                                query (length query)))))

;;; ── bindings ──────────────────────────────────────────────────────────
;;;
;;; vim convention: j/k = down/up by page, g g = first, G = last, / = search.
;;; All bindings use symbol form so where-is-command can find them.

(limn:bind "j"   'next-page)
(limn:bind "k"   'prev-page)
(limn:bind "g g" 'first-page)
(limn:bind "G"   'last-page)
(limn:bind "/"   'search-here)

(format t ";; demo init.lisp loaded: j/k page nav, g-g/G boundaries, / search~%")
