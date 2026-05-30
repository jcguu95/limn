;;;; v0.37 — limn/bookmark-handlers RED tests (unit-tier)
;;;;
;;;; Covers:
;;;;   D1 install registers text-mode / org-mode / pdf-mode in
;;;;      limn/bookmark's record-fn + handler registries
;;;;   D2 text-mode record-fn dispatch (vtable mock) returns expected
;;;;      record plist shape
;;;;   D3 text-mode jump-fn dispatch (vtable mock) receives the record
;;;;   D4 same for pdf-mode
;;;;   D5 round-trip: register handlers, store a bookmark, jump it,
;;;;      verify the jump-fn fired with the recorded values
;;;;
;;;; All wire I/O is mocked via the *text-record-fn* / *pdf-jump-fn*
;;;; vtable — no live Limn binary needed.

(in-package #:limn/unit-test)

;;; ── D1. install registers all three modes ──────────────────────────

(deftest bookmark-handlers-d1-install-registers-text
  (limn/bookmark-handlers:install)
  (assert-true (limn/bookmark:handler-registered-p 'cl-user::text-mode)
               "text-mode handler registered"))

(deftest bookmark-handlers-d1-install-registers-org
  (limn/bookmark-handlers:install)
  (assert-true (limn/bookmark:handler-registered-p 'cl-user::org-mode)
               "org-mode handler registered (same shape as text-mode)"))

(deftest bookmark-handlers-d1-install-registers-pdf
  (limn/bookmark-handlers:install)
  (assert-true (limn/bookmark:handler-registered-p 'cl-user::pdf-mode)
               "pdf-mode handler registered"))

(deftest bookmark-handlers-d1-install-is-idempotent
  "Re-running install does not error; it just replaces the entries."
  (limn/bookmark-handlers:install)
  (assert-no-error (limn/bookmark-handlers:install)))

;;; ── D2. text-mode record (vtable mock) ─────────────────────────────

(deftest bookmark-handlers-d2-text-record-shape
  "Mocked vtable returns a deterministic record; the registered
   record-fn passes it through unchanged."
  (limn/bookmark-handlers:install)
  (let ((limn/bookmark-handlers:*text-record-fn*
          (lambda () '(:file "/m/note.txt" :position 17))))
    (let ((rec (limn/bookmark:make-current-record 'cl-user::text-mode)))
      (assert-equal "/m/note.txt" (getf rec :file)
                    "record-fn return value propagated")
      (assert-equal 17 (getf rec :position)))))

(deftest bookmark-handlers-d2-text-record-nil-when-no-buffer
  "When the vtable returns NIL (no focused text buffer / unsaved
   scratch), make-current-record returns NIL too — the command
   layer uses this to skip silently."
  (limn/bookmark-handlers:install)
  (let ((limn/bookmark-handlers:*text-record-fn* (lambda () nil)))
    (assert-false (limn/bookmark:make-current-record 'cl-user::text-mode))))

;;; ── D3. text-mode jump (vtable mock) ───────────────────────────────

(deftest bookmark-handlers-d3-text-jump-dispatch
  "bookmark-jump on a text-mode record fires *text-jump-fn* with the
   record plist."
  (limn/bookmark-handlers:install)
  (limn/bookmark:bookmark-clear)
  (let ((received nil))
    (let ((limn/bookmark-handlers:*text-jump-fn*
            (lambda (rec) (setf received rec))))
      (limn/bookmark:bookmark-add
       (limn/bookmark:make-bookmark
        :name "t" :handler 'cl-user::text-mode
        :record '(:file "/m/x.txt" :position 99)))
      (limn/bookmark:bookmark-jump "t"))
    (assert-equal "/m/x.txt" (getf received :file)
                  "jump-fn received :file")
    (assert-equal 99 (getf received :position)
                  "jump-fn received :position")))

(deftest bookmark-handlers-d3-org-mode-uses-text-jump
  "org-mode delegates to *text-jump-fn* (same record shape)."
  (limn/bookmark-handlers:install)
  (limn/bookmark:bookmark-clear)
  (let ((received nil))
    (let ((limn/bookmark-handlers:*text-jump-fn*
            (lambda (rec) (setf received rec))))
      (limn/bookmark:bookmark-add
       (limn/bookmark:make-bookmark
        :name "o" :handler 'cl-user::org-mode
        :record '(:file "/m/y.org" :position 3)))
      (limn/bookmark:bookmark-jump "o"))
    (assert-equal "/m/y.org" (getf received :file)
                  "org-mode handler also routes through *text-jump-fn*")))

;;; ── D4. pdf-mode record + jump ─────────────────────────────────────

(deftest bookmark-handlers-d4-pdf-record-shape
  (limn/bookmark-handlers:install)
  (let ((limn/bookmark-handlers:*pdf-record-fn*
          (lambda () '(:path "/m/spec.pdf"
                       :page 7 :y-offset 0.42 :x-offset 0.1))))
    (let ((rec (limn/bookmark:make-current-record 'cl-user::pdf-mode)))
      (assert-equal "/m/spec.pdf" (getf rec :path))
      (assert-equal 7 (getf rec :page))
      (assert-true (< (abs (- (getf rec :y-offset) 0.42)) 0.001))
      (assert-true (< (abs (- (getf rec :x-offset) 0.1))  0.001)))))

(deftest bookmark-handlers-d4-pdf-jump-dispatch
  (limn/bookmark-handlers:install)
  (limn/bookmark:bookmark-clear)
  (let ((received nil))
    (let ((limn/bookmark-handlers:*pdf-jump-fn*
            (lambda (rec) (setf received rec))))
      (limn/bookmark:bookmark-add
       (limn/bookmark:make-bookmark
        :name "p" :handler 'cl-user::pdf-mode
        :record '(:path "/m/z.pdf" :page 3 :y-offset 0.5 :x-offset 0.0)))
      (limn/bookmark:bookmark-jump "p"))
    (assert-equal "/m/z.pdf" (getf received :path))
    (assert-equal 3 (getf received :page))))

;;; ── D4b. missing-file regression (v0.37 ship-readiness) ────────────

(deftest bookmark-handlers-d4b-pdf-jump-missing-file-signals
  "default-pdf-jump on a record whose :path points at a deleted
   file must error LOUDLY — not silently no-op or open a wrong
   buffer.  cmd-bookmark-jump's handler-case relays this to the
   user via %echo."
  (assert-error error
                (limn/bookmark-handlers:default-pdf-jump
                 '(:path "/does/not/exist/ghost.pdf" :page 0
                   :y-offset 0.0 :x-offset 0.0))))

(deftest bookmark-handlers-d4b-pdf-jump-missing-path-signals
  "Record without :path at all is a bug (someone hand-built a
   malformed record).  Signal so it's obvious, don't silently
   no-op."
  (assert-error error
                (limn/bookmark-handlers:default-pdf-jump '(:page 1))))

(deftest bookmark-handlers-d4b-text-jump-missing-file-signals
  "default-text-jump on a record whose :file no longer exists
   must error — without this check limn/file:find-file would
   silently open an empty new buffer, hiding the data loss."
  (assert-error error
                (limn/bookmark-handlers:default-text-jump
                 '(:file "/does/not/exist/ghost.txt" :position 0))))

(deftest bookmark-handlers-d4b-text-jump-missing-path-signals
  (assert-error error
                (limn/bookmark-handlers:default-text-jump '(:position 5))))

;;; ── D5. round-trip via persistence ────────────────────────────────

(deftest bookmark-handlers-d5-roundtrip-with-handler
  "Save → clear → load → jump still dispatches the live handler with
   the persisted record.  This is the user-visible 'I closed Limn,
   reopened it, M-x bookmark-jump my-bookmark, and ended up where
   I left off' contract."
  (limn/bookmark-handlers:install)
  (limn/bookmark:bookmark-clear)
  (let ((tmp (merge-pathnames "limn-bm-hdl-roundtrip.lisp"
                              (pathname (or (sb-posix:getenv "TMPDIR")
                                            "/tmp/")))))
    (when (probe-file tmp) (delete-file tmp))
    (limn/bookmark:bookmark-add
     (limn/bookmark:make-bookmark
      :name "persist-me" :handler 'cl-user::pdf-mode
      :record '(:path "/m/persisted.pdf" :page 11
                :y-offset 0.25 :x-offset 0.0)))
    (limn/bookmark:bookmarks-save tmp)
    (limn/bookmark:bookmark-clear)
    (limn/bookmark:bookmarks-load tmp)
    (let ((received nil))
      (let ((limn/bookmark-handlers:*pdf-jump-fn*
              (lambda (rec) (setf received rec))))
        (limn/bookmark:bookmark-jump "persist-me"))
      (assert-equal 11 (getf received :page)
                    "page survived save+load+jump round-trip")
      (assert-equal "/m/persisted.pdf" (getf received :path)
                    "path survived"))
    (when (probe-file tmp) (delete-file tmp))))
