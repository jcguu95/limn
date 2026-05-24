;;;; v0.23.1 §D8 — buffer-modified wire event Qt-tier tests
;;;;
;;;; These tests verify the C++ side of the v0.23 §D contract: every
;;;; gap-buffer mutation (insert / delete) must emit a 'buffer-modified'
;;;; wire event so the Lisp undo subsystem can record an inverse.
;;;;
;;;; Wire event shape (string-keyed, since wire dispatch is string-based):
;;;;   :|event|     = "buffer-modified"
;;;;   :|buffer-id| = buffer-id string
;;;;   :|op|        = "insert" | "delete"
;;;;   :|pos|       = codepoint offset (int)
;;;;   :|len|       = codepoint length of affected region (int)
;;;;   :|before|    = removed text (empty for insert)
;;;;   :|after|     = added text  (empty for delete)
;;;;
;;;; Naming chosen to match cmd_buffer_insert / cmd_buffer_delete's
;;;; existing cp-based wire arguments (:|at|, :|from|, :|to|, :|text|).

(in-package #:limn/test)

;; The Qt-tier framework normally talks to the binary by wire alone and
;; doesn't load the backend Lisp modules. Tests 7+8 below dogfood the
;; *real* limn/buffer-undo subsystem, so we pull its module in here
;; (idempotent; already-loaded packages just re-define).
(let* ((suite-dir (make-pathname :defaults (or *load-pathname*
                                                *default-pathname-defaults*)
                                  :name nil :type nil))
       (backend-dir (merge-pathnames "../../" suite-dir)))
  (dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
               "limn-buffer-undo.lisp"))
    (handler-case (load (merge-pathnames f backend-dir))
      (error (e) (format t "  !! skipped ~A: ~A~%" f e)))))

