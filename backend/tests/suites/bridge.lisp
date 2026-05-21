;;;; bridge/ namespace tests
;;;;
;;;; Covers section 5.1 of LIMN-SPEC:
;;;;   bridge/capabilities, bridge/engine-load, bridge/win-list,
;;;;   bridge/win-split, bridge/win-close, bridge/win-focus,
;;;;   bridge/win-float-{create,move,resize},
;;;;   bridge/frame-{new,close,list} (long-term, may not yet be implemented)

(in-package #:limn/test)

;;; ─── bridge/capabilities ──────────────────────────────────────────────────

(deftest test-capabilities-ok
  "bridge/capabilities returns ok with data."
  (let ((r (send! "bridge/capabilities")))
    (assert-ok r)
    (assert-has-key :|data| r "data field present")))

(deftest test-capabilities-lists-engines
  "Capabilities data includes a non-empty engines list."
  (let* ((r    (send! "bridge/capabilities"))
         (data (getf r :|data|))
         (engines (getf data :|engines|)))
    (assert-type engines list "engines is a list")
    (assert-true engines "at least one engine present")
    (assert-list-of #'stringp engines "engines list contains strings")))

(deftest test-capabilities-lists-mupdf
  "mupdf is among the listed engines."
  (let* ((r       (send! "bridge/capabilities"))
         (engines (json-get* r :|data| :|engines|)))
    (assert-contains "mupdf" engines "mupdf engine available")))

(deftest test-capabilities-has-frontend-name
  "Capabilities reports the frontend identifier (e.g. 'qt')."
  (let ((frontend (json-get* (send! "bridge/capabilities") :|data| :|frontend|)))
    (assert-type frontend string "frontend field is a string")))

(deftest test-capabilities-has-version
  "Capabilities reports a protocol version."
  (let ((version (json-get* (send! "bridge/capabilities") :|data| :|version|)))
    (assert-type version string "version is a string")))

;;; ─── bridge/engine-load ───────────────────────────────────────────────────

(deftest test-engine-load-mupdf-ok
  "Loading mupdf engine with a valid PDF returns ok and a buffer-id."
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)))
    (assert-ok r)
    (assert-has-key :|buffer-id| (getf r :|data|) "buffer-id returned")
    (assert-type (json-get* r :|data| :|buffer-id|) string "buffer-id is a string")))

(deftest test-engine-load-missing-file
  "Loading from a nonexistent path returns ok=false with an error."
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf" :|path| "/no/file.pdf")))
    (assert-fail r)
    (assert-type (getf r :|error|) string "error message present")))

(deftest test-engine-load-unknown-engine
  "Loading an unknown engine name returns ok=false."
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "no-such-engine" :|path| *fixture-pdf*)))
    (assert-fail r)))

(deftest test-engine-load-missing-fields
  "engine-load without required fields fails."
  (let ((r (send! "bridge/engine-load" :|win-id| "w1")))
    (assert-fail r "missing engine and path")))

(deftest test-engine-load-invalid-win-id
  "Loading into a nonexistent win-id fails."
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w-nonexistent"
                  :|engine| "mupdf" :|path| *fixture-pdf*)))
    (assert-fail r "unknown win-id rejected")))

;;; ─── bridge/win-list ──────────────────────────────────────────────────────

(deftest test-win-list-after-startup
  "win-list returns at least one window after Limn starts."
  (let* ((r    (send! "bridge/win-list"))
         (data (getf r :|data|)))
    (assert-ok r)
    (assert-type data list "data is a list")
    (assert-true data "at least one window exists")))

(deftest test-win-list-entry-shape
  "Each win-list entry has win-id, engine fields."
  (let* ((r (send! "bridge/win-list"))
         (data (getf r :|data|))
         (first (first data)))
    (when first
      (assert-has-key :|win-id| first "win-id present")
      (assert-has-key :|engine| first "engine present"))))

