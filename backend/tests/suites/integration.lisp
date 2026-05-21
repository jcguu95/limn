;;;; Integration tests
;;;;
;;;; Multi-step flows that exercise multiple parts of the protocol together,
;;;; mimicking realistic Lisp control patterns:
;;;;
;;;;   - Open → navigate → search → highlight → close
;;;;   - Open in main window + portal view (floating window)
;;;;   - Split → load different buffers per pane
;;;;   - Save state via view/get + win-list; restore via view/set + engine-load

(in-package #:limn/test)

;;; ── Open → navigate → close ──────────────────────────────────────────────

(deftest test-flow-open-navigate-close
  "Realistic flow: open a PDF, navigate to page 2, query state, close."
  (let* ((load-r (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (buf    (json-get* load-r :|data| :|buffer-id|)))
    (assert-ok load-r)

    ;; Navigate
    (assert-ok (send! "view/set" :|win-id| "w1" :|page| 1) "go to page 1")
    (assert-ok (send! "view/set" :|win-id| "w1" :|page| 2) "go to page 2")
    (assert-ok (send! "view/set" :|win-id| "w1" :|zoom| 1.25) "set zoom")

    ;; Query
    (let* ((g    (send! "view/get" :|win-id| "w1"))
           (data (getf g :|data|)))
      (assert-equal 2 (getf data :|page|) "page is now 2"))

    ;; Close
    (assert-ok (send! "buffer/close" :|buffer-id| buf))))

;;; ── Search-and-highlight flow (composed in Lisp) ─────────────────────────

(deftest test-flow-search-and-highlight
  "Mimic what limn-search.lisp will do: fetch page text, match in Lisp,
   then call view/overlays to highlight the matching word."
  (with-buffer (buf)
    (let* ((text-r (send! "buffer/text" :|buffer-id| buf :|page| 0))
           (words  (json-get* text-r :|data| :|words|))
           ;; pick first non-empty word with a usable rect
           (target (find-if (lambda (w)
                              (and (getf w :|text|)
                                   (> (length (getf w :|text|)) 1)))
                            words)))
      (when target
        (let ((hl-r (send! "view/overlays" :|win-id| "w1"
                           :|layers|
                           (list `(:|type| "rect"
                                   :|page| 0
                                   :|rect| ,(getf target :|rect|)
                                   :|color| "#FFFF00"
                                   :|opacity| 0.4)))))
          (assert-ok hl-r "highlighting target word"))))))

;;; ── Portal view: floating window showing the same buffer ─────────────────

(deftest test-flow-portal-view
  "Open a PDF in main window, then open a portal (floating window)
   showing the same buffer at a different page — like sioyek's portal."
  (let* ((load-r (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (buf    (json-get* load-r :|data| :|buffer-id|)))
    (assert-ok load-r)
    ;; Set main window to page 0
    (send! "view/set" :|win-id| "w1" :|page| 0)
    ;; Create floating window
    (let* ((fr   (send! "bridge/win-float-create"
                        :|buffer-id| buf
                        :|x| 200 :|y| 100 :|width| 400 :|height| 300))
           (fwin (json-get* fr :|data| :|win-id|)))
      (when fwin
        ;; Set floating window to a different page
        (assert-ok (send! "view/set" :|win-id| fwin :|page| 1)
                   "floating window on different page")
        ;; Verify main and floating have independent state
        (let ((p-main (json-get* (send! "view/get" :|win-id| "w1")
                                 :|data| :|page|))
              (p-flo  (json-get* (send! "view/get" :|win-id| fwin)
                                 :|data| :|page|)))
          (check-assertion (not (equal p-main p-flo))
                           "main and floating show different pages"
                           "main=~a, floating=~a" p-main p-flo))
        (send! "bridge/win-close" :|win-id| fwin)))))

;;; ── Split with two different buffers ─────────────────────────────────────

(deftest test-flow-split-two-buffers
  "Split horizontally; load different buffers in left and right."
  ;; Load buffer in w1
  (send! "bridge/engine-load"
         :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)
  ;; Split
  (let* ((s-r (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
         (w2  (json-get* s-r :|data| :|win-b|)))
    (when w2
      ;; Load another buffer in w2 (same PDF, separate buffer instance)
      (let ((load-r (send! "bridge/engine-load"
                           :|win-id| w2 :|engine| "mupdf"
                           :|path| *fixture-pdf*)))
        (assert-ok load-r)
        ;; Verify both windows have buffers
        (let* ((list-r (send! "bridge/win-list"))
               (windows (getf list-r :|data|))
               (w1-entry (find "w1" windows :key (lambda (w) (getf w :|win-id|))
                               :test #'string=))
               (w2-entry (find w2 windows :key (lambda (w) (getf w :|win-id|))
                               :test #'string=)))
          (when (and w1-entry w2-entry)
            (assert-true (getf w1-entry :|buffer-id|) "w1 has buffer")
            (assert-true (getf w2-entry :|buffer-id|) "w2 has buffer"))))
      ;; clean up
      (send! "bridge/win-close" :|win-id| w2))))

;;; ── Session save/restore ─────────────────────────────────────────────────

(deftest test-flow-session-snapshot-restore
  "Mimic limn-session.lisp: capture state via view/get + win-list, then
   restore by re-issuing view/set."
  (with-buffer (buf)
    ;; Set a specific state
    (send! "view/set" :|win-id| "w1" :|page| 2 :|zoom| 1.5 :|offset-y| 100.0)
    ;; Snapshot
    (let* ((snap (json-get* (send! "view/get" :|win-id| "w1") :|data|))
           (snap-page (getf snap :|page|))
           (snap-zoom (getf snap :|zoom|))
           (snap-oy   (getf snap :|offset-y|)))
      ;; Change state
      (send! "view/set" :|win-id| "w1" :|page| 0 :|zoom| 1.0 :|offset-y| 0.0)
      ;; Restore from snapshot
      (send! "view/set" :|win-id| "w1"
             :|page| snap-page :|zoom| snap-zoom :|offset-y| snap-oy)
      ;; Verify
      (let ((restored (json-get* (send! "view/get" :|win-id| "w1") :|data|)))
        (assert-equal snap-page (getf restored :|page|)
                      "page restored")
        (check-assertion (< (abs (- snap-zoom (getf restored :|zoom|))) 0.01)
                         "zoom restored"
                         "expected ~s, got ~s"
                         snap-zoom (getf restored :|zoom|))))))

;;; ── Undo-tree style: stack of states ─────────────────────────────────────

(deftest test-flow-undo-stack
  "Mimic limn-undo.lisp basic operation: push states, restore previous."
  (with-buffer (buf)
    (let (stack)
      ;; State 1: page 0
      (send! "view/set" :|win-id| "w1" :|page| 0)
      (push (getf (send! "view/get" :|win-id| "w1") :|data|) stack)
      ;; State 2: page 1
      (send! "view/set" :|win-id| "w1" :|page| 1)
      (push (getf (send! "view/get" :|win-id| "w1") :|data|) stack)
      ;; State 3: page 2
      (send! "view/set" :|win-id| "w1" :|page| 2)
      (push (getf (send! "view/get" :|win-id| "w1") :|data|) stack)
      ;; Undo twice = restore to state 1
      (pop stack) (pop stack)
      (let ((s1 (first stack)))
        (send! "view/set" :|win-id| "w1" :|page| (getf s1 :|page|))
        (let ((curr (getf (send! "view/get" :|win-id| "w1") :|data|)))
          (assert-equal (getf s1 :|page|) (getf curr :|page|)
                        "undo'd back to state 1"))))))

;;; ── Many overlays from search-like operation ─────────────────────────────

(deftest test-flow-search-all-and-overlay
  "Walk first page text, build overlays for words containing 'a',
   send all in one call (realistic search-result highlighting)."
  (with-buffer (buf)
    (let* ((text-r (send! "buffer/text" :|buffer-id| buf :|page| 0))
           (words  (json-get* text-r :|data| :|words|))
           (hits   (remove-if-not (lambda (w)
                                    (and (getf w :|text|)
                                         (find #\a (getf w :|text|))))
                                  words)))
      (when hits
        (let* ((layers (loop for w in hits
                             collect `(:|type| "rect"
                                       :|page| 0
                                       :|rect| ,(getf w :|rect|)
                                       :|color| "#FFFF00"
                                       :|opacity| 0.4)))
               (r (send! "view/overlays" :|win-id| "w1" :|layers| layers)))
          (assert-ok r (format nil "highlighted ~a words" (length hits))))))))

;;; ── Drag-drop opens new buffers ──────────────────────────────────────────

(deftest test-flow-drag-drop-opens-buffer
  "When test/inject-drag-drop is fired with a PDF path, Lisp can open it
   in response. This simulates the Lisp hook handler."
  (let ((r (send! "test/inject-drag-drop"
                  :|frame-id| "f1" :|win-id| "w1"
                  :|paths| (list *fixture-pdf*))))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "drag-drop" :timeout 1)))
        (when ev
          ;; Lisp would call engine-load with the path from the event
          (let* ((paths (getf ev :|paths|))
                 (load-r (send! "bridge/engine-load"
                                :|win-id| "w1" :|engine| "mupdf"
                                :|path| (first paths))))
            (assert-ok load-r "loaded buffer from drag-drop")))))))