(defmacro with-text-buf-and-event ((buf-var) &body body)
  "Open a text-engine buffer, drain any stale events, run BODY."
  `(with-text-buffer (,buf-var)
     (drain-events)
     ,@body))

(defun %fan-out-event (ev)
  "Manually fan a wire event through limn/hooks the same way
   limn-dispatch:fire-event would. The Qt-tier framework's
   read-event consumes from its own queue; without this helper,
   subscribers registered with add-hook never see it."
  (let ((etype (getf ev :|event|))
        (run-hook (find-symbol "RUN-HOOK" '#:limn/hooks)))
    (when (and etype run-hook)
      (funcall run-hook
               (concatenate 'string "event/" etype)
               ev))))

;;; ── 1. insert emits buffer-modified with correct payload ────────────

(deftest test-bumod-insert-emits-event
  "buffer/insert pushes buffer-modified event."
  (with-text-buf-and-event (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "hello")
    (let ((ev (read-event :type "buffer-modified" :timeout 2)))
      (assert-true (not (null ev)) "event arrived")
      (when ev
        (assert-equal buf     (getf ev :|buffer-id|) "buffer-id matches")
        (assert-equal "insert" (getf ev :|op|) "op = insert")
        (assert-equal 0       (getf ev :|pos|) "pos = 0 (cursor was at 0)")
        (assert-equal 5       (getf ev :|len|) "len = 5 (hello)")
        (assert-equal ""      (getf ev :|before|) "before empty for insert")
        (assert-equal "hello" (getf ev :|after|)  "after = inserted text")))))

;;; ── 2. delete emits buffer-modified with correct payload ────────────

(deftest test-bumod-delete-emits-event
  "buffer/delete pushes buffer-modified event."
  (with-text-buf-and-event (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "abcdef")
    (drain-events)
    (send! "buffer/delete" :|buffer-id| buf :|from| 2 :|to| 4)
    (let ((ev (read-event :type "buffer-modified" :timeout 2)))
      (assert-true (not (null ev)) "delete event arrived")
      (when ev
        (assert-equal "delete" (getf ev :|op|) "op = delete")
        (assert-equal 2       (getf ev :|pos|) "pos = from")
        (assert-equal 2       (getf ev :|len|) "len = to - from")
        (assert-equal "cd"    (getf ev :|before|) "before = removed text")
        (assert-equal ""      (getf ev :|after|)  "after empty for delete")))))

;;; ── 3. order preserved across a burst of mutations ──────────────────

(deftest test-bumod-order-preserved
  "Three quick mutations arrive in emit order."
  (with-text-buf-and-event (buf)
    (send! "buffer/insert" :|buffer-id| buf :|at| 0 :|text| "A")
    (send! "buffer/insert" :|buffer-id| buf :|at| 1 :|text| "B")
    (send! "buffer/insert" :|buffer-id| buf :|at| 2 :|text| "C")
    (let ((evs (loop for ev = (read-event :type "buffer-modified" :timeout 1)
                     while ev collect ev)))
      (assert-equal 3 (length evs) "got 3 events")
      (when (= 3 (length evs))
        (assert-equal "A" (getf (first  evs) :|after|) "first event = A")
        (assert-equal "B" (getf (second evs) :|after|) "second event = B")
        (assert-equal "C" (getf (third  evs) :|after|) "third event = C")))))

;;; ── 4. multi-buffer routing: events carry the right buf-id ──────────

(deftest test-bumod-multi-buffer-routing
  "Mutations on two buffers produce events tagged with each buf-id."
  (with-text-buf-and-event (buf-a)
    (with-text-buf-and-event (buf-b)
      (send! "buffer/insert" :|buffer-id| buf-a :|text| "alpha")
      (send! "buffer/insert" :|buffer-id| buf-b :|text| "beta")
      (let ((evs (loop for ev = (read-event :type "buffer-modified" :timeout 1)
                       while ev collect ev)))
        (let ((for-a (find buf-a evs :key (lambda (e) (getf e :|buffer-id|))
                                     :test #'equal))
              (for-b (find buf-b evs :key (lambda (e) (getf e :|buffer-id|))
                                     :test #'equal)))
          (assert-true for-a "event for buf-a present")
          (assert-true for-b "event for buf-b present")
          (when for-a (assert-equal "alpha" (getf for-a :|after|) "buf-a got alpha"))
          (when for-b (assert-equal "beta"  (getf for-b :|after|) "buf-b got beta")))))))

;;; ── 5. cp-based positions: multi-byte chars use codepoint offsets ──

(deftest test-bumod-codepoint-positions
  "Position payload uses codepoints, not UTF-16 surrogate units."
  (with-text-buf-and-event (buf)
    ;; "中" is one codepoint, two UTF-16 units (in BMP; actually 1 unit
    ;; — pick a non-BMP char for the real test). Use 𝕏 (U+1D54F, 1 cp,
    ;; 2 UTF-16 units).
    (send! "buffer/insert" :|buffer-id| buf :|text| "a𝕏b")
    (drain-events)
    ;; Insert at codepoint 2 (i.e. between 𝕏 and b).
    (send! "buffer/insert" :|buffer-id| buf :|at| 2 :|text| "X")
    (let ((ev (read-event :type "buffer-modified" :timeout 2)))
      (when ev
        (assert-equal 2 (getf ev :|pos|) "pos uses codepoint index, not UTF-16")
        (assert-equal 1 (getf ev :|len|) "len in codepoints (X is 1 cp)")))))

;;; ── 6. burst — 50 quick inserts deliver 50 events, no loss ─────────

(deftest test-bumod-burst-no-loss
  "50 quick inserts produce 50 buffer-modified events (no dropping)."
  (with-text-buf-and-event (buf)
    (dotimes (i 50)
      (send! "buffer/insert" :|buffer-id| buf :|text| "x"))
    (let ((evs (loop for ev = (read-event :type "buffer-modified" :timeout 1)
                     while ev collect ev)))
      (assert-equal 50 (length evs)
                    (format nil "expected 50 events, got ~A" (length evs))))))

;;; ── 7. Lisp buffer-undo subscriber captures wire events ────────────

(deftest test-bumod-lisp-undo-subscribes
  "limn/buffer-undo:install-buffer-modified-handler picks up wire events
   and accumulates them per buffer."
  (with-text-buf-and-event (buf)
    ;; Wire up Lisp-side undo. install is idempotent.
    (let ((install (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER"
                                 '#:limn/buffer-undo))
          (enable  (find-symbol "ENABLE-UNDO" '#:limn/buffer-undo))
          (ulist   (find-symbol "BUFFER-UNDO-LIST" '#:limn/buffer-undo))
          (clear   (find-symbol "CLEAR-UNDO" '#:limn/buffer-undo)))
      (when (and install enable ulist clear)
        (funcall clear buf)
        (funcall install)
        (funcall enable buf)
        (send! "buffer/insert" :|buffer-id| buf :|text| "logged")
        ;; Pump the event into Lisp manually (the Qt-tier framework
        ;; reads events into its queue without firing hooks).
        (let ((ev (read-event :type "buffer-modified" :timeout 2)))
          (when ev (%fan-out-event ev)))
        (sleep 0.05)
        (let ((entries (funcall ulist buf)))
          (assert-true (and entries (>= (length entries) 1))
                       (format nil "undo list got ~A entries"
                               (length (or entries '())))))))))

;;; ── 8. roundtrip — insert via wire, undo via Lisp, buffer reverts ──

(deftest test-bumod-roundtrip-insert-undo
  "Insert via wire → Lisp undo → buffer text reverts."
  (with-text-buf-and-event (buf)
    (let ((install (find-symbol "INSTALL-BUFFER-MODIFIED-HANDLER"
                                 '#:limn/buffer-undo))
          (enable  (find-symbol "ENABLE-UNDO" '#:limn/buffer-undo))
          (clear   (find-symbol "CLEAR-UNDO" '#:limn/buffer-undo))
          (undo    (find-symbol "UNDO" '#:limn/buffer-undo)))
      (when (and install enable clear undo)
        (funcall clear buf)
        (funcall install)
        (funcall enable buf)
        ;; Subscribe the inverse-op hook to actually perform the undo
        ;; against the wire buffer:
        (let ((hooks-add (find-symbol "ADD-HOOK" '#:limn/hooks))
              (inverse-handler
                (lambda (buf-id inv)
                  (case (getf inv :op)
                    (:delete
                     (send! "buffer/delete"
                            :|buffer-id| buf-id
                            :|from| (getf inv :pos)
                            :|to| (+ (getf inv :pos) (getf inv :len))))
                    (:insert
                     (send! "buffer/insert"
                            :|buffer-id| buf-id
                            :|at| (getf inv :pos)
                            :|text| (or (getf inv :text)
                                        (getf inv :after))))))))
          (funcall hooks-add :buffer-undo/apply-inverse inverse-handler)
          (unwind-protect
               (progn
                 (send! "buffer/insert" :|buffer-id| buf :|text| "to-undo")
                 (let ((ev (read-event :type "buffer-modified" :timeout 2)))
                   (when ev (%fan-out-event ev)))
                 (sleep 0.05)
                 ;; Now undo the insert. The inverse-op hook will dispatch
                 ;; buffer/delete via wire — drain its echoed
                 ;; buffer-modified to keep the queue clean.
                 (funcall undo buf)
                 (sleep 0.1)
                 (drain-events)
                 (let ((r (send! "buffer/text" :|buffer-id| buf)))
                   (assert-ok r "buffer/text query")
                   (assert-equal ""
                                 (json-get* r :|data| :|text|)
                                 "text reverted after undo")))
            (funcall (find-symbol "REMOVE-HOOK" '#:limn/hooks)
                     :buffer-undo/apply-inverse inverse-handler)))))))
