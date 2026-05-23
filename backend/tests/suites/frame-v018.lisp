;;;; v0.18.0 frame system — Qt-tier tests.
;;;;
;;;; SPEC §12 v0.18 / §3.2 §7.2:
;;;;   frame = OS-level window (vs window/pane = subdivision inside one
;;;;   frame). Multiple frames can coexist; each has its own pool of
;;;;   tiled / floating windows.
;;;;
;;;; v0.18.0 scope (this file):
;;;;   - frame registry + frame_id on every LimnWindow (default "f1")
;;;;   - frame/list / frame/create / frame/close / frame/focus wire cmds
;;;;   - bridge/win-list entries carry :frame-id
;;;;   - bridge/win-split accepts optional :frame-id (defaults to the
;;;;     window's existing frame)
;;;;   - events: frame-create / frame-close / frame-focus
;;;;
;;;; v0.18.1 (deferred):
;;;;   - actually instantiate a second Qt MainWindow per frame
;;;;   - frame/focus raises the OS window
;;;;   - per-frame DocumentView isolation
;;;;   - container openbox multi-workspace tests
;;;;   - frame-workspace-change event
;;;;
;;;; The existing suites/frame.lisp uses the OLDER bridge/frame-* naming
;;;; with soft "skip-if-unimplemented" assertions. Once v0.18 ships,
;;;; that file can be removed in favour of this one.

(in-package #:limn/test)

;;; ── helpers ───────────────────────────────────────────────────────────

(defun frame-list ()
  (json-get* (send! "frame/list") :|data| :|items|))

(defun frame-create! ()
  (let ((r (send! "frame/create")))
    (and (eq (getf r :|ok|) t)
         (json-get* r :|data| :|frame-id|))))

(defun frame-close! (fid)
  (send! "frame/close" :|frame-id| fid))

(defun frame-focus! (fid)
  (send! "frame/focus" :|frame-id| fid))

(defun frame-by-id (frames fid)
  (find fid frames :key (lambda (f) (getf f :|frame-id|))
                   :test #'string=))

;;; ── A. baseline: default frame f1 exists from startup ────────────────

(deftest test-frame-list-includes-default-f1
  "Startup state has at least one frame (f1) that owns the default w1."
  (let* ((frames (frame-list))
         (f1     (frame-by-id frames "f1")))
    (assert-true frames "frame/list non-empty")
    (assert-true f1    "f1 in list")
    (when f1
      (assert-true (getf f1 :|focused|) "f1 is focused at startup"))))

(deftest test-frame-list-shape
  "Each entry has :frame-id, :focused, :win-ids."
  (let ((frames (frame-list)))
    (dolist (f frames)
      (assert-has-key :|frame-id| f)
      (assert-has-key :|focused|  f)
      (assert-has-key :|win-ids|  f)
      (assert-type (getf f :|win-ids|) list ":win-ids is a list"))))

(deftest test-bridge-win-list-entries-have-frame-id
  "Every window in bridge/win-list carries :frame-id (default f1)."
  (let* ((r (send! "bridge/win-list"))
         (entries (getf r :|data|)))
    (dolist (w entries)
      (assert-has-key :|frame-id| w
                      (format nil "win ~a has :frame-id" (getf w :|win-id|)))
      (assert-true (and (stringp (getf w :|frame-id|))
                        (plusp (length (getf w :|frame-id|))))
                   ":frame-id is non-empty string"))))

(deftest test-default-window-belongs-to-f1
  "w1 (the bootstrap window) belongs to frame f1."
  (let* ((r (send! "bridge/win-list"))
         (w1 (find "w1" (getf r :|data|)
                   :key (lambda (w) (getf w :|win-id|))
                   :test #'string=)))
    (assert-true w1)
    (when w1
      (assert-equal "f1" (getf w1 :|frame-id|)))))

;;; ── B. frame/create allocates new frame-id ──────────────────────────

(deftest test-frame-create-returns-new-id
  "frame/create returns a fresh frame-id distinct from f1."
  (let ((fid (frame-create!)))
    (assert-true (stringp fid) "frame-id returned")
    (when fid
      (assert-true (not (string= fid "f1")) "new id ≠ f1")
      (frame-close! fid))))

(deftest test-frame-create-shows-in-list
  "After create, frame/list grows by 1 and contains the new id."
  (let* ((before (length (frame-list)))
         (fid    (frame-create!)))
    (when fid
      (let* ((after (frame-list)))
        (assert-equal (1+ before) (length after) "list grew by 1")
        (assert-true (frame-by-id after fid) "new id present"))
      (frame-close! fid))))

(deftest test-frame-create-starts-with-zero-windows
  "A freshly-created frame has no windows yet (user adds via win-split
   :frame-id when they want one)."
  (let ((fid (frame-create!)))
    (when fid
      (let* ((frames (frame-list))
             (entry  (frame-by-id frames fid))
             (wids   (and entry (getf entry :|win-ids|))))
        (assert-equal 0 (length wids)
                      "new frame has no windows by default"))
      (frame-close! fid))))

;;; ── C. frame/close ──────────────────────────────────────────────────

(deftest test-frame-close-removes-from-list
  "After frame/close, the frame is gone from frame/list."
  (let ((fid (frame-create!)))
    (when fid
      (assert-ok (frame-close! fid))
      (assert-true (not (frame-by-id (frame-list) fid))
                   "closed frame absent from list"))))

(deftest test-frame-close-default-f1-refused
  "Cannot close the last (or default) frame — would leave nothing to
   render into. Hard fail rather than silent ignore."
  (let ((r (frame-close! "f1")))
    (assert-fail r "closing default f1 rejected")))

(deftest test-frame-close-unknown-fails
  "Closing a non-existent frame-id fails with clear error."
  (assert-fail (frame-close! "f-nope")))

(deftest test-frame-close-removes-its-windows
  "Closing a frame implicitly closes every window in it."
  (let ((fid (frame-create!)))
    (when fid
      ;; Split w1 into the new frame so it has at least one window.
      ;; (Currently w1 is in f1; we split w1 with :frame-id fid which
      ;; should put the NEW window into fid.)
      (let* ((sr (send! "bridge/win-split" :|win-id| "w1"
                                            :|dir| "h" :|frame-id| fid))
             (new-w (json-get* sr :|data| :|win-b|)))
        (when new-w
          ;; Verify new-w is in fid pre-close.
          (let* ((before (frame-by-id (frame-list) fid)))
            (assert-true (member new-w (getf before :|win-ids|) :test #'string=)
                         "new window listed under fid"))
          ;; Close the frame; its window should be gone too.
          (frame-close! fid)
          (let* ((r (send! "bridge/win-list"))
                 (entries (getf r :|data|)))
            (assert-true (not (find new-w entries
                                     :key (lambda (w) (getf w :|win-id|))
                                     :test #'string=))
                         "frame's window gone from bridge/win-list")))))))

;;; ── D. frame/focus ──────────────────────────────────────────────────

(deftest test-frame-focus-flips-focused-flag
  "After frame/focus, that frame's :focused becomes true and the old
   one's becomes false."
  (let ((fid (frame-create!)))
    (when fid
      (assert-ok (frame-focus! fid))
      (let* ((frames (frame-list))
             (foc    (remove-if-not (lambda (f) (getf f :|focused|)) frames)))
        (assert-equal 1 (length foc) "exactly one focused frame")
        (assert-equal fid (getf (first foc) :|frame-id|)
                      "the new frame is focused"))
      (frame-focus! "f1")
      (frame-close! fid))))

(deftest test-frame-focus-unknown-fails
  (assert-fail (frame-focus! "f-nope")))

;;; ── E. bridge/win-split with :frame-id ──────────────────────────────

(deftest test-win-split-with-frame-id-puts-window-in-frame
  "bridge/win-split :frame-id puts the NEW window in the named frame."
  (let ((fid (frame-create!)))
    (when fid
      (let* ((sr (send! "bridge/win-split" :|win-id| "w1"
                                            :|dir| "h" :|frame-id| fid))
             (new-w (json-get* sr :|data| :|win-b|)))
        (assert-true new-w "split returned new win-id")
        (when new-w
          (let* ((frames (frame-list))
                 (entry  (frame-by-id frames fid)))
            (assert-true (member new-w (getf entry :|win-ids|) :test #'string=)
                         "new window listed under the target frame"))))
      (frame-close! fid))))

(deftest test-win-split-without-frame-id-defaults-to-source-frame
  "Without :frame-id, split puts the new window in the SAME frame as
   the source window (existing behavior — all windows in f1)."
  (let* ((sr (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
         (new-w (json-get* sr :|data| :|win-b|)))
    (when new-w
      (let* ((r (send! "bridge/win-list"))
             (entries (getf r :|data|))
             (w-entry (find new-w entries
                            :key (lambda (w) (getf w :|win-id|))
                            :test #'string=)))
        (assert-equal "f1" (getf w-entry :|frame-id|)
                      "new window inherits f1 from source")
        (send! "bridge/win-close" :|win-id| new-w)))))

;;; ── F. events: frame-create / frame-close / frame-focus ─────────────

(deftest test-frame-create-fires-event
  (drain-events)
  (let ((fid (frame-create!)))
    (when fid
      (let ((ev (read-event :type "frame-create" :timeout 1)))
        (assert-true ev "frame-create event fired")
        (when ev
          (assert-equal fid (getf ev :|frame-id|))))
      (frame-close! fid))))

(deftest test-frame-close-fires-event
  (let ((fid (frame-create!)))
    (when fid
      (drain-events)
      (frame-close! fid)
      (let ((ev (read-event :type "frame-close" :timeout 1)))
        (assert-true ev "frame-close event fired")
        (when ev
          (assert-equal fid (getf ev :|frame-id|)))))))

(deftest test-frame-focus-fires-event
  (let ((fid (frame-create!)))
    (when fid
      (drain-events)
      (frame-focus! fid)
      (let ((ev (read-event :type "frame-focus" :timeout 1)))
        (assert-true ev "frame-focus event fired")
        (when ev
          (assert-equal fid (getf ev :|frame-id|))))
      (frame-focus! "f1")
      (frame-close! fid))))

;;; ── G. multi-frame: list grows / shrinks correctly ──────────────────

(deftest test-multi-frame-create-and-close
  "Create 3 frames, verify list size, close each, verify list shrinks."
  (let* ((base (length (frame-list)))
         (f-a  (frame-create!))
         (f-b  (frame-create!))
         (f-c  (frame-create!)))
    (when (and f-a f-b f-c)
      (assert-equal (+ base 3) (length (frame-list)) "grew by 3")
      (frame-close! f-b)
      (assert-equal (+ base 2) (length (frame-list)) "shrunk by 1")
      (frame-close! f-a)
      (frame-close! f-c)
      (assert-equal base (length (frame-list)) "back to baseline"))))

(deftest test-frame-ids-are-unique-sequential
  "Newly allocated frame-ids are unique (no reuse during a session)."
  (let* ((fids (loop repeat 3
                     for fid = (frame-create!)
                     when fid collect fid)))
    (assert-equal (length fids) (length (remove-duplicates fids :test #'string=))
                  "all returned ids are unique")
    (dolist (fid fids) (frame-close! fid))))
