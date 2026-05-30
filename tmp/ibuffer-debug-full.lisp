;;;; Full-flow debug — mirror the GUI driver's 14 steps via call-interactively
;;;; so we can see the wire state at every transition (no human, no GUI).

(in-package #:cl-user)

(sleep 1.0)

(defun %d-show (label)
  (format t "~&~%━━━ ~a ━━━~%" label)
  (let* ((vr (handler-case (limn:call "view/get" :|win-id| "w1")
               (error () nil)))
         (vd (and vr (handler-case (limn/bridge:response-data vr) (error () nil))))
         (wbid (and vd (getf vd :|buffer-id|)))
         (rt   (find-package '#:limn/runtime))
         (ga   (and rt (find-symbol "WINDOW-ACTIVE-BUFFER" rt)))
         (lbid (and ga (funcall (symbol-function ga) "w1")))
         (s    (and (find-symbol "*IBUFFER-STATE*" '#:limn/ibuffer)
                    (symbol-value (find-symbol "*IBUFFER-STATE*" '#:limn/ibuffer))))
         (regs (sort (copy-list (limn/buffer:list-all)) #'string<)))
    (format t "  wire view/get → ~s    Lisp *active* → ~s~%" wbid lbid)
    (format t "  registered    → ~s~%" regs)
    (when s
      (format t "  ibuffer state → ib-bid=~s  current=~s  rows=~d~%"
              (limn/ibuffer:ibuffer-state-ibuffer-buf-id s)
              (limn/ibuffer:ibuffer-state-current s)
              (length (limn/ibuffer:ibuffer-state-rows s))))
    (finish-output)))

(defun %step (n title fn)
  (format t "~%>>> step ~a: ~a~%" n title)
  (handler-case (funcall fn)
    (error (e) (format t "  !! errored: ~a~%" e)))
  (sleep 0.2)
  (%d-show (format nil "after step ~a" n)))

(%d-show "T+0  baseline (after `(o tutorial.pdf)`)")

;; --- step 3: M-x ibuffer ---
(%step 3 "M-x ibuffer"
       (lambda () (limn/cmd:call-interactively 'cl-user::ibuffer)))

;; --- step 6: driver opens /tmp/foo.txt + buffer/show ib + revert ---
(%step 6 "driver opens /tmp/foo.txt + switch back + revert"
       (lambda ()
         (let* ((ib (and (find-symbol "*IBUFFER-STATE*" '#:limn/ibuffer)
                          (symbol-value (find-symbol "*IBUFFER-STATE*" '#:limn/ibuffer))))
                (ib-bid (and ib (limn/ibuffer:ibuffer-state-ibuffer-buf-id ib))))
           ;; open foo.txt via wire
           (let* ((r (limn:call "bridge/engine-load" :|win-id| "w1"
                                :|engine| "text" :|path| ""))
                  (d (limn/bridge:response-data r))
                  (b (and d (getf d :|buffer-id|))))
             (when b
               (limn:call "buffer/load-file" :|buffer-id| b :|path| "/tmp/foo.txt")))
           ;; switch back and revert
           (when ib-bid
             (limn:call "buffer/show" :|buffer-id| ib-bid :|win-id| "w1")
             (limn/cmd:call-interactively 'cl-user::ibuffer-revert)))))

;; --- step 7: n (next-line) ---
(%step 7 "n (ibuffer-next-line)"
       (lambda () (limn/cmd:call-interactively 'cl-user::ibuffer-next-line)))

;; --- step 8: d (mark-for-delete) ---
(%step 8 "d (ibuffer-mark-for-delete)"
       (lambda () (limn/cmd:call-interactively 'cl-user::ibuffer-mark-for-delete)))

;; --- step 9: u (unmark) ---
(%step 9 "u (ibuffer-unmark) — but first move to the marked row"
       (lambda ()
         (limn/cmd:call-interactively 'cl-user::ibuffer-prev-line)
         (limn/cmd:call-interactively 'cl-user::ibuffer-unmark)))

;; --- step 10: d + x (kill) ---
(%step 10 "d + x (mark + execute) on /tmp/foo.txt"
       (lambda ()
         ;; navigate to foo.txt row.  After step 9 we should be on row 1 (next-row after unmark).
         ;; Actually let me just unmark all then carefully move to foo.txt and mark+execute.
         (limn/cmd:call-interactively 'cl-user::ibuffer-unmark-all)
         ;; find foo.txt's index by scanning rows
         (let* ((s (symbol-value (find-symbol "*IBUFFER-STATE*" '#:limn/ibuffer)))
                (rows (and s (limn/ibuffer:ibuffer-state-rows s)))
                (idx  (position-if
                        (lambda (r)
                          (search "foo" (or (limn/ibuffer:ibuffer-row-path r) "")))
                        rows)))
           (format t "    foo.txt is at index ~a~%" idx)
           (when idx
             (setf (limn/ibuffer:ibuffer-state-current s) idx)
             (limn/cmd:call-interactively 'cl-user::ibuffer-mark-for-delete)
             (limn/cmd:call-interactively 'cl-user::ibuffer-do-execute)))))

;; --- step 11: re-open foo.txt + S sort by path ---
(%step 11 "re-open foo.txt + S sort by path"
       (lambda ()
         (let* ((ib (symbol-value (find-symbol "*IBUFFER-STATE*" '#:limn/ibuffer)))
                (ib-bid (and ib (limn/ibuffer:ibuffer-state-ibuffer-buf-id ib))))
           (let* ((r (limn:call "bridge/engine-load" :|win-id| "w1"
                                :|engine| "text" :|path| ""))
                  (d (limn/bridge:response-data r))
                  (b (and d (getf d :|buffer-id|))))
             (when b
               (limn:call "buffer/load-file" :|buffer-id| b :|path| "/tmp/foo.txt")))
           (when ib-bid
             (limn:call "buffer/show" :|buffer-id| ib-bid :|win-id| "w1")))
         ;; sort by path
         (let ((sym (find-symbol "%SORT-BY" '#:limn/ibuffer)))
           (when sym (funcall (symbol-function sym) "path")))))

;; --- step 12: filter "tutorial" ---
(%step 12 "/ filter \"tutorial\""
       (lambda ()
         (let ((sym (find-symbol "%SET-FILTER" '#:limn/ibuffer)))
           (when sym (funcall (symbol-function sym) "tutorial")))))

;; --- step 13: clear filter ---
(%step 13 "/ clear filter"
       (lambda ()
         (let ((sym (find-symbol "%SET-FILTER" '#:limn/ibuffer)))
           (when sym (funcall (symbol-function sym) "")))))

;; --- step 14: direct buffer/show back to PDF ---
;; v0.40: ibuffer no longer binds q; leaving ibuffer is done by RET on a
;; row or M-x switch-to-buffer, both of which invoke buffer/show.  Mimic
;; that here to verify the wire round-trip + sync-shim still leaves the
;; system in the expected state.
(%step 14 "buffer/show b1 (simulate leaving ibuffer)"
       (lambda ()
         (limn:call "buffer/show" :|buffer-id| "b1" :|win-id| "w1")))

(format t "~%━━━ DONE ━━━~%")
(finish-output)
(sleep 0.5)
(sb-ext:exit)
