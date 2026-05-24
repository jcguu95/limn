;;;; v0.35 §B — auto-revert-mode RED tests (~26 tests)
;;;;
;;;; 覆蓋（SPEC v0.35 §B）：
;;;;   limn/auto-revert :
;;;;     auto-revert-mode                 ; toggle on current buffer
;;;;     global-auto-revert-mode          ; toggle on all file-backed buffers
;;;;     auto-revert-tail-mode            ; append-only, cursor follows tail
;;;;     *auto-revert-interval*           ; polling fallback period (s)
;;;;     *auto-revert-stop-on-user-input* ; like Emacs (optional)
;;;;     tick                             ; interval helper (for testing)
;;;;     reset-auto-revert                ; test cleanup
;;;;
;;;; Vtable（unit tests mock everything）：
;;;;     *file-notify-add-fn*       ; default: limn/file-notify:file-notify-add-watch
;;;;     *file-notify-rm-fn*
;;;;     *revert-buffer-fn*         ; default: limn/file:revert-buffer
;;;;     *buffer-modified-p-fn*
;;;;     *visited-file-name-fn*
;;;;     *buffer-list-fn*
;;;;     *buffer-text-fn*           ; for tail mode point-max
;;;;     *cursor-set-fn*            ; for tail mode
;;;;     *message-fn*               ; for "buffer modified, refusing to revert"
;;;;
;;;; 全部 RED — limn-auto-revert.lisp 尚未實作。

