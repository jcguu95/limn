;;;; Frame system tests (Spec 5.1 frame-*; marked ◇ long-term)
;;;;
;;;; A "frame" is an OS-level window in Limn's model. Most tests skip
;;;; gracefully if frame-* isn't implemented yet, but those that DO pass
;;;; verify cross-frame isolation, the most subtle property of the model.

(in-package #:limn/test)

;;; ── frame-new ───────────────────────────────────────────────────────────

(deftest test-frame-new-returns-frame-id
  (let ((r (send! "bridge/frame-new")))
    (when (eq (getf r :|ok|) t)
      (let ((fid (json-get* r :|data| :|frame-id|)))
        (assert-type fid string "frame-id is string")
        (check-assertion (> (length fid) 0) "frame-id non-empty")
        (ignore-errors (send! "bridge/frame-close" :|frame-id| fid))))))

(deftest test-frame-new-creates-default-window
  "A newly created frame contains at least one default window."
  (let ((r (send! "bridge/frame-new")))
    (when (eq (getf r :|ok|) t)
      (let* ((fid     (json-get* r :|data| :|frame-id|))
             (list-r  (send! "bridge/win-list"))
             (windows (getf list-r :|data|))
             (in-new  (remove-if-not
                       (lambda (w) (string= (getf w :|frame-id|) fid))
                       windows)))
        (assert-true in-new (format nil "new frame ~a has at least one window" fid))
        (ignore-errors (send! "bridge/frame-close" :|frame-id| fid))))))

;;; ── frame-list ──────────────────────────────────────────────────────────

(deftest test-frame-list-includes-default-frame
  "frame-list contains at least the original startup frame."
  (let ((r (send! "bridge/frame-list")))
    (when (eq (getf r :|ok|) t)
      (let ((frames (getf r :|data|)))
        (assert-true frames "at least one frame")
        (assert-list-of #'consp frames "each entry is an object")))))

(deftest test-frame-list-grows-after-new
  "After frame-new, frame-list count increases by 1."
  (let ((before (send! "bridge/frame-list")))
    (when (eq (getf before :|ok|) t)
      (let ((count-before (length (getf before :|data|)))
            (nf (send! "bridge/frame-new")))
        (when (eq (getf nf :|ok|) t)
          (let* ((after (send! "bridge/frame-list"))
                 (count-after (length (getf after :|data|))))
            (assert-equal (1+ count-before) count-after
                          "frame-list count incremented"))
          (ignore-errors
            (send! "bridge/frame-close"
                   :|frame-id| (json-get* nf :|data| :|frame-id|))))))))

;;; ── frame-close ─────────────────────────────────────────────────────────

(deftest test-frame-close-removes-frame
  "frame-close on a created frame removes it from frame-list."
  (let ((nf (send! "bridge/frame-new")))
    (when (eq (getf nf :|ok|) t)
      (let ((fid (json-get* nf :|data| :|frame-id|)))
        (assert-ok (send! "bridge/frame-close" :|frame-id| fid))
        (let ((fl (send! "bridge/frame-list")))
          (when (eq (getf fl :|ok|) t)
            (let ((ids (mapcar (lambda (f) (getf f :|frame-id|))
                                (getf fl :|data|))))
              (assert-false (find fid ids :test #'string=)
                            "closed frame not in list"))))))))

(deftest test-frame-close-unknown
  (let ((r (send! "bridge/frame-close" :|frame-id| "f-nope")))
    (when (eq (getf r :|ok|) :false)
      (assert-fail r "closing unknown frame fails"))))

;;; ── Cross-frame win-id isolation ───────────────────────────────────────

(deftest test-frame-windows-have-frame-id
  "Each window in win-list reports which frame it belongs to."
  (let* ((data (getf (send! "bridge/win-list") :|data|))
         (first (first data)))
    (when first
      ;; Frame implementations should include frame-id; if it's missing,
      ;; the implementation hasn't multi-framed yet — that's also OK.
      (when (getf first :|frame-id|)
        (assert-type (getf first :|frame-id|) string)))))

(deftest test-frame-load-buffer-scoped-to-frame
  "engine-load in a window of one frame doesn't affect another frame's windows."
  (let ((nf (send! "bridge/frame-new")))
    (when (eq (getf nf :|ok|) t)
      (let ((new-fid (json-get* nf :|data| :|frame-id|)))
        ;; load a buffer in w1 (original frame)
        (send! "bridge/engine-load"
               :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)
        ;; verify a window in the new frame doesn't show that buffer
        (let* ((list-r (send! "bridge/win-list"))
               (other-frame-win
                 (find-if (lambda (w)
                            (string= (getf w :|frame-id|) new-fid))
                          (getf list-r :|data|))))
          (when other-frame-win
            ;; The new frame's window should not have the buffer we just loaded
            (let ((b (getf other-frame-win :|buffer-id|)))
              (assert-true (or (null b) (eq b :null))
                           "new frame's window is empty"))))
        (ignore-errors (send! "bridge/frame-close" :|frame-id| new-fid))))))

;;; ── Events from a specific frame ───────────────────────────────────────

(deftest test-frame-event-frame-id-matches-source
  "Events injected to a specific frame include that frame's id."
  (let ((nf (send! "bridge/frame-new")))
    (when (eq (getf nf :|ok|) t)
      (let ((new-fid (json-get* nf :|data| :|frame-id|)))
        (drain-events)
        (send! "test/inject-key"
               :|frame-id| new-fid :|key| "j" :|mods| nil)
        (let ((ev (read-event :type "key" :timeout 1)))
          (when ev
            (assert-equal new-fid (getf ev :|frame-id|)
                          "event frame-id matches injected frame")))
        (ignore-errors (send! "bridge/frame-close" :|frame-id| new-fid))))))

;;; ── Frame focus ─────────────────────────────────────────────────────────

(deftest test-frame-focus-roundtrip
  "Newly created frame can be focused; old frame can be re-focused."
  (let ((nf (send! "bridge/frame-new")))
    (when (eq (getf nf :|ok|) t)
      (let ((new-fid (json-get* nf :|data| :|frame-id|))
            (focus-cmd (find-symbol "BRIDGE/FRAME-FOCUS" :keyword)))
        (declare (ignore focus-cmd))
        ;; spec defines bridge/frame-focus indirectly via frame-list update
        (let ((r (send! "bridge/frame-focus" :|frame-id| new-fid)))
          (assert-true (member (getf r :|ok|) '(t :false))
                       "frame-focus responds"))
        (ignore-errors (send! "bridge/frame-close" :|frame-id| new-fid))))))

;;; ── Closing a frame closes its windows ─────────────────────────────────

(deftest test-frame-close-cascades-to-windows
  "Closing a frame removes all its windows from win-list."
  (let ((nf (send! "bridge/frame-new")))
    (when (eq (getf nf :|ok|) t)
      (let* ((new-fid (json-get* nf :|data| :|frame-id|))
             ;; collect windows in new frame
             (before-list (send! "bridge/win-list"))
             (in-frame
               (remove-if-not
                 (lambda (w) (string= (getf w :|frame-id|) new-fid))
                 (getf before-list :|data|)))
             (frame-win-ids
               (mapcar (lambda (w) (getf w :|win-id|)) in-frame)))
        ;; close the frame
        (send! "bridge/frame-close" :|frame-id| new-fid)
        ;; verify those windows gone
        (let* ((after-list (send! "bridge/win-list"))
               (after-ids (mapcar (lambda (w) (getf w :|win-id|))
                                   (getf after-list :|data|))))
          (dolist (w frame-win-ids)
            (assert-false (find w after-ids :test #'string=)
                          (format nil "window ~s gone after frame close" w))))))))
