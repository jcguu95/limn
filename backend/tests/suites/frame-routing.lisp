;;;; v0.21 — frame system completion (folded-in v0.18.2).
;;;;
;;;; A. Per-frame wire command routing — when target window lives in
;;;;    frame fN, commands like view/set / engine-load / bookmark/* /
;;;;    view/overlays / view/selection-* drive fN's MainWidget, not
;;;;    f1's.
;;;;
;;;; v0.18.0+0.18.1 shipped the frame REGISTRY and a second OS window
;;;; but every wire command still went through f1's MainWidget. After
;;;; v0.21 A, a window's frame_id determines which widget executes its
;;;; commands.
;;;;
;;;; Tests sit at the Qt-tier (no docker), verifying the routing logic
;;;; via observable state — e.g., open a doc in w2 (in f2) and confirm
;;;; the buffer-id is registered, view/get reports the right page after
;;;; engine-load, etc. We can't easily verify "the right MainWidget
;;;; rendered" without GL grab, but state-level routing is the
;;;; framework-level contract — the visible part is implicit follow-on.
;;;;
;;;; OS-tier (batch-os-frame-workspace.lisp) tests workspace movement
;;;; and frame-workspace-change events.

(in-package #:limn/test)

;;; ── helpers ───────────────────────────────────────────────────────────

(defun fc-create! ()
  (let ((r (send! "frame/create")))
    (and (eq (getf r :|ok|) t) (json-get* r :|data| :|frame-id|))))

(defun fc-close! (fid) (send! "frame/close" :|frame-id| fid))

(defun split-into-frame! (frame-id &key (from "w1"))
  (let ((r (send! "bridge/win-split" :|win-id| from
                                      :|dir| "h" :|frame-id| frame-id)))
    (and (eq (getf r :|ok|) t) (json-get* r :|data| :|win-b|))))

;;; ── A. engine-load on a window-in-f2 doesn't perturb f1's state ─────

(deftest test-routing-engine-load-into-f2-isolated-from-f1
  "Load a doc into a window in f2; w1 (in f1) state unchanged.
   v0.18.x already gave us per-window state isolation; v0.21 makes
   it routed through the RIGHT MainWidget (the win's frame's), so
   loading into w-in-f2 doesn't visually steal f1's display."
  (with-buffer (b1)
    ;; w1.buffer = b1 in f1, by now. Snapshot.
    (let ((p1-before (json-get* (send! "view/get" :|win-id| "w1") :|data| :|page|))
          (fid (fc-create!)))
      (when fid
        (let ((w-in-f2 (split-into-frame! fid)))
          (when w-in-f2
            (let ((r (send! "bridge/engine-load"
                            :|win-id| w-in-f2 :|engine| "mupdf"
                            :|path| *fixture-pdf*)))
              (assert-ok r "engine-load into w-in-f2 succeeds")
              (assert-equal p1-before
                            (json-get* (send! "view/get" :|win-id| "w1")
                                       :|data| :|page|)
                            "f1's w1 page unaffected by load into f2")))
          (fc-close! fid))))))

(deftest test-routing-view-set-on-win-in-f2-doesnt-touch-f1
  "view/set :page on a window in f2 doesn't change f1's w1 page state."
  (with-buffer (b1)
    (let ((fid (fc-create!)))
      (when fid
        (let ((w (split-into-frame! fid)))
          (when w
            (send! "bridge/engine-load" :|win-id| w :|engine| "mupdf"
                                          :|path| *fixture-pdf*)
            (send! "view/set" :|win-id| "w1" :|page| 0)
            (send! "view/set" :|win-id| w   :|page| 3)
            (let ((p1 (json-get* (send! "view/get" :|win-id| "w1")
                                 :|data| :|page|))
                  (p2 (json-get* (send! "view/get" :|win-id| w)
                                 :|data| :|page|)))
              (assert-equal 0 p1 "w1 stays at page 0")
              (assert-equal 3 p2 "w-in-f2 goes to page 3")))
          (fc-close! fid))))))

(deftest test-routing-bookmark-set-on-win-in-f2-uses-its-own-buffer
  "bookmark/set on w-in-f2 attaches to the buffer that f2 has loaded,
   not to f1's buffer."
  (with-buffer (b1)
    (let ((fid (fc-create!)))
      (when fid
        (let ((w (split-into-frame! fid)))
          (when w
            (let* ((lr (send! "bridge/engine-load"
                              :|win-id| w :|engine| "mupdf"
                              :|path| *fixture-pdf*))
                   (b2 (json-get* lr :|data| :|buffer-id|)))
              (when b2
                (send! "bookmark/set" :|buffer-id| b2
                                       :|name| "from-f2" :|page| 0)
                ;; f1's buffer should have ZERO bookmarks
                (assert-equal 0 (length (json-get*
                                          (send! "bookmark/list"
                                                 :|buffer-id| b1)
                                          :|data| :|items|))
                              "f1 buffer empty bookmark list")
                ;; f2's buffer should have exactly the one we set
                (assert-equal 1 (length (json-get*
                                          (send! "bookmark/list"
                                                 :|buffer-id| b2)
                                          :|data| :|items|))
                              "f2 buffer has the bookmark")
                (send! "bookmark/delete" :|buffer-id| b2 :|name| "from-f2")
                (send! "buffer/close" :|buffer-id| b2))))
          (fc-close! fid))))))

(deftest test-routing-resolve-widget-for-window-helper-works
  "A test that an internal resolve_widget_for_window helper (or equivalent
   abstraction) handles unknown win-id gracefully — view/get on bad
   win-id fails clearly without crashing the server."
  (let ((r (send! "view/get" :|win-id| "w-nope")))
    (assert-fail r "unknown win-id fails")))

;;; ── B. Window count per frame remains consistent after routing ─────

(deftest test-routing-bridge-win-list-frame-ids-match-frame-list
  "Cross-check: bridge/win-list's :frame-id per entry matches what
   frame/list says about :win-ids — guards against routing logic
   getting confused about which frame a window belongs to."
  (let ((fid (fc-create!)))
    (when fid
      (let ((w (split-into-frame! fid)))
        (when w
          (let* ((entries (getf (send! "bridge/win-list") :|data|))
                 (w-entry (find w entries
                                :key (lambda (e) (getf e :|win-id|))
                                :test #'string=))
                 (frame-entry (find fid
                                    (json-get* (send! "frame/list")
                                                :|data| :|items|)
                                    :key (lambda (f) (getf f :|frame-id|))
                                    :test #'string=)))
            (assert-equal fid (getf w-entry :|frame-id|)
                          "win's :frame-id matches its frame")
            (assert-true (member w (getf frame-entry :|win-ids|)
                                  :test #'string=)
                         "frame's :win-ids contains the win")))
        (fc-close! fid)))))