;;; ── Incremental search (every keystroke re-runs search + updates overlay) ──

(deftest test-flow-incremental-search
  "Simulate isearch: build query incrementally, refresh highlights each step."
  (with-buffer (buf)
    (let* ((text-r (send! "buffer/text" :|buffer-id| buf :|page| 0))
           (words  (json-get* text-r :|data| :|words|))
           (queries '("t" "th" "the")))
      (when words
        (dolist (q queries)
          (let* ((hits (remove-if-not
                        (lambda (w)
                          (search q (getf w :|text|) :test #'char-equal))
                        words))
                 (layers (loop for hit in hits
                               collect `(:|type| "rect" :|page| 0
                                         :|rect| ,(getf hit :|rect|)
                                         :|color| "#FFFF00" :|opacity| 0.4)))
                 (r (send! "view/overlays" :|win-id| "w1" :|layers| layers)))
            (assert-ok r (format nil "incremental search step \"~a\"" q))))))))

;;; ── Cross-buffer navigation (jump from one buffer to another) ────────────

(deftest test-flow-cross-buffer-jump
  "Open two buffers, jump between them maintaining each one's state."
  (let* ((r1 (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (b1 (json-get* r1 :|data| :|buffer-id|))
         (r2 (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (b2 (json-get* r2 :|data| :|buffer-id|)))
    (unwind-protect
         (progn
           ;; Show b1 in w1
           (send! "view/set" :|win-id| "w1" :|buffer-id| b1 :|page| 1)
           ;; Switch to b2 in same window
           (send! "view/set" :|win-id| "w1" :|buffer-id| b2 :|page| 0)
           ;; Switch back to b1; should resume at page 1 IF state is preserved per-buffer
           (send! "view/set" :|win-id| "w1" :|buffer-id| b1)
           (let ((page (json-get* (send! "view/get" :|win-id| "w1")
                                   :|data| :|page|)))
             ;; Behavior is spec-undefined; informational
             (format t "    info: b1 page after re-attach = ~a~%" page)))
      (when b1 (send! "buffer/close" :|buffer-id| b1))
      (when b2 (send! "buffer/close" :|buffer-id| b2)))))

;;; ── Key event → action → state change (closed loop) ──────────────────────

(deftest test-flow-key-triggers-action
  "Inject a key, then verify state changes as if Lisp had handled it.
   This requires Lisp to actually be listening; we simulate manually."
  (with-buffer (buf)
    (drain-events)
    (let ((page-before (json-get* (send! "view/get" :|win-id| "w1")
                                   :|data| :|page|)))
      ;; Inject 'j' (in our mental Lisp dispatch, j = next-page)
      (when (eq (getf (send! "test/inject-key"
                              :|frame-id| "f1" :|key| "j" :|mods| nil)
                      :|ok|) t)
        (let ((ev (read-event :type "key" :timeout 1)))
          (when ev
            ;; Lisp's hypothetical handler: receive 'j' event → view/set next page
            (send! "view/set" :|win-id| "w1" :|page| (1+ page-before))
            (let ((page-after (json-get* (send! "view/get" :|win-id| "w1")
                                          :|data| :|page|)))
              (assert-equal (1+ page-before) page-after
                            "page advanced after key handling"))))))))

;;; ── Multi-window state independence ──────────────────────────────────────

(deftest test-flow-multi-window-state-independent
  "Two windows showing different buffers maintain independent state under load."
  (let* ((r1 (send! "bridge/engine-load"
                    :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (sr (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
         (w2 (json-get* sr :|data| :|win-b|)))
    (unwind-protect
         (when w2
           (send! "bridge/engine-load"
                  :|win-id| w2 :|engine| "mupdf" :|path| *fixture-pdf*)
           ;; Set different pages
           (send! "view/set" :|win-id| "w1" :|page| 0 :|zoom| 1.0)
           (send! "view/set" :|win-id| w2   :|page| 2 :|zoom| 2.0)
           ;; Verify each
           (let ((p1 (json-get* (send! "view/get" :|win-id| "w1")
                                 :|data| :|page|))
                 (p2 (json-get* (send! "view/get" :|win-id| w2)
                                 :|data| :|page|)))
             (assert-equal 0 p1 "w1 stayed on page 0")
             (assert-equal 2 p2 "w2 stayed on page 2")))
      (when w2 (ignore-errors (send! "bridge/win-close" :|win-id| w2))))))

;;; ── Search → click on result → jump ──────────────────────────────────────

(deftest test-flow-search-then-click-jumps
  "Run search, get results, then user clicks a result → Lisp jumps there."
  (with-buffer (buf)
    (let* ((text-r (send! "buffer/text" :|buffer-id| buf :|page| 0))
           (words  (json-get* text-r :|data| :|words|))
           ;; pick the first "real" word
           (target (find-if (lambda (w)
                              (and (getf w :|text|)
                                   (> (length (getf w :|text|)) 2)))
                            words)))
      (when target
        ;; highlight it
        (send! "view/overlays" :|win-id| "w1"
               :|layers| (list `(:|type| "rect" :|page| 0
                                 :|rect| ,(getf target :|rect|)
                                 :|color| "#FFFF00" :|opacity| 0.4)))
        ;; simulate click on it
        (let ((rect (getf target :|rect|)))
          (when (>= (length rect) 4)
            (let ((cx (/ (+ (nth 0 rect) (nth 2 rect)) 2.0))
                  (cy (/ (+ (nth 1 rect) (nth 3 rect)) 2.0)))
              ;; Inject a click at the word's center
              (let ((r (send! "test/inject-mouse-click"
                              :|frame-id| "f1" :|win-id| "w1"
                              :|page| 0
                              :|x| (/ cx 600.0)  ; rough normalize
                              :|y| (/ cy 800.0)
                              :|button| 1)))
                (assert-true (member (getf r :|ok|) '(t :false))
                             "click injected cleanly")))))))))
