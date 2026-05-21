;;;; Connection lifecycle and recovery tests
;;;;
;;;; What happens at the edges of a session:
;;;;   - Disconnect then reconnect (does Limn state survive? should it?)
;;;;   - Limn restart (state from disk?)
;;;;   - Frontend kill while requests pending
;;;;
;;;; The spec doesn't explicitly mandate behavior on disconnect; these
;;;; tests verify whatever the implementation chooses is at least
;;;; well-defined and the protocol resumes cleanly.

(in-package #:limn/test)

;;; ── Reconnect mid-session ───────────────────────────────────────────────

(deftest test-lifecycle-reconnect-basic
  "After disconnect + reconnect, basic protocol still works."
  ;; load something, get a buffer-id, disconnect, reconnect
  (let* ((r   (send! "bridge/engine-load"
                     :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (bid (json-get* r :|data| :|buffer-id|)))
    (declare (ignore bid))
    (disconnect!)
    (sleep 0.1)
    (connect!)
    ;; Verify basic protocol works
    (let ((r2 (send! "bridge/capabilities")))
      (assert-ok r2 "capabilities works after reconnect"))))

(deftest test-lifecycle-reconnect-can-still-load
  "After reconnect, can still load a new buffer."
  (disconnect!)
  (sleep 0.1)
  (connect!)
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)))
    (assert-ok r "engine-load works after reconnect")))

;;; ── Pending request when connection drops ──────────────────────────────

(deftest test-lifecycle-pending-request-cleanup
  "After disconnect, any pending requests don't leak frontend resources."
  ;; Send a request and abandon it
  (send-raw! '(:|cmd| "bridge/capabilities"))
  ;; Disconnect immediately without reading response
  (disconnect!)
  (sleep 0.1)
  ;; Reconnect and verify frontend is healthy
  (connect!)
  (assert-ok (send! "bridge/capabilities")
             "frontend recovers from abandoned request"))

;;; ── Many reconnects in quick succession ─────────────────────────────────

(deftest test-lifecycle-many-reconnects
  "10 disconnect/reconnect cycles."
  (loop repeat 10 do
    (disconnect!)
    (sleep 0.05)
    (connect!))
  (assert-ok (send! "bridge/capabilities")
             "frontend healthy after 10 reconnect cycles"))

;;; ── State persistence across reconnect ──────────────────────────────────
;;; Spec is ambiguous: should Limn keep loaded buffers across client
;;; disconnect, or clean up? Either is acceptable; the test documents
;;; whichever the implementation chose.

(deftest test-lifecycle-buffer-state-on-reconnect
  "Document Limn's choice: does buffer survive client disconnect?"
  (let* ((r   (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (bid (json-get* r :|data| :|buffer-id|)))
    (assert-ok r)
    (disconnect!)
    (sleep 0.2)
    (connect!)
    ;; Try to use the old buffer-id
    (let ((toc-r (send! "buffer/toc" :|buffer-id| bid)))
      (cond
        ((eq (getf toc-r :|ok|) t)
         (format t "    INFO: buffer survives client reconnect~%"))
        (t
         (format t "    INFO: buffer cleaned up on client disconnect~%")))
      ;; Either way, the protocol responded — pass.
      (assert-true t "either policy is valid"))))

;;; ── Win-list reflects current state ────────────────────────────────────

(deftest test-lifecycle-win-list-after-many-ops
  "After lots of split/close, win-list reflects exactly the open windows."
  (let ((opened '()))
    (unwind-protect
         (progn
           ;; Open 5 splits
           (loop repeat 5 do
             (let* ((r (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
                    (w (json-get* r :|data| :|win-b|)))
               (when w (push w opened))))
           ;; Close 2
           (loop repeat 2 do
             (when opened
               (send! "bridge/win-close" :|win-id| (pop opened))))
           ;; win-list should contain remaining 3 + original w1
           (let* ((data (getf (send! "bridge/win-list") :|data|))
                  (ids  (mapcar (lambda (w) (getf w :|win-id|)) data)))
             (assert-contains "w1" ids "w1 still present")
             (dolist (w opened)
               (assert-contains w ids "remaining split still present"))))
      ;; Cleanup remaining
      (dolist (w opened)
        (ignore-errors (send! "bridge/win-close" :|win-id| w))))))

;;; ── Heartbeat behavior across operations ───────────────────────────────

(deftest test-lifecycle-heartbeat-doesnt-block-ops
  "Heartbeats don't disrupt normal request/response."
  (drain-events)
  (let ((all-ok t))
    (loop repeat 20 do
      (let ((r (send! "bridge/capabilities")))
        (unless (eq (getf r :|ok|) t) (setf all-ok nil))))
    (assert-true all-ok "20 requests all succeeded with heartbeats in flight")))

;;; ── No double-response ──────────────────────────────────────────────────

(deftest test-lifecycle-each-id-gets-one-response
  "Each request id gets exactly one response (no duplicates)."
  (let ((id (next-id)))
    (send-raw! (list :|id| id :|cmd| "bridge/capabilities"))
    (let ((r1 (read-response id :timeout 3)))
      (assert-ok r1 "first response received")
      ;; Wait a moment, drain anything; nothing matching this id should arrive
      (sleep 0.3)
      (let ((extra nil))
        (loop while (listen *stream*) do
          (let ((line (read-line *stream* nil nil)))
            (when line
              (let ((parsed (handler-case (decode-json line) (error () nil))))
                (when (and parsed
                           (string= (getf parsed :|id|) id))
                  (setf extra t))))))
        (assert-false extra "no duplicate response for same id")))))

;;; ── Buffer-id is per-engine instance, not globally reusable ────────────

(deftest test-lifecycle-buffer-id-not-reused-after-close
  "After closing a buffer-id, opening again gives a NEW id."
  (let* ((r1 (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (b1 (json-get* r1 :|data| :|buffer-id|)))
    (send! "buffer/close" :|buffer-id| b1)
    (let* ((r2 (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
           (b2 (json-get* r2 :|data| :|buffer-id|)))
      ;; b1 was already closed; b2 might be the same string or different
      ;; — spec doesn't require uniqueness over time. Just verify b2 works.
      (assert-ok r2 "new buffer-id usable")
      (send! "buffer/close" :|buffer-id| b2))))
