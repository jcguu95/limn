;;;; v0.37 "bookmark everywhere" — OS-tier integration driver.
;;;;
;;;; Spawns a real Limn binary, drives the new limn/bookmark module via
;;;; limn:call (so the wire round-trips actually fire), and asserts that
;;;; the user-visible round-trip works:
;;;;
;;;;   Ω1 handlers installed (text/org/pdf via cl-user:: symbols)
;;;;   Ω2 PDF: open fixture → default-pdf-record returns expected shape
;;;;   Ω3 PDF: jump to a different page, then default-pdf-jump on the
;;;;          recorded plist returns us to the original page
;;;;   Ω4 Text: open a tmp text file, set cursor, default-text-record
;;;;          returns :file + :position; jump round-trips
;;;;   Ω5 Persistence: bookmarks-save → clear → bookmarks-load → entries
;;;;          come back with handlers intact
;;;;   Ω6 M-x dispatch path: cl-user::bookmark-set + cl-user::bookmark-
;;;;          jump callable via call-interactively (mocked minibuffer)
;;;;
;;;; No Xvfb / xdotool needed — pure wire.  (PDF visual checks belong
;;;; in a separate driver; we exercise the data path only.)

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))

(defun b/ (f) (concatenate 'string *bdir* f))

;; Stash any local init.lisp so the driver runs against a vanilla
;; backend.  Same convention as batch-os-v024-mark.lisp.
(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v037bm"))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(format t "~%=== batch-os-v037-bookmark ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v037bm-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v037bm.log"
              :if-output-exists :supersede :error :output))
       (fixture-pdf
        (or (sb-posix:getenv "LIMN_FIXTURE")
            (namestring (merge-pathnames "tests/fixtures/test.pdf"
                                          (pathname *bdir*)))))
       (tmp-txt (format nil "/tmp/limn-v037bm-~a.txt" (sb-posix:getpid)))
       (tmp-side (format nil "/tmp/limn-v037bm-side-~a.lisp"
                          (sb-posix:getpid))))
  (with-open-file (out tmp-txt :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create)
    (write-sequence "hello bookmark world" out))

  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  (unwind-protect
   (progn

    ;;; ── Ω1: handlers registered for all three modes ─────────────────
    (format t "~%── Ω1: handlers registered ──~%")
    (limn/bookmark-handlers:install)
    (dolist (m '("TEXT-MODE" "ORG-MODE" "PDF-MODE"))
      (let ((sym (find-symbol m :cl-user)))
        (check (format nil "Ω1 handler registered for ~a" m)
               (and sym (limn/bookmark:handler-registered-p sym)))))

    ;;; ── Ω2: PDF default-pdf-record returns expected shape ───────────
    (format t "~%── Ω2: pdf-record shape ──~%")
    (let* ((r (limn:call "bridge/engine-load"
                          :|win-id| "w1"
                          :|engine| "mupdf"
                          :|path|   fixture-pdf))
           (bid (and (ok? r) (getf (data r) :|buffer-id|))))
      (check "Ω2a engine-load mupdf returned buffer-id"
             (and bid (stringp bid)))
      (when bid
        ;; pdf-mode-on-buffer-opened populates *buffer-id-to-path*;
        ;; in test-mode it may not fire automatically, so set it
        ;; ourselves to mirror what runtime would do.
        (setf (gethash bid limn/pdf-mode::*buffer-id-to-path*)
              fixture-pdf)
        ;; Park on a non-zero page so the record is interesting.
        (limn:call "view/set" :|win-id| "w1" :|page| 2)
        (sleep 0.05)
        (let ((rec (limn/bookmark-handlers:default-pdf-record)))
          (check "Ω2b record :path matches fixture"
                 (equal (getf rec :path) fixture-pdf)
                 (format nil "got ~s" rec))
          (check "Ω2c record :page = 2"
                 (equal (getf rec :page) 2)
                 (format nil "got ~s" (getf rec :page)))
          (check "Ω2d record has :y-offset"
                 (numberp (getf rec :y-offset))))

        ;;; ── Ω3: jump round-trip ───────────────────────────────────
        (format t "~%── Ω3: pdf jump round-trip ──~%")
        (let ((saved-rec (limn/bookmark-handlers:default-pdf-record)))
          ;; Wander off.
          (limn:call "view/set" :|win-id| "w1" :|page| 0)
          (sleep 0.05)
          ;; And come back via the handler.
          (limn/bookmark-handlers:default-pdf-jump saved-rec)
          (sleep 0.05)
          (let* ((v   (data (limn:call "view/get" :|win-id| "w1")))
                 (now (getf v :|page|)))
            (check (format nil "Ω3 page restored to 2 (got ~a)" now)
                   (equal now 2))))

        ;;; ── Ω5 (early): cl-user::bookmark-set via call-interactively
        (format t "~%── Ω6: M-x bookmark-set via mocked minibuffer ──~%")
        (let ((limn/cmd:*minibuffer-read*
               (lambda (prompt)
                 (declare (ignore prompt))
                 "mxset")))
          ;; Make sure focus-mode resolution picks pdf-mode.  Test-mode
          ;; doesn't always auto-register the mode-buffer; do it manually.
          (let ((mb (limn/mode:make-mode-buffer))
                (pm (find-symbol "PDF-MODE" :cl-user)))
            (when (limn/mode:find-mode pm)
              (limn/mode:activate mb pm))
            (limn/runtime:register-mode-buffer bid mb)
            (limn/runtime:set-window-active-buffer "w1" bid)
            (limn/bookmark:bookmark-clear)
            (limn/cmd:call-interactively
             (find-symbol "BOOKMARK-SET" :cl-user))
            (let ((b (limn/bookmark:bookmark-find "mxset")))
              (check "Ω6a bookmark-set added 'mxset'" b)
              (check "Ω6b handler = pdf-mode"
                     (and b (eq (limn/bookmark:bookmark-handler b) pm)))
              (check "Ω6c record carries page"
                     (and b (integerp
                             (getf (limn/bookmark:bookmark-record b)
                                   :page)))))))
        (ignore-errors (limn:call "buffer/close" :|buffer-id| bid))))

    ;;; ── Ω4: text record + jump round-trip ───────────────────────────
    (format t "~%── Ω4: text record + jump ──~%")
    ;; find-file from Lisp side opens (or re-opens) the file; the wire
    ;; side gets text-engine via *open-text-engine-fn* hook installed
    ;; by limn.lisp's bootstrap.
    (let ((fbuf (limn/file:find-file tmp-txt)))
      (sleep 0.1)
      (let ((wire (limn/file:buffer-wire-id fbuf)))
        ;; Move cursor inside the buffer, then capture the record.
        (when wire
          (limn:call "buffer/cursor-set"
                      :|buffer-id| wire :|offset| 11))
        (sleep 0.05)
        (let ((rec (limn/bookmark-handlers:default-text-record)))
          (check "Ω4a text-record :file = tmp-txt"
                 (equal (getf rec :file) tmp-txt)
                 (format nil "got ~s" rec))
          (check "Ω4b text-record :position reflects cursor"
                 (equal (getf rec :position) 11)))
        ;; Jump back to position 0 via a freshly-built record.
        (let ((rec-zero (list :file tmp-txt :position 0)))
          (limn/bookmark-handlers:default-text-jump rec-zero)
          (sleep 0.05)
          (when wire
            (let* ((d (data (limn:call "buffer/cursor-get"
                                        :|buffer-id| wire)))
                   (off (getf d :|offset|)))
              (check (format nil "Ω4c text jump moved cursor to 0 (got ~a)"
                             off)
                     (equal off 0)))))))

    ;;; ── Ω5: persistence round-trip ──────────────────────────────────
    (format t "~%── Ω5: save → clear → load → handler still wired ──~%")
    (limn/bookmark:bookmark-clear)
    (limn/bookmark:bookmark-add
     (limn/bookmark:make-bookmark
      :name "ω5"
      :handler (find-symbol "PDF-MODE" :cl-user)
      :record (list :path fixture-pdf :page 1
                    :y-offset 0.0 :x-offset 0.0)))
    (limn/bookmark:bookmarks-save tmp-side)
    (check "Ω5a sidecar file exists" (probe-file tmp-side))
    (limn/bookmark:bookmark-clear)
    (check "Ω5b store empty after clear"
           (zerop (limn/bookmark:bookmark-count)))
    (limn/bookmark:bookmarks-load tmp-side)
    (let ((b (limn/bookmark:bookmark-find "ω5")))
      (check "Ω5c CJK name round-tripped" b)
      (check "Ω5d handler still pdf-mode"
             (and b (eq (limn/bookmark:bookmark-handler b)
                        (find-symbol "PDF-MODE" :cl-user))))
      (check "Ω5e record :page preserved"
             (and b (equal (getf (limn/bookmark:bookmark-record b) :page)
                           1)))))

   ;; cleanup
   (ignore-errors (delete-file tmp-txt))
   (ignore-errors (delete-file tmp-side))
   (ignore-errors (limn:stop))
   (sleep 0.1)
   (handler-case (sb-ext:process-kill proc 15) (error () nil))
   (handler-case (sb-ext:process-wait proc) (error () nil))))

(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failure(s))~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
