;;;; narrow-walkthrough.lisp — interactive v0.40 narrow/widen demo.
;;;;
;;;; Usage:
;;;;   # one-off setup (export so the run-repl.sh subprocess sees it):
;;;;   export LIMN_BIN=/Users/jin/data/local/projects/sioyek-core/sioyek/limn.app/Contents/MacOS/limn
;;;;   HEADLESS=0 backend/run-repl.sh
;;;;
;;;;   ;; at the SBCL prompt:
;;;;   (load "scratch/narrow-walkthrough.lisp")
;;;;
;;;; Each step injects forms, prints what you should see in the Qt
;;;; window, and asks y to continue, n to stop.  Watch the Qt window
;;;; for cursor position, modeline label (bottom-left), and any dim
;;;; overlay covering the inaccessible portion of the buffer.
;;;;
;;;; All forms run in :CL-USER so you can copy-paste any chunk
;;;; afterwards into the prompt to re-run it.

(in-package #:cl-user)

(defparameter *narrow-demo-path* "/tmp/narrow-demo.txt")

(defparameter *narrow-demo-content*
  "0123456789abcdefghijklmnopqrstuvwxyz
(defun foo () 1)
(defun bar () 2)
(defun baz () 3)
")

(defvar *narrow-demo-buf* nil)

(defparameter *narrow-walk-total* 8)

(defun %narrow-expect (msg)
  (terpri)
  (write-string "  ┌─ expect ─────────────────────────────────────────")
  (terpri)
  (with-input-from-string (in msg)
    (loop for line = (read-line in nil) while line
          do (format t "  │ ~a~%" line)))
  (write-string "  └──────────────────────────────────────────────────")
  (terpri)
  (force-output)
  (y-or-n-p "  match? "))

(defmacro %narrow-step (n title body expect)
  `(progn
     (format t "~&~%━━ step ~a/~a — ~a ━━~%"
             ,n *narrow-walk-total* ,title)
     ,body
     (unless (%narrow-expect ,expect)
       (format t "~&  ✗ stopped at step ~a.~%" ,n)
       (return-from narrow-walkthrough nil))))

(defun narrow-walkthrough ()
  (block narrow-walkthrough
    ;; ── prep: write the demo file ──────────────────────────────────────
    (with-open-file (s *narrow-demo-path* :direction :output
                                          :if-exists :supersede
                                          :if-does-not-exist :create)
      (write-string *narrow-demo-content* s))

    (%narrow-step 1 "open a text buffer with the demo file"
       (let* ((r   (limn:call "bridge/engine-load"
                              :|win-id| "w1"
                              :|engine| "text" :|path| ""))
              (buf (getf (getf r :|data|) :|buffer-id|)))
         (limn:call "buffer/load-file"
                    :|buffer-id| buf :|path| *narrow-demo-path*)
         (setf limn/text:*current-text-buffer* buf
               *narrow-demo-buf* buf)
         (let ((mb-fn (find-symbol "MODE-BUFFER-FOR-WINDOW" :limn/runtime)))
           (when (and mb-fn (fboundp mb-fn))
             (let ((mb (funcall mb-fn "w1")))
               (when mb (limn/mode:activate mb 'text-mode)))))
         ;; push initial modeline label
         (limn/text:text-mode-update-modeline :buffer-id buf
                                              :path *narrow-demo-path*)
         (format t "  buf = ~s~%" buf))
       "Qt window shows the demo text:
    0123456789abcdefghijklmnopqrstuvwxyz
    (defun foo () 1)
    (defun bar () 2)
    (defun baz () 3)
Modeline (bottom-left) reads: \"Text: narrow-demo.txt\".
There is NO \"Narrow\" suffix yet.")

    (%narrow-step 2 "place cursor at 5, push mark, move cursor to 15"
       (let ((buf *narrow-demo-buf*))
         (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 5)
         (limn/mark:set-mark 5 buf)
         (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 15)
         (format t "  cursor=~s   mark=~s~%"
                 (getf (getf (limn:call "buffer/cursor-get"
                                         :|buffer-id| buf)
                              :|data|) :|offset|)
                 (limn/mark:mark buf)))
       "cursor=15 and mark=5 printed above.
In the Qt window the cursor sits between '4' and '5' visually (offset 15).")

    (%narrow-step 3 "C-x n n  →  narrow-to-region [5, 15)"
       (limn/cmd:call-interactively
        (find-symbol "NARROW-TO-REGION" :cl-user))
       "Modeline now reads: \"Text: narrow-demo.txt   Narrow\".
The chars '01234' (before pos 5) and 'fghij...' through
all three (defun ...) forms (from pos 15 onward) appear DIMMED.
The five chars '56789' in the middle are the only fully-bright text.")

    (%narrow-step 4 "M-> via direct call → cursor clamps to point-max = 15"
       (progn
         (limn/text-nav:end-of-buffer *narrow-demo-buf*)
         (format t "  cursor → ~s~%"
                 (getf (getf (limn:call "buffer/cursor-get"
                                         :|buffer-id| *narrow-demo-buf*)
                              :|data|) :|offset|)))
       "cursor printed as 15 (point-max), NOT the buffer's actual end.
In the Qt window the cursor sits at the right edge of the bright
strip, just before the dimmed 'fghij...' region.")

    (%narrow-step 5 "M-< via direct call → cursor clamps to point-min = 5"
       (progn
         (limn/text-nav:beginning-of-buffer *narrow-demo-buf*)
         (format t "  cursor → ~s~%"
                 (getf (getf (limn:call "buffer/cursor-get"
                                         :|buffer-id| *narrow-demo-buf*)
                              :|data|) :|offset|)))
       "cursor printed as 5 (point-min), NOT 0.
In the Qt window the cursor sits at the left edge of the bright strip,
just after the dimmed '01234'.")

    (%narrow-step 6 "C-x n w  →  widen"
       (limn/cmd:call-interactively
        (find-symbol "WIDEN" :cl-user))
       "Modeline drops \"Narrow\" — reads just \"Text: narrow-demo.txt\".
All dim overlays are gone; the whole buffer is bright again.")

    (%narrow-step 7 "C-x n d on (defun foo ...) — narrow-to-defun"
       (let* ((buf  *narrow-demo-buf*)
              (text (getf (getf (limn:call "buffer/text" :|buffer-id| buf)
                                 :|data|) :|text|))
              (idx  (search "(defun foo" text)))
         (limn:call "buffer/cursor-set"
                    :|buffer-id| buf :|offset| (+ idx 5))
         (limn/cmd:call-interactively
          (find-symbol "NARROW-TO-DEFUN" :cl-user))
         (format t "  narrowed → [~s, ~s)~%"
                 (limn/excursion:point-min-of buf)
                 (limn/excursion:point-max-of buf)))
       "Bounds printed cover exactly \"(defun foo () 1)\".
Modeline shows \"Narrow\".  In the Qt window only that single
defun line is bright; the header alphabet line and the other two
defuns are dimmed.")

    (%narrow-step 8 "widen + done"
       (limn/cmd:call-interactively
        (find-symbol "WIDEN" :cl-user))
       "Modeline + dim overlays cleared.  Buffer fully accessible.")

    (format t "~&~%━━ done — narrow/widen walkthrough complete. ━━~%")
    t))

;; Run automatically when the file is loaded.
(narrow-walkthrough)