;; ── package stub ─────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/auto-revert)
    (make-package '#:limn/auto-revert :use '(#:cl)))
  (dolist (sym '("AUTO-REVERT-MODE"
                 "GLOBAL-AUTO-REVERT-MODE"
                 "AUTO-REVERT-TAIL-MODE"
                 "AUTO-REVERT-ENABLED-P"
                 "*AUTO-REVERT-INTERVAL*"
                 "*AUTO-REVERT-STOP-ON-USER-INPUT*"
                 "TICK"
                 "RESET-AUTO-REVERT"
                 ;; vtable
                 "*FILE-NOTIFY-ADD-FN*"
                 "*FILE-NOTIFY-RM-FN*"
                 "*REVERT-BUFFER-FN*"
                 "*BUFFER-MODIFIED-P-FN*"
                 "*VISITED-FILE-NAME-FN*"
                 "*BUFFER-LIST-FN*"
                 "*BUFFER-TEXT-FN*"
                 "*CURSOR-SET-FN*"
                 "*MESSAGE-FN*"))
    (export (intern sym '#:limn/auto-revert) '#:limn/auto-revert)))

(in-package #:limn/unit-test)

;;; ── helpers ──────────────────────────────────────────────────────────────

(defmacro with-ar-pkg (&body body)
  `(let ((pkg (find-package '#:limn/auto-revert)))
     (if (null pkg)
         (format t "  (skipped: limn/auto-revert not loaded)~%")
         (progn ,@body))))

(defmacro with-clean-ar (&body body)
  `(with-ar-pkg
     (let ((reset (find-symbol "RESET-AUTO-REVERT" '#:limn/auto-revert)))
       (when reset (funcall reset))
       (unwind-protect (progn ,@body)
         (when reset (funcall reset))))))

;;; A miniature in-memory buffer registry used by all tests.
(defstruct fake-buf id path modified-p content (cursor 0))

(defvar *fakes* nil)

(defun %reset-fakes () (setf *fakes* nil))
(defun %add-fake (id &key path (modified-p nil) (content "") (cursor 0))
  (let ((b (make-fake-buf :id id :path path :modified-p modified-p
                          :content content :cursor cursor)))
    (push b *fakes*)
    b))

(defun %find-fake (id) (find id *fakes* :key #'fake-buf-id :test #'equal))

(defmacro with-fake-buffers ((&rest bufs) &body body)
  "BUFS = (id &key path modified-p content cursor)*. Installs the auto-revert
   vtable to read/write our fake registry, plus a mock file-notify that
   stores (path callback) pairs we can fire manually via FIRE-EVENT."
  (let ((bsyms '()))
    (dolist (b bufs) (push b bsyms))
    `(let ((*fakes* nil)
           (mock-watches '())  ; list of (path . callback)
           (revert-calls '())
           (rm-calls 0)
           (messages '()))
       (declare (ignorable mock-watches revert-calls rm-calls messages))
       ,@(loop for spec in bsyms
               collect `(%add-fake ,@spec))
       (let* ((pkg (find-package '#:limn/auto-revert))
              (vis-sym (find-symbol "*VISITED-FILE-NAME-FN*" pkg))
              (mod-sym (find-symbol "*BUFFER-MODIFIED-P-FN*" pkg))
              (bls-sym (find-symbol "*BUFFER-LIST-FN*" pkg))
              (txt-sym (find-symbol "*BUFFER-TEXT-FN*" pkg))
              (cur-sym (find-symbol "*CURSOR-SET-FN*" pkg))
              (msg-sym (find-symbol "*MESSAGE-FN*" pkg))
              (rev-sym (find-symbol "*REVERT-BUFFER-FN*" pkg))
              (add-sym (find-symbol "*FILE-NOTIFY-ADD-FN*" pkg))
              (rm-sym  (find-symbol "*FILE-NOTIFY-RM-FN*" pkg)))
         (progv (list vis-sym mod-sym bls-sym txt-sym cur-sym
                      msg-sym rev-sym add-sym rm-sym)
                (list
                  (lambda (id) (let ((b (%find-fake id)))
                                  (and b (fake-buf-path b))))
                  (lambda (id) (let ((b (%find-fake id)))
                                  (and b (fake-buf-modified-p b))))
                  (lambda () (mapcar #'fake-buf-id *fakes*))
                  (lambda (id) (let ((b (%find-fake id)))
                                  (and b (fake-buf-content b))))
                  (lambda (id pos)
                    (let ((b (%find-fake id)))
                      (when b (setf (fake-buf-cursor b) pos))))
                  (lambda (fmt &rest args)
                    (push (apply #'format nil fmt args) messages))
                  (lambda (id &key (confirm t))
                    (declare (ignore confirm))
                    (push id revert-calls)
                    id)
                  (lambda (path flags cb)
                    (declare (ignore flags))
                    (let ((d (cons path cb)))
                      (push d mock-watches)
                      d))
                  (lambda (desc)
                    (incf rm-calls)
                    (setf mock-watches (remove desc mock-watches :test #'eq))))
           (labels ((fire-event (path action)
                      (dolist (w mock-watches)
                        (when (equal (car w) path)
                          (funcall (cdr w)
                                   (list :descriptor w :action action
                                         :file path))))))
             (declare (ignorable (function fire-event)))
             ,@body))))))

;;; ─── B1. mode toggle ────────────────────────────────────────────────────

(deftest auto-revert-b1-mode-toggles
  (with-clean-ar
    (with-fake-buffers (("b1" :path "/tmp/b1.txt"))
      (assert-false (limn/auto-revert:auto-revert-enabled-p "b1"))
      (limn/auto-revert:auto-revert-mode "b1")
      (assert-true (limn/auto-revert:auto-revert-enabled-p "b1"))
      (limn/auto-revert:auto-revert-mode "b1")
      (assert-false (limn/auto-revert:auto-revert-enabled-p "b1")))))

(deftest auto-revert-b1-enable-adds-watch
  "Enabling auto-revert installs a file-notify watch."
  (with-clean-ar
    (with-fake-buffers (("b1" :path "/tmp/b1.txt"))
      (limn/auto-revert:auto-revert-mode "b1")
      (assert-eql 1 (length mock-watches))
      (assert-equal "/tmp/b1.txt" (car (first mock-watches))))))

(deftest auto-revert-b1-disable-rm-watch
  (with-clean-ar
    (with-fake-buffers (("b1" :path "/tmp/b1.txt"))
      (limn/auto-revert:auto-revert-mode "b1")
      (limn/auto-revert:auto-revert-mode "b1")  ; toggle off
      (assert-eql 1 rm-calls "rm called once")
      (assert-eql 0 (length mock-watches)))))

;;; ─── B2. clean buffer → auto revert ─────────────────────────────────────

(deftest auto-revert-b2-clean-buffer-reverts-on-modify
  (with-clean-ar
    (with-fake-buffers (("c1" :path "/tmp/c1.txt" :modified-p nil))
      (limn/auto-revert:auto-revert-mode "c1")
      (fire-event "/tmp/c1.txt" :modified)
      (assert-equal '("c1") revert-calls))))

(deftest auto-revert-b2-revert-called-with-confirm-nil
  "Auto-revert is non-interactive: must pass :confirm nil so it doesn't prompt."
  (with-clean-ar
    (with-fake-buffers (("c1" :path "/tmp/c1.txt"))
      (let* ((pkg (find-package '#:limn/auto-revert))
             (rev-sym (find-symbol "*REVERT-BUFFER-FN*" pkg))
             (captured nil))
        (progv (list rev-sym)
               (list (lambda (id &key (confirm t))
                       (setf captured (list :id id :confirm confirm))))
          (limn/auto-revert:auto-revert-mode "c1")
          (fire-event "/tmp/c1.txt" :modified)
          (assert-equal "c1" (getf captured :id))
          (assert-false (getf captured :confirm)))))))

;;; ─── B3. modified buffer → refuse + message ────────────────────────────

(deftest auto-revert-b3-modified-buffer-not-reverted
  (with-clean-ar
    (with-fake-buffers (("m1" :path "/tmp/m1.txt" :modified-p t))
      (limn/auto-revert:auto-revert-mode "m1")
      (fire-event "/tmp/m1.txt" :modified)
      (assert-eql 0 (length revert-calls)
                  "no revert when buffer is modified"))))

(deftest auto-revert-b3-modified-buffer-emits-warning
  (with-clean-ar
    (with-fake-buffers (("m1" :path "/tmp/m1.txt" :modified-p t))
      (limn/auto-revert:auto-revert-mode "m1")
      (fire-event "/tmp/m1.txt" :modified)
      (assert-true (some (lambda (m) (search "m1" m)) messages)
                   "warning message mentions buffer"))))

;;; ─── B4. global-auto-revert-mode ────────────────────────────────────────

(deftest auto-revert-b4-global-enables-on-all-file-buffers
  (with-clean-ar
    (with-fake-buffers (("g1" :path "/tmp/g1")
                        ("g2" :path "/tmp/g2")
                        ("g3" :path nil))    ; not file-backed
      (limn/auto-revert:global-auto-revert-mode 1)
      (assert-true  (limn/auto-revert:auto-revert-enabled-p "g1"))
      (assert-true  (limn/auto-revert:auto-revert-enabled-p "g2"))
      (assert-false (limn/auto-revert:auto-revert-enabled-p "g3")))))

(deftest auto-revert-b4-global-installs-watches
  (with-clean-ar
    (with-fake-buffers (("g1" :path "/tmp/g1")
                        ("g2" :path "/tmp/g2"))
      (limn/auto-revert:global-auto-revert-mode 1)
      (assert-eql 2 (length mock-watches)))))

(deftest auto-revert-b4-global-off-disables-all
  (with-clean-ar
    (with-fake-buffers (("g1" :path "/tmp/g1")
                        ("g2" :path "/tmp/g2"))
      (limn/auto-revert:global-auto-revert-mode 1)
      (limn/auto-revert:global-auto-revert-mode -1)
      (assert-false (limn/auto-revert:auto-revert-enabled-p "g1"))
      (assert-false (limn/auto-revert:auto-revert-enabled-p "g2")))))

;;; ─── B5. tail mode ──────────────────────────────────────────────────────

(deftest auto-revert-b5-tail-mode-enables-flag
  (with-clean-ar
    (with-fake-buffers (("t1" :path "/tmp/log.txt"))
      (limn/auto-revert:auto-revert-tail-mode "t1")
      (assert-true (limn/auto-revert:auto-revert-enabled-p "t1")))))

(deftest auto-revert-b5-tail-moves-cursor-to-end
  "After tail revert, cursor should be at point-max (= length of content)."
  (with-clean-ar
    (with-fake-buffers (("t1" :path "/tmp/log.txt"
                         :content "line1" :cursor 0))
      (limn/auto-revert:auto-revert-tail-mode "t1")
      ;; Simulate the file growing: revert-fn updates content, then
      ;; tail-mode should set cursor to (length content).
      (let* ((pkg (find-package '#:limn/auto-revert))
             (rev-sym (find-symbol "*REVERT-BUFFER-FN*" pkg)))
        (progv (list rev-sym)
               (list (lambda (id &key confirm)
                       (declare (ignore confirm))
                       (let ((b (%find-fake id)))
                         (when b (setf (fake-buf-content b)
                                       "line1
line2 appended")))))
          (fire-event "/tmp/log.txt" :modified)
          (let ((b (%find-fake "t1")))
            (assert-eql (length (fake-buf-content b))
                        (fake-buf-cursor b)
                        "cursor moved to point-max")))))))

;;; ─── B6. unsubscribe on close ───────────────────────────────────────────

(deftest auto-revert-b6-buffer-removal-rms-watch
  "If a buffer disappears from buffer-list-fn, its watch should be cleaned
   up on the next tick (or on explicit close)."
  (with-clean-ar
    (with-fake-buffers (("c1" :path "/tmp/c1"))
      (limn/auto-revert:auto-revert-mode "c1")
      (setf *fakes* nil)   ; "close" the buffer
      (limn/auto-revert:tick)
      (assert-true (>= rm-calls 1) "rm-watch fired on tick after close"))))

;;; ─── B7. interval / polling-tick fallback ───────────────────────────────

(deftest auto-revert-b7-default-interval-is-5s
  (with-clean-ar
    (assert-eql 5 limn/auto-revert:*auto-revert-interval*)))

(deftest auto-revert-b7-tick-reverts-clean-buffer
  "tick is the interval helper; with no file-notify it just walks the
   enabled-buffers list and reverts clean ones."
  (with-clean-ar
    (with-fake-buffers (("t1" :path "/tmp/t1" :modified-p nil))
      (limn/auto-revert:auto-revert-mode "t1")
      (limn/auto-revert:tick)
      (assert-eql 1 (length revert-calls)))))

(deftest auto-revert-b7-tick-skips-modified-buffer
  (with-clean-ar
    (with-fake-buffers (("t1" :path "/tmp/t1" :modified-p t))
      (limn/auto-revert:auto-revert-mode "t1")
      (limn/auto-revert:tick)
      (assert-eql 0 (length revert-calls)))))

;;; ─── B8. shared file → multiple buffers ─────────────────────────────────

(deftest auto-revert-b8-two-buffers-same-file-both-revert
  (with-clean-ar
    (with-fake-buffers (("b8a" :path "/tmp/shared")
                        ("b8b" :path "/tmp/shared"))
      (limn/auto-revert:auto-revert-mode "b8a")
      (limn/auto-revert:auto-revert-mode "b8b")
      (fire-event "/tmp/shared" :modified)
      (assert-eql 2 (length revert-calls)))))

;;; ─── B9. disable cleanup ────────────────────────────────────────────────

(deftest auto-revert-b9-disable-removes-from-enabled-set
  (with-clean-ar
    (with-fake-buffers (("d1" :path "/tmp/d1"))
      (limn/auto-revert:auto-revert-mode "d1")
      (assert-true (limn/auto-revert:auto-revert-enabled-p "d1"))
      (limn/auto-revert:auto-revert-mode "d1")
      (assert-false (limn/auto-revert:auto-revert-enabled-p "d1")))))

(deftest auto-revert-b9-disabled-event-is-noop
  "Events fired after disable do not revert."
  (with-clean-ar
    (with-fake-buffers (("d1" :path "/tmp/d1"))
      (limn/auto-revert:auto-revert-mode "d1")
      (limn/auto-revert:auto-revert-mode "d1")
      (fire-event "/tmp/d1" :modified)
      (assert-eql 0 (length revert-calls)))))

;;; ─── B10. action filtering ──────────────────────────────────────────────

(deftest auto-revert-b10-only-modify-and-attrib-trigger-revert
  "Pure :created or :deleted events should NOT trigger revert."
  (with-clean-ar
    (with-fake-buffers (("f1" :path "/tmp/f1"))
      (limn/auto-revert:auto-revert-mode "f1")
      (fire-event "/tmp/f1" :created)
      (fire-event "/tmp/f1" :deleted)
      (assert-eql 0 (length revert-calls)))))

(deftest auto-revert-b10-modify-and-attrib-do-trigger
  (with-clean-ar
    (with-fake-buffers (("f1" :path "/tmp/f1"))
      (limn/auto-revert:auto-revert-mode "f1")
      (fire-event "/tmp/f1" :modified)
      (fire-event "/tmp/f1" :attribute-changed)
      (assert-true (>= (length revert-calls) 1)))))

;;; ─── B11. extra extrapolation ───────────────────────────────────────────

(deftest auto-revert-b11-no-file-backing-cannot-enable
  "Buffers without a visited file cannot be auto-reverted."
  (with-clean-ar
    (with-fake-buffers (("n1" :path nil))
      (assert-error error
        (limn/auto-revert:auto-revert-mode "n1")))))

(deftest auto-revert-b11-double-enable-is-idempotent
  "Enabling twice does not install two watches."
  (with-clean-ar
    (with-fake-buffers (("i1" :path "/tmp/i1"))
      (limn/auto-revert:auto-revert-mode "i1")
      (limn/auto-revert:auto-revert-mode "i1")
      (limn/auto-revert:auto-revert-mode "i1")
      ;; After odd count it should be on with exactly 1 watch
      (assert-true (limn/auto-revert:auto-revert-enabled-p "i1"))
      (assert-eql 1 (length mock-watches)))))

(deftest auto-revert-b11-revert-error-does-not-leave-watch-broken
  "If revert-fn signals, subsequent events still get delivered."
  (with-clean-ar
    (with-fake-buffers (("e1" :path "/tmp/e1"))
      (let* ((pkg (find-package '#:limn/auto-revert))
             (rev-sym (find-symbol "*REVERT-BUFFER-FN*" pkg))
             (n 0))
        (progv (list rev-sym)
               (list (lambda (id &key confirm)
                       (declare (ignore id confirm))
                       (incf n)
                       (when (= n 1) (error "first revert boom"))))
          (limn/auto-revert:auto-revert-mode "e1")
          (assert-no-error (fire-event "/tmp/e1" :modified))
          (assert-no-error (fire-event "/tmp/e1" :modified))
          (assert-eql 2 n "both revert attempts ran"))))))
