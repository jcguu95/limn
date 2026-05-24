;;;; v0.23 §D — buffer-undo RED tests (Lisp unit only)
;;;;
;;;; ~30 tests. New package limn/buffer-undo distinct from existing
;;;; limn/undo (tree primitive shipped in v0.6). buffer-undo is the
;;;; user-facing undo system bound to event/buffer-modified.
;;;;
;;;; Qt-tier (D8 — real C++ event emit) lives in suites/, not here.
;;;; OS-tier (D9 — real text buffer round-trip) lives in e2e/.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/buffer-undo)
    (make-package '#:limn/buffer-undo :use '(#:cl)))
  (dolist (sym '("ENABLE-UNDO" "DISABLE-UNDO" "UNDO-DISABLED-P"
                 "UNDO" "REDO"
                 "UNDO-BOUNDARY"
                 "BUFFER-UNDO-LIST"
                 "CLEAR-UNDO"
                 "*BEFORE-UNDO-HOOK*" "*AFTER-UNDO-HOOK*"
                 "BUFFER-BRANCHES" "SWITCH-BRANCH"
                 "BUFFER-CURRENT-BRANCH-ID"
                 "SERIALIZE-UNDO" "DESERIALIZE-UNDO"
                 "INSTALL-BUFFER-MODIFIED-HANDLER"))
    (let ((s (intern sym '#:limn/buffer-undo)))
      (export s '#:limn/buffer-undo))))

(in-package #:limn/unit-test)

(use-package '#:limn/v023-helpers)

;;; Each test uses a fresh mock buffer with undo enabled.
(defmacro with-fresh-buffer ((buf-var &key (id "u")) &body body)
  `(let ((,buf-var (make-mock-buffer :id ,id)))
     (limn/buffer-undo:install-buffer-modified-handler)
     (install-mock-inverse-handler)
     (register-mock-buffer ,buf-var)
     (limn/buffer-undo:enable-undo ,id)
     (unwind-protect (progn ,@body)
       (limn/buffer-undo:clear-undo ,id)
       (unregister-mock-buffer ,id))))

;;; ─── D1. Insert undo ──────────────────────────────────────────────

(deftest undo-d1-insert-then-undo-empties
  (with-fresh-buffer (b)
    (mock-insert b 0 "hello")
    (limn/buffer-undo:undo "u")
    (assert-equal "" (mock-buffer-text b))))

(deftest undo-d1-insert-undo-redo-roundtrip
  (with-fresh-buffer (b)
    (mock-insert b 0 "hello")
    (limn/buffer-undo:undo "u")
    (limn/buffer-undo:redo "u")
    (assert-equal "hello" (mock-buffer-text b))))

(deftest undo-d1-multiple-inserts-one-undo-per-boundary
  (with-fresh-buffer (b)
    (mock-insert b 0 "a")
    (limn/buffer-undo:undo-boundary "u")
    (mock-insert b 1 "b")
    (limn/buffer-undo:undo-boundary "u")
    (mock-insert b 2 "c")
    (assert-equal "abc" (mock-buffer-text b))
    (limn/buffer-undo:undo "u")
    (assert-equal "ab" (mock-buffer-text b))
    (limn/buffer-undo:undo "u")
    (assert-equal "a" (mock-buffer-text b))))

(deftest undo-d1-without-boundary-collapses-into-one-step
  (with-fresh-buffer (b)
    (mock-insert b 0 "a")
    (mock-insert b 1 "b")
    (mock-insert b 2 "c")
    (limn/buffer-undo:undo "u")
    (assert-equal "" (mock-buffer-text b))))

(deftest undo-d1-disabled-then-enabled-loses-prior
  (with-fresh-buffer (b)
    (mock-insert b 0 "before")
    (limn/buffer-undo:disable-undo "u")
    (limn/buffer-undo:enable-undo "u")
    (mock-insert b 6 "after")
    (limn/buffer-undo:undo "u")
    (assert-equal "before" (mock-buffer-text b))))

;;; ─── D2. Delete undo ──────────────────────────────────────────────

(deftest undo-d2-delete-undo-restores-text-and-position
  (with-fresh-buffer (b)
    (mock-insert b 0 "abcdef")
    (limn/buffer-undo:undo-boundary "u")
    (mock-delete b 2 2)               ; remove "cd"
    (assert-equal "abef" (mock-buffer-text b))
    (limn/buffer-undo:undo "u")
    (assert-equal "abcdef" (mock-buffer-text b))))

(deftest undo-d2-multiple-deletes-stepwise-undo
  (with-fresh-buffer (b)
    (mock-insert b 0 "abcdef")
    (limn/buffer-undo:undo-boundary "u")
    (mock-delete b 5 1) (limn/buffer-undo:undo-boundary "u")
    (mock-delete b 4 1) (limn/buffer-undo:undo-boundary "u")
    (mock-delete b 3 1)
    (assert-equal "abc" (mock-buffer-text b))
    (limn/buffer-undo:undo "u") (assert-equal "abcd"   (mock-buffer-text b))
    (limn/buffer-undo:undo "u") (assert-equal "abcde"  (mock-buffer-text b))
    (limn/buffer-undo:undo "u") (assert-equal "abcdef" (mock-buffer-text b))))

(deftest undo-d2-mixed-delete-then-insert
  (with-fresh-buffer (b)
    (mock-insert b 0 "abc")           ; "abc"
    (limn/buffer-undo:undo-boundary "u")
    (mock-delete b 0 1)               ; "bc"
    (limn/buffer-undo:undo-boundary "u")
    (mock-insert b 0 "X")             ; "Xbc"
    (limn/buffer-undo:undo "u") (assert-equal "bc"  (mock-buffer-text b))
    (limn/buffer-undo:undo "u") (assert-equal "abc" (mock-buffer-text b))))

(deftest undo-d2-delete-on-empty-noop
  (with-fresh-buffer (b)
    (let ((before-len (length (limn/buffer-undo:buffer-undo-list "u"))))
      ;; mock-delete on empty raises; tolerate either ignore or skip.
      (handler-case (mock-delete b 0 0) (error () nil))
      (assert-eql before-len
                  (length (limn/buffer-undo:buffer-undo-list "u"))))))

;;; ─── D3. Replace undo ─────────────────────────────────────────────

(deftest undo-d3-replace-atomic-single-step
  (with-fresh-buffer (b)
    (mock-insert b 0 "hello world")
    (limn/buffer-undo:undo-boundary "u")
    (mock-replace b 6 5 "lispers")    ; world → lispers
    (assert-equal "hello lispers" (mock-buffer-text b))
    (limn/buffer-undo:undo "u")
    (assert-equal "hello world" (mock-buffer-text b))))

(deftest undo-d3-replace-zero-old-equals-insert
  (with-fresh-buffer (b)
    (mock-insert b 0 "ac")
    (limn/buffer-undo:undo-boundary "u")
    (mock-replace b 1 0 "b")          ; insert "b" at pos 1
    (assert-equal "abc" (mock-buffer-text b))
    (limn/buffer-undo:undo "u")
    (assert-equal "ac" (mock-buffer-text b))))

(deftest undo-d3-replace-empty-new-equals-delete
  (with-fresh-buffer (b)
    (mock-insert b 0 "abc")
    (limn/buffer-undo:undo-boundary "u")
    (mock-replace b 1 1 "")           ; delete "b"
    (assert-equal "ac" (mock-buffer-text b))
    (limn/buffer-undo:undo "u")
    (assert-equal "abc" (mock-buffer-text b))))

;;; ─── D4. Branching / undo-tree ────────────────────────────────────

(deftest undo-d4-undo-then-new-insert-keeps-old-branch
  (with-fresh-buffer (b)
    (mock-insert b 0 "A") (limn/buffer-undo:undo-boundary "u")
    (mock-insert b 1 "B") (limn/buffer-undo:undo-boundary "u")
    (limn/buffer-undo:undo "u")        ; back to "A"
    (mock-insert b 1 "C")              ; new branch
    (assert-true (>= (length (limn/buffer-undo:buffer-branches "u")) 2))))

(deftest undo-d4-switch-branch-changes-redo-target
  (with-fresh-buffer (b)
    (mock-insert b 0 "A") (limn/buffer-undo:undo-boundary "u")
    (mock-insert b 1 "B") (limn/buffer-undo:undo-boundary "u")
    (limn/buffer-undo:undo "u")
    (mock-insert b 1 "C")
    (limn/buffer-undo:undo "u")
    (limn/buffer-undo:switch-branch "u" :next)
    (limn/buffer-undo:redo "u")
    ;; Either AB or AC depending on which branch we switched to;
    ;; the contract is only "switch-branch picks a different
    ;; reachable future".
    (let ((txt (mock-buffer-text b)))
      (assert-true (or (equal txt "AB") (equal txt "AC"))))))

(deftest undo-d4-many-branches-no-degrade
  (with-fresh-buffer (b)
    (with-timeout-bound 2
      (mock-insert b 0 "root") (limn/buffer-undo:undo-boundary "u")
      (loop repeat 100 do
        (mock-insert b 4 "x") (limn/buffer-undo:undo-boundary "u")
        (limn/buffer-undo:undo "u")))
    (assert-true (>= (length (limn/buffer-undo:buffer-branches "u")) 10))))

(deftest undo-d4-branch-ids-unique
  (with-fresh-buffer (b)
    (mock-insert b 0 "A") (limn/buffer-undo:undo-boundary "u")
    (let ((seen (make-hash-table :test 'equal)))
      (loop repeat 10 do
        (limn/buffer-undo:undo "u")
        (mock-insert b 0 "x")
        (limn/buffer-undo:undo-boundary "u")
        (let ((id (limn/buffer-undo:buffer-current-branch-id "u")))
          (assert-false (gethash id seen)
                        (format nil "branch id ~A repeated" id))
          (setf (gethash id seen) t))))))

(deftest undo-d4-each-branch-has-timestamp
  (with-fresh-buffer (b)
    (mock-insert b 0 "A") (limn/buffer-undo:undo-boundary "u")
    (mock-insert b 1 "B") (limn/buffer-undo:undo-boundary "u")
    (let ((branches (limn/buffer-undo:buffer-branches "u")))
      (assert-true (every (lambda (b) (getf b :timestamp)) branches)))))

(deftest undo-d4-serialize-roundtrip
  (with-fresh-buffer (b)
    (mock-insert b 0 "abc") (limn/buffer-undo:undo-boundary "u")
    (mock-insert b 3 "def") (limn/buffer-undo:undo-boundary "u")
    (let* ((blob (limn/buffer-undo:serialize-undo "u"))
           (count-before (length (limn/buffer-undo:buffer-undo-list "u"))))
      (limn/buffer-undo:clear-undo "u")
      (limn/buffer-undo:deserialize-undo "u" blob)
      (assert-eql count-before
                  (length (limn/buffer-undo:buffer-undo-list "u"))))))

;;; ─── D5. Multi-buffer isolation ────────────────────────────────────

(deftest undo-d5-undo-on-buf-a-does-not-touch-buf-b
  (let ((a (make-mock-buffer :id "A"))
        (b (make-mock-buffer :id "B")))
    (limn/buffer-undo:install-buffer-modified-handler)
    (install-mock-inverse-handler)
    (register-mock-buffer a) (register-mock-buffer b)
    (limn/buffer-undo:enable-undo "A")
    (limn/buffer-undo:enable-undo "B")
    (mock-insert a 0 "alpha")
    (mock-insert b 0 "beta")
    (limn/buffer-undo:undo "A")
    (assert-equal "" (mock-buffer-text a))
    (assert-equal "beta" (mock-buffer-text b))
    (limn/buffer-undo:clear-undo "A")
    (limn/buffer-undo:clear-undo "B")
    (unregister-mock-buffer "A") (unregister-mock-buffer "B")))

(deftest undo-d5-clear-undo-on-delete-buffer
  (mock-insert (make-mock-buffer :id "tmp") 0 "x")
  (limn/buffer-undo:clear-undo "tmp")
  (assert-true (or (null (limn/buffer-undo:buffer-undo-list "tmp"))
                   (zerop (length (limn/buffer-undo:buffer-undo-list "tmp"))))))

(deftest undo-d5-cross-buffer-ops-dont-bleed
  (let ((a (make-mock-buffer :id "A2"))
        (b (make-mock-buffer :id "B2")))
    (limn/buffer-undo:install-buffer-modified-handler)
    (install-mock-inverse-handler)
    (register-mock-buffer a) (register-mock-buffer b)
    (limn/buffer-undo:enable-undo "A2")
    (limn/buffer-undo:enable-undo "B2")
    (loop repeat 5 do
      (mock-insert a 0 "a")
      (mock-insert b 0 "b"))
    (assert-eql (length (limn/buffer-undo:buffer-undo-list "A2"))
                (length (limn/buffer-undo:buffer-undo-list "B2")))
    (limn/buffer-undo:clear-undo "A2")
    (limn/buffer-undo:clear-undo "B2")
    (unregister-mock-buffer "A2") (unregister-mock-buffer "B2")))

(deftest undo-d5-concurrent-buffers-no-deadlock
  (let ((a (make-mock-buffer :id "PA"))
        (b (make-mock-buffer :id "PB")))
    (limn/buffer-undo:install-buffer-modified-handler)
    (install-mock-inverse-handler)
    (register-mock-buffer a) (register-mock-buffer b)
    (limn/buffer-undo:enable-undo "PA")
    (limn/buffer-undo:enable-undo "PB")
    (with-timeout-bound 2
      (let ((ta (sb-thread:make-thread
                 (lambda ()
                   (handler-case
                       (dotimes (_ 50) (mock-insert a 0 "x"))
                     (error () nil)))))
            (tb (sb-thread:make-thread
                 (lambda ()
                   (handler-case
                       (dotimes (_ 50) (mock-insert b 0 "y"))
                     (error () nil))))))
        (sb-thread:join-thread ta)
        (sb-thread:join-thread tb)))
    (limn/buffer-undo:clear-undo "PA")
    (limn/buffer-undo:clear-undo "PB")))

;;; ─── D6. Edge cases ───────────────────────────────────────────────

(deftest undo-d6-undo-empty-list-noop
  (with-fresh-buffer (b)
    (assert-no-error (limn/buffer-undo:undo "u"))
    (assert-equal "" (mock-buffer-text b))))

(deftest undo-d6-redo-nothing-noop
  (with-fresh-buffer (b)
    (mock-insert b 0 "x")
    (assert-no-error (limn/buffer-undo:redo "u"))))

(deftest undo-d6-duplicate-boundary-collapses
  (with-fresh-buffer (b)
    (mock-insert b 0 "x")
    (limn/buffer-undo:undo-boundary "u")
    (limn/buffer-undo:undo-boundary "u")
    (limn/buffer-undo:undo-boundary "u")
    (mock-insert b 1 "y")
    (limn/buffer-undo:undo "u")
    (assert-equal "x" (mock-buffer-text b))
    (limn/buffer-undo:undo "u")
    (assert-equal "" (mock-buffer-text b))))

(deftest undo-d6-large-insert-no-memory-explosion
  (with-fresh-buffer (b)
    (with-timeout-bound 3
      (mock-insert b 0 (make-string 100000 :initial-element #\z)))
    (assert-eql 100000 (length (mock-buffer-text b)))
    (limn/buffer-undo:undo "u")
    (assert-equal "" (mock-buffer-text b))))

;;; ─── D7. Hooks ────────────────────────────────────────────────────

(deftest undo-d7-before-undo-hook-fires
  (with-fresh-buffer (b)
    (mock-insert b 0 "x")
    (let ((called nil))
      (let ((limn/buffer-undo:*before-undo-hook*
              (list (lambda (buf-id) (setf called buf-id)))))
        (limn/buffer-undo:undo "u"))
      (assert-equal "u" called))))

(deftest undo-d7-after-undo-hook-receives-op
  (with-fresh-buffer (b)
    (mock-insert b 0 "abc")
    (let ((seen-op nil))
      (let ((limn/buffer-undo:*after-undo-hook*
              (list (lambda (buf-id op)
                      (declare (ignore buf-id))
                      (setf seen-op op)))))
        (limn/buffer-undo:undo "u"))
      (assert-true seen-op "after-hook received op payload"))))

(deftest undo-d7-hook-error-does-not-break-undo
  (with-fresh-buffer (b)
    (mock-insert b 0 "ok")
    (let ((limn/buffer-undo:*before-undo-hook*
            (list (lambda (buf-id) (declare (ignore buf-id))
                    (error "hook boom")))))
      (assert-no-error (limn/buffer-undo:undo "u")))
    (assert-equal "" (mock-buffer-text b))))

(deftest undo-d7-disabled-p-query
  (with-fresh-buffer (b)
    (mock-insert b 0 "")              ; touch b so compiler doesn't warn
    (assert-false (limn/buffer-undo:undo-disabled-p "u"))
    (limn/buffer-undo:disable-undo "u")
    (assert-true (limn/buffer-undo:undo-disabled-p "u"))
    (limn/buffer-undo:enable-undo "u")
    (assert-false (limn/buffer-undo:undo-disabled-p "u"))))
