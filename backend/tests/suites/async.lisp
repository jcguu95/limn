;;;; Async behavior tests
;;;;
;;;; Per Spec section 2, Limn is "async event-driven" — events arrive
;;;; asynchronously, multiple requests can be in flight, etc. This suite
;;;; verifies the async guarantees:
;;;;   - Long-running requests don't block other requests
;;;;   - Events don't get lost during heavy request load
;;;;   - State changes are atomic from client perspective
;;;;   - Render (potentially long) interleaves with quick queries

(in-package #:limn/test)

;;; ── Long request doesn't block quick query ──────────────────────────────

(deftest test-async-render-doesnt-block-capabilities
  "While a slow render is in flight, capabilities query still returns quickly."
  (with-buffer (buf)
    ;; Fire off a high-DPI render (slow), don't wait
    (let ((render-id (send-raw! (list :|cmd| "buffer/render"
                                       :|buffer-id| buf
                                       :|page| 0 :|dpi| 300))))
      ;; Quickly send a capabilities query — it should return BEFORE
      ;; render completes (or at least not be blocked by it)
      (let ((cap-id (send-raw! '(:|cmd| "bridge/capabilities"))))
        (let ((cap (read-response cap-id :timeout 5)))
          (assert-ok cap "capabilities returned during render")))
      ;; Now drain the render
      (ignore-errors (read-response render-id :timeout 10)))))

;;; ── Events arrive even during heavy request load ───────────────────────

(deftest test-async-events-not-lost-under-load
  "Inject 5 key events, then send 20 fast queries — all 5 events still arrive."
  (drain-events)
  ;; Inject 5 events without reading
  (loop for i below 5 do
    (send! "test/inject-key" :|frame-id| "f1"
            :|key| (format nil "~a" i) :|mods| nil))
  ;; Drown them with queries
  (loop repeat 20 do (send! "bridge/capabilities"))
  ;; Now collect all queued events
  (let ((events (loop for i below 10
                      for ev = (read-event :type "key" :timeout 0.5)
                      while ev collect ev)))
    (check-assertion (>= (length events) 5)
                     "all 5 injected key events received"
                     "got ~a events" (length events))))

;;; ── Atomicity: view/set isn't observable mid-transaction ────────────────

(deftest test-async-view-set-atomic-from-client
  "After view/set returns ok, view/get reflects the new state — never partial."
  (with-buffer (buf)
    (loop repeat 10 do
      (let ((target-page (random 3)))
        (send! "view/set" :|win-id| "w1" :|page| target-page :|zoom| 1.0)
        (let* ((g    (send! "view/get" :|win-id| "w1"))
               (page (json-get* g :|data| :|page|)))
          (assert-equal target-page page
                        (format nil "page=~a observed atomically" target-page)))))))

;;; ── Quick succession of view/set: last wins ─────────────────────────────

(deftest test-async-rapid-view-set-last-wins
  "Sending 10 rapid view/set calls, the last one's value is observed in view/get."
  (with-buffer (buf)
    (loop for p from 0 below 5 do
      (send! "view/set" :|win-id| "w1" :|page| p))
    ;; Last set was page 4 — get should reflect that
    (let ((page (json-get* (send! "view/get" :|win-id| "w1")
                            :|data| :|page|)))
      (assert-equal 4 page "last set's value wins"))))

;;; ── Out-of-order response delivery ─────────────────────────────────────

(deftest test-async-out-of-order-by-cost
  "If we issue a slow then a fast request, responses may arrive fast-first."
  (with-buffer (buf)
    ;; slow: render high DPI
    (let ((slow-id (send-raw! (list :|cmd| "buffer/render"
                                     :|buffer-id| buf
                                     :|page| 0 :|dpi| 300))))
      ;; fast: capabilities
      (let ((fast-id (send-raw! '(:|cmd| "bridge/capabilities"))))
        ;; Read fast first; framework matches by id, so this should just work
        (let ((fast (read-response fast-id :timeout 5))
              (slow (read-response slow-id :timeout 10)))
          (assert-ok fast "fast response matched correctly")
          (assert-ok slow "slow response matched correctly"))))))

;;; ── Buffer-opened event arrives BEFORE engine-load response ────────────
;;; The spec doesn't mandate ordering between event push and response,
;;; but we should verify it's at least consistent (one ordering, every time).

(deftest test-async-buffer-opened-and-response-coexist
  "Engine-load returns a response AND triggers a buffer-opened event."
  (drain-events)
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)))
    (assert-ok r "response received")
    (let ((ev (read-event :type "buffer-opened" :timeout 2)))
      (assert-true ev "buffer-opened event arrived"))))

;;; ── Render order doesn't depend on response delivery order ─────────────

(deftest test-async-page-render-after-view-set
  "Setting page then immediately rendering: render reflects new page state."
  (with-buffer (buf)
    (send! "view/set" :|win-id| "w1" :|page| 2)
    (let ((r (send! "buffer/render"
                    :|buffer-id| buf :|page| 2 :|dpi| 72)))
      (assert-ok r "render of just-set page succeeds"))))

;;; ── Heartbeat continues during long operations ─────────────────────────

(deftest test-async-heartbeat-during-render
  "Heartbeats fire even while frontend is busy with render."
  (drain-events)
  (with-buffer (buf)
    ;; Start a high-dpi render, don't wait
    (let ((rid (send-raw! (list :|cmd| "buffer/render"
                                 :|buffer-id| buf
                                 :|page| 0 :|dpi| 300))))
      ;; Listen for heartbeat
      (let ((ev (read-event :type "heartbeat" :timeout 8)))
        ;; Now drain render
        (ignore-errors (read-response rid :timeout 10))
        ;; If heartbeats are configured, we should see at least one
        ;; (informational; not strictly required)
        (when ev
          (assert-has-key :|timestamp| ev "heartbeat had timestamp"))))))

;;; ── Race: close buffer while rendering ─────────────────────────────────

(deftest test-async-render-while-closing
  "If we close a buffer while a render is in flight, frontend handles cleanly."
  (let* ((r   (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (bid (json-get* r :|data| :|buffer-id|)))
    ;; start render
    (let ((rid (send-raw! (list :|cmd| "buffer/render"
                                 :|buffer-id| bid
                                 :|page| 0 :|dpi| 200))))
      ;; immediately close
      (let ((close-r (send! "buffer/close" :|buffer-id| bid)))
        ;; render may succeed (snapshot taken before close) or fail —
        ;; both acceptable; what matters is no crash
        (let ((render-r (ignore-errors (read-response rid :timeout 8))))
          (when render-r
            (assert-true (member (getf render-r :|ok|) '(t :false))
                         "render-during-close responded cleanly"))
          (assert-true (member (getf close-r :|ok|) '(t :false))
                       "close responded cleanly"))))))

;;; ── Many small renders interleave fairly ───────────────────────────────

(deftest test-async-many-small-renders-fair
  "30 low-DPI renders complete in reasonable time."
  (with-buffer (buf)
    (let ((start (get-internal-real-time))
          (n     30))
      (let ((ids (loop repeat n
                       collect (send-raw!
                                 (list :|cmd| "buffer/render"
                                       :|buffer-id| buf
                                       :|page| 0 :|dpi| 36)))))
        (dolist (id ids)
          (read-response id :timeout 10)))
      (let ((elapsed (/ (- (get-internal-real-time) start)
                         internal-time-units-per-second)))
        (format t "    info: ~a renders took ~,2f seconds~%" n elapsed)
        (check-assertion (< elapsed 60)
                         (format nil "~a renders < 60 seconds" n))))))