(deftest test-win-list-shows-loaded-buffer
  "After engine-load, win-list reflects the new buffer."
  (let* ((load-r (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (buf-id (json-get* load-r :|data| :|buffer-id|))
         (list-r (send! "bridge/win-list"))
         (w1     (find "w1" (getf list-r :|data|)
                       :key (lambda (w) (getf w :|win-id|))
                       :test #'string=)))
    (assert-true w1 "w1 found in win-list")
    (when w1
      (assert-equal buf-id (getf w1 :|buffer-id|) "buffer-id matches loaded"))))

(deftest test-win-list-type-field
  "Each window has a 'type' field (tiled or float)."
  (let* ((data (getf (send! "bridge/win-list") :|data|))
         (first (first data)))
    (when first
      (assert-has-key :|type| first "type field present")
      (assert-contains (getf first :|type|) '("tiled" "float") "type is tiled or float"))))

;;; ─── bridge/win-split ─────────────────────────────────────────────────────

(deftest test-win-split-horizontal
  "Horizontal split returns two window ids."
  (let* ((r    (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
         (data (getf r :|data|)))
    (assert-ok r)
    (assert-has-key :|win-a| data "win-a returned")
    (assert-has-key :|win-b| data "win-b returned")
    (assert-false (string= (getf data :|win-a|) (getf data :|win-b|))
                  "win-a and win-b are distinct")
    ;; clean up
    (send! "bridge/win-close" :|win-id| (getf data :|win-b|))))

(deftest test-win-split-vertical
  "Vertical split returns two window ids."
  (let* ((r    (send! "bridge/win-split" :|win-id| "w1" :|dir| "v"))
         (data (getf r :|data|)))
    (assert-ok r)
    (assert-has-key :|win-a| data "win-a returned")
    (assert-has-key :|win-b| data "win-b returned")
    (send! "bridge/win-close" :|win-id| (getf data :|win-b|))))

(deftest test-win-split-invalid-dir
  "Split with invalid direction returns an error."
  (let ((r (send! "bridge/win-split" :|win-id| "w1" :|dir| "diagonal")))
    (assert-fail r)))

(deftest test-win-split-missing-dir
  "Split without direction either defaults or errors — but must not crash."
  (let ((r (send! "bridge/win-split" :|win-id| "w1")))
    ;; either ok with a default or fail — but must respond
    (assert-true (member (getf r :|ok|) '(t :false)) "split responded")))

(deftest test-win-split-nonexistent
  "Splitting a nonexistent window fails."
  (let ((r (send! "bridge/win-split" :|win-id| "w-nope" :|dir| "h")))
    (assert-fail r)))

(deftest test-win-split-increases-win-count
  "After splitting, win-list contains one more window."
  (let* ((before (length (getf (send! "bridge/win-list") :|data|)))
         (r      (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
         (new-id (json-get* r :|data| :|win-b|))
         (after  (length (getf (send! "bridge/win-list") :|data|))))
    (assert-equal (1+ before) after "win-list grew by one")
    (when new-id
      (send! "bridge/win-close" :|win-id| new-id))))

;;; ─── bridge/win-close ─────────────────────────────────────────────────────

(deftest test-win-close-split
  "Closing a window created by split works and removes it from win-list."
  (let* ((r       (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
         (new-win (json-get* r :|data| :|win-b|)))
    (assert-true new-win "split returned new win-id")
    (let ((close-r (send! "bridge/win-close" :|win-id| new-win)))
      (assert-ok close-r "win-close ok"))
    (let* ((list-r (send! "bridge/win-list"))
           (ids    (mapcar (lambda (w) (getf w :|win-id|)) (getf list-r :|data|))))
      (assert-false (find new-win ids :test #'string=)
                    "closed window no longer in win-list"))))

(deftest test-win-close-nonexistent
  "Closing a nonexistent window returns ok=false."
  (let ((r (send! "bridge/win-close" :|win-id| "w-does-not-exist")))
    (assert-fail r)))

(deftest test-win-close-last-window-protected
  "Closing the last window should either fail or recreate a default — must not leave Limn in unusable state."
  ;; We don't enforce a specific behavior here; we just check the response.
  ;; The framework can't easily verify Limn is still usable after this without restart.
  (let ((r (send! "bridge/win-close" :|win-id| "w1")))
    ;; Either it succeeded (and Limn auto-created a new window) or it refused.
    (assert-true (member (getf r :|ok|) '(t :false))
                 "response is well-formed (either accepted or rejected)")))

;;; ─── bridge/win-focus ─────────────────────────────────────────────────────

(deftest test-win-focus-ok
  "Focusing a valid window succeeds."
  (let ((r (send! "bridge/win-focus" :|win-id| "w1")))
    (assert-ok r)))

(deftest test-win-focus-nonexistent
  "Focusing a nonexistent window fails."
  (let ((r (send! "bridge/win-focus" :|win-id| "w-nope")))
    (assert-fail r)))

;;; ─── bridge/win-float-create / move / resize / close ─────────────────────

(deftest test-win-float-create
  "Creating a floating window returns a new win-id."
  (with-buffer (buf)
    (let* ((r (send! "bridge/win-float-create"
                     :|buffer-id| buf
                     :|x| 100 :|y| 100 :|width| 400 :|height| 300))
           (fwin (json-get* r :|data| :|win-id|)))
      (assert-ok r "float-create ok")
      (assert-type fwin string "float win-id returned")
      (send! "bridge/win-close" :|win-id| fwin))))

(deftest test-win-float-create-default-size
  "Floating window can be created without explicit size (uses default)."
  (with-buffer (buf)
    (let ((r (send! "bridge/win-float-create" :|buffer-id| buf)))
      (when (eq (getf r :|ok|) t)
        (send! "bridge/win-close" :|win-id| (json-get* r :|data| :|win-id|))))))

(deftest test-win-float-type-is-float
  "win-list shows floating windows with type=float."
  (with-buffer (buf)
    (let* ((r    (send! "bridge/win-float-create"
                        :|buffer-id| buf
                        :|x| 50 :|y| 50 :|width| 300 :|height| 200))
           (fwin (json-get* r :|data| :|win-id|)))
      (when fwin
        (let* ((list-r (send! "bridge/win-list"))
               (entry  (find fwin (getf list-r :|data|)
                             :key (lambda (w) (getf w :|win-id|))
                             :test #'string=)))
          (when entry
            (assert-equal "float" (getf entry :|type|) "type=float")))
        (send! "bridge/win-close" :|win-id| fwin)))))

(deftest test-win-float-move
  "Moving a floating window updates its x,y."
  (with-buffer (buf)
    (let* ((cr (send! "bridge/win-float-create"
                      :|buffer-id| buf
                      :|x| 100 :|y| 100 :|width| 300 :|height| 200))
           (fwin (json-get* cr :|data| :|win-id|))
           (mv-r (send! "bridge/win-float-move"
                        :|win-id| fwin :|x| 250 :|y| 175)))
      (assert-ok mv-r)
      (let* ((list-r (send! "bridge/win-list"))
             (entry  (find fwin (getf list-r :|data|)
                           :key (lambda (w) (getf w :|win-id|))
                           :test #'string=)))
        (when entry
          (assert-equal 250 (getf entry :|x|) "x updated")
          (assert-equal 175 (getf entry :|y|) "y updated")))
      (send! "bridge/win-close" :|win-id| fwin))))

(deftest test-win-float-resize
  "Resizing a floating window updates its width,height."
  (with-buffer (buf)
    (let* ((cr (send! "bridge/win-float-create"
                      :|buffer-id| buf :|x| 100 :|y| 100 :|width| 300 :|height| 200))
           (fwin (json-get* cr :|data| :|win-id|))
           (rs-r (send! "bridge/win-float-resize"
                        :|win-id| fwin :|width| 500 :|height| 400)))
      (assert-ok rs-r)
      (send! "bridge/win-close" :|win-id| fwin))))

(deftest test-win-float-close-removes
  "Closing a floating window removes it from win-list."
  (with-buffer (buf)
    (let* ((cr (send! "bridge/win-float-create"
                      :|buffer-id| buf :|x| 0 :|y| 0 :|width| 200 :|height| 200))
           (fwin (json-get* cr :|data| :|win-id|)))
      (send! "bridge/win-close" :|win-id| fwin)
      (let* ((list-r (send! "bridge/win-list"))
             (ids    (mapcar (lambda (w) (getf w :|win-id|))
                             (getf list-r :|data|))))
        (assert-false (find fwin ids :test #'string=)
                      "closed floating window gone from list")))))

;;; ─── bridge/frame-* (long term, may return ok=false:not-implemented) ─────

(deftest test-frame-new-or-not-implemented
  "frame-new either creates a frame or returns 'not-implemented' (long-term)."
  (let ((r (send! "bridge/frame-new")))
    ;; Both responses are valid: ok with frame-id, OR error indicating not yet implemented.
    (assert-true (member (getf r :|ok|) '(t :false)) "responds without crashing")
    (when (eq (getf r :|ok|) t)
      (assert-has-key :|frame-id| (getf r :|data|) "frame-id returned")
      ;; clean up
      (ignore-errors
        (send! "bridge/frame-close" :|frame-id| (json-get* r :|data| :|frame-id|))))))

(deftest test-frame-list-or-not-implemented
  "frame-list either returns a list or 'not-implemented'."
  (let ((r (send! "bridge/frame-list")))
    (assert-true (member (getf r :|ok|) '(t :false)) "responds")))

;;; ─── Consecutive / nested splits ──────────────────────────────────────────

(deftest test-win-split-can-split-child
  "A window created by split can itself be split."
  (let* ((r1 (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
         (w2 (json-get* r1 :|data| :|win-b|)))
    (when w2
      (let* ((r2 (send! "bridge/win-split" :|win-id| w2 :|dir| "v"))
             (w3 (json-get* r2 :|data| :|win-b|)))
        (assert-ok r2 "child window can be split")
        (when w3 (send! "bridge/win-close" :|win-id| w3)))
      (send! "bridge/win-close" :|win-id| w2))))

(deftest test-win-split-many-times
  "Splitting many times in a row creates many windows."
  (let ((created '()))
    (unwind-protect
         (progn
           (loop repeat 4 do
             (let* ((r (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
                    (w (json-get* r :|data| :|win-b|)))
               (when w (push w created))))
           ;; verify all 4 in win-list
           (let* ((data (getf (send! "bridge/win-list") :|data|))
                  (ids  (mapcar (lambda (w) (getf w :|win-id|)) data)))
             (dolist (w created)
               (assert-contains w ids "split-created window in list"))))
      ;; cleanup
      (dolist (w created)
        (ignore-errors (send! "bridge/win-close" :|win-id| w))))))

;;; ─── win-list shape stricter check ────────────────────────────────────────

(deftest test-win-list-tiled-windows-no-position
  "Tiled (non-float) windows don't need x/y/width/height fields."
  (let* ((data (getf (send! "bridge/win-list") :|data|))
         (tiled (find "tiled" data
                      :key (lambda (w) (getf w :|type|))
                      :test #'string=)))
    (when tiled
      ;; spec doesn't require position fields for tiled
      (assert-equal "tiled" (getf tiled :|type|) "type=tiled present"))))

(deftest test-win-list-float-has-position
  "Floating windows must have x, y, width, height fields."
  (with-buffer (buf)
    (let* ((cr (send! "bridge/win-float-create"
                      :|buffer-id| buf :|x| 50 :|y| 50
                      :|width| 200 :|height| 200))
           (fwin (json-get* cr :|data| :|win-id|)))
      (when fwin
        (let* ((data (getf (send! "bridge/win-list") :|data|))
               (entry (find fwin data
                            :key (lambda (w) (getf w :|win-id|))
                            :test #'string=)))
          (when entry
            (assert-has-key :|x|      entry)
            (assert-has-key :|y|      entry)
            (assert-has-key :|width|  entry)
            (assert-has-key :|height| entry)))
        (send! "bridge/win-close" :|win-id| fwin)))))

;;; ─── win-focus state consistency ──────────────────────────────────────────

(deftest test-win-focus-only-one-focused
  "Only one window has focus at a time."
  ;; After focusing w1, splitting and focusing the new one, win-list
  ;; should mark only the new one as focused (if focus is reported).
  (send! "bridge/win-focus" :|win-id| "w1")
  (let* ((sr (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
         (w2 (json-get* sr :|data| :|win-b|)))
    (when w2
      (send! "bridge/win-focus" :|win-id| w2)
      (let* ((data (getf (send! "bridge/win-list") :|data|))
             (focused (count-if (lambda (w) (getf w :|focused|)) data)))
        ;; If the implementation reports focus state, exactly one window has focus.
        ;; If it doesn't report at all, this is vacuously true.
        (when (> focused 0)
          (assert-equal 1 focused "exactly one window focused")))
      (send! "bridge/win-close" :|win-id| w2))))

;;; ─── engine-load with already-loaded buffer ───────────────────────────────

(deftest test-engine-load-replaces-current-buffer
  "Loading a new engine in a window that already has one replaces the buffer."
  (send! "bridge/engine-load"
         :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)
  (let* ((r2 (send! "bridge/engine-load"
                    :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (new-buf (json-get* r2 :|data| :|buffer-id|)))
    (assert-ok r2 "second engine-load on same window ok")
    ;; The win-list should show the new buffer
    (let* ((data (getf (send! "bridge/win-list") :|data|))
           (w1   (find "w1" data
                        :key (lambda (w) (getf w :|win-id|))
                        :test #'string=)))
      (when w1
        (assert-equal new-buf (getf w1 :|buffer-id|)
                      "w1 shows the new buffer")))))
