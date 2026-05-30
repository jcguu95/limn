;;;; ibuffer-debug.lisp — drive the whole ibuffer flow via call-interactively
;;;; (no keyboard needed), printing wire + Lisp state after each step.
;;;;
;;;; Loaded AFTER (o tutorial.pdf) by run-repl.sh.  Headless is fine —
;;;; we just want to verify wire-side view/get reports the right bid.

(in-package #:cl-user)

(sleep 1.0)   ; let initial PDF settle

(defun %dbg-state (label)
  (format t "~&~%━━━ ~a ━━━~%" label)
  (let* ((vr (handler-case (limn:call "view/get" :|win-id| "w1")
               (error (e) (list :error (princ-to-string e)))))
         (vd (and vr (handler-case (limn/bridge:response-data vr)
                       (error () nil))))
         (wire-bid (and vd (getf vd :|buffer-id|)))
         (rt        (find-package '#:limn/runtime))
         (get-act   (and rt (find-symbol "WINDOW-ACTIVE-BUFFER" rt)))
         (lisp-act  (and get-act (funcall (symbol-function get-act) "w1")))
         (s         (and (find-symbol "*IBUFFER-STATE*" '#:limn/ibuffer)
                          (symbol-value
                           (find-symbol "*IBUFFER-STATE*" '#:limn/ibuffer))))
         (regs      (sort (copy-list (limn/buffer:list-all)) #'string<)))
    (format t "  wire view/get  → :buffer-id ~s~%" wire-bid)
    (format t "  Lisp *active*  → ~s~%" lisp-act)
    (format t "  registered     → ~s~%" regs)
    (when s
      (format t "  ibuffer state  → ibuffer-bid=~s current=~s~%"
              (limn/ibuffer:ibuffer-state-ibuffer-buf-id s)
              (limn/ibuffer:ibuffer-state-current s)))
    (finish-output)))

(%dbg-state "T+0  baseline (just after `(o tutorial.pdf)`)")

;; ── simulate user pressing M-x ibuffer ─────────────────────────────────
(format t "~%>>> simulating: M-x ibuffer~%")
(handler-case (limn/cmd:call-interactively 'cl-user::ibuffer)
  (error (e) (format t "  !! error: ~a~%" e)))
(sleep 0.3)
(%dbg-state "T+1  after M-x ibuffer")

;; ── simulate buffer/show back to PDF ───────────────────────────────────
;; v0.40: ibuffer no longer exposes a q binding (see limn-ibuffer.lisp's
;; install for rationale).  To leave ibuffer one uses RET on a row or
;; M-x switch-to-buffer — both invoke buffer/show under the hood.  Here
;; we just call buffer/show directly to inspect the round-trip.
(format t "~%>>> direct: (limn:call \"buffer/show\" :buffer-id b1 :win-id w1)~%")
(let ((r (handler-case (limn:call "buffer/show"
                                  :|buffer-id| "b1" :|win-id| "w1")
           (error (e) (list :error (princ-to-string e))))))
  (format t "  response: ~s~%" r))
(sleep 0.3)
(%dbg-state "T+2  after buffer/show b1 (back to PDF)")

;; ── M-x ibuffer again to verify state recreation ───────────────────────
(format t "~%>>> simulating: M-x ibuffer (2nd time)~%")
(handler-case (limn/cmd:call-interactively 'cl-user::ibuffer)
  (error (e) (format t "  !! error: ~a~%" e)))
(sleep 0.3)
(%dbg-state "T+3  after 2nd M-x ibuffer")

(format t "~%━━━ DONE ━━━~%")
(finish-output)
(sleep 0.5)
(sb-ext:exit)
