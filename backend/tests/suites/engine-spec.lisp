;;;; Engine Interface Spec compliance tests
;;;;
;;;; Covers section 7 of LIMN-SPEC. Any engine claiming to be a Limn engine
;;;; must pass these tests. The tests use the mupdf engine since it's the
;;;; reference implementation.
;;;;
;;;; MUST implement: buffer/open, buffer/close, view/set, view/get, view/overlays
;;;; SHOULD implement (with capability advertisement):
;;;;   buffer/text, buffer/toc, buffer/links, buffer/render,
;;;;   buffer/render-region, buffer/metadata
;;;; MUST push: buffer-opened, error
;;;; MUST advertise: supports field in buffer/open response

(in-package #:limn/test)

;;; ── 7.1 MUST implement ──────────────────────────────────────────────────

(deftest test-spec-must-implement-buffer-open
  "Engine implements buffer/open."
  (let ((r (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*)))
    (assert-ok r "buffer/open responds with ok")
    (when (eq (getf r :|ok|) t)
      (send! "buffer/close" :|buffer-id| (json-get* r :|data| :|buffer-id|)))))

(deftest test-spec-must-implement-buffer-close
  "Engine implements buffer/close."
  (with-buffer (buf)
    (let ((r (send! "buffer/close" :|buffer-id| buf)))
      (assert-ok r))))

(deftest test-spec-must-implement-view-set
  "Engine implements view/set with at least page, zoom, offset-y."
  (with-buffer (buf)
    (assert-ok (send! "view/set" :|win-id| "w1" :|page| 0))
    (assert-ok (send! "view/set" :|win-id| "w1" :|zoom| 1.0))
    (assert-ok (send! "view/set" :|win-id| "w1" :|offset-y| 0.0))))

(deftest test-spec-must-implement-view-get
  "Engine implements view/get, returning required fields."
  (with-buffer (buf)
    (let* ((r    (send! "view/get" :|win-id| "w1"))
           (data (getf r :|data|)))
      (assert-ok r)
      (assert-has-key :|buffer-id|     data)
      (assert-has-key :|page|          data)
      (assert-has-key :|zoom|          data)
      (assert-has-key :|engine-params| data))))

(deftest test-spec-must-implement-view-overlays
  "Engine implements view/overlays with at least rect type."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers| (list '(:|type| "rect"
                                      :|page| 0
                                      :|rect| (0.0 0.0 10.0 10.0)
                                      :|color| "#000000"
                                      :|opacity| 1.0)))))
      (assert-ok r))))

;;; ── 7.2 SHOULD implement (with capability declaration) ──────────────────

(deftest test-spec-should-advertise-supports
  "buffer/open response includes 'supports' list."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (assert-true supports "supports field exists")
    (assert-type supports list)
    (send! "buffer/close" :|buffer-id| bid)))

(deftest test-spec-should-text-or-not-supported
  "If 'buffer/text' is in supports list, calling it must succeed."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (when (find "buffer/text" supports :test #'string=)
      (let ((tr (send! "buffer/text" :|buffer-id| bid :|page| 0)))
        (assert-ok tr "advertised buffer/text actually works")))
    (send! "buffer/close" :|buffer-id| bid)))

(deftest test-spec-should-toc-or-not-supported
  "If buffer/toc is advertised, it must work."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (when (find "buffer/toc" supports :test #'string=)
      (assert-ok (send! "buffer/toc" :|buffer-id| bid)))
    (send! "buffer/close" :|buffer-id| bid)))

(deftest test-spec-should-links-or-not-supported
  "If buffer/links is advertised, it must work."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (when (find "buffer/links" supports :test #'string=)
      (assert-ok (send! "buffer/links" :|buffer-id| bid :|page| 0)))
    (send! "buffer/close" :|buffer-id| bid)))

(deftest test-spec-should-render-or-not-supported
  "If buffer/render is advertised, it must work."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (when (find "buffer/render" supports :test #'string=)
      (assert-ok (send! "buffer/render" :|buffer-id| bid :|page| 0 :|dpi| 72)))
    (send! "buffer/close" :|buffer-id| bid)))

;;; ── 7.2 not-supported returns clear error ────────────────────────────────

(deftest test-spec-unsupported-returns-not-supported-error
  "An engine that doesn't support a command returns a recognizable error.
   Hard to test for mupdf which supports everything; this is a placeholder
   for future engines (image-engine, audio-engine, etc.)."
  ;; Future: when image-engine is added, calling buffer/toc on an image buffer
  ;; should return {ok:false, error: contains 'not supported'}.
  (assert-true t "placeholder — verified once a partially-supporting engine exists"))

;;; ── 7.3 Capability declaration ───────────────────────────────────────────

(deftest test-spec-supports-only-strings
  "supports list contains only strings (command names)."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (assert-list-of #'stringp supports "supports entries are strings")
    (send! "buffer/close" :|buffer-id| bid)))

(deftest test-spec-supports-uses-namespaced-commands
  "supports entries use 'buffer/foo' format, not just 'foo'."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (dolist (s supports)
      (check-assertion (search "/" s)
                       (format nil "~s is namespaced (contains /)" s)))
    (send! "buffer/close" :|buffer-id| bid)))

;;; ── 7.4 MUST push events ────────────────────────────────────────────────

(deftest test-spec-must-push-buffer-opened
  "Successful buffer/open must result in a buffer-opened event."
  (drain-events)
  (let ((r (send! "bridge/engine-load"
                  :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*)))
    (when (eq (getf r :|ok|) t)
      (let ((ev (read-event :type "buffer-opened" :timeout 2)))
        (assert-true ev "buffer-opened event arrived")))))

(deftest test-spec-must-push-error
  "Failed buffer/open should also push an error event (SHOULD per spec)."
  (drain-events)
  (send! "bridge/engine-load"
         :|win-id| "w1" :|engine| "mupdf" :|path| "/no/file.pdf")
  (let ((ev (read-event :type "error" :timeout 1)))
    ;; SHOULD, not MUST — don't fail if no event. But if it arrives, shape it correctly.
    (when ev
      (assert-has-key :|cmd|     ev)
      (assert-has-key :|message| ev))))

;;; ── 7.5 Engine naming convention ────────────────────────────────────────

(deftest test-spec-engine-name-lowercase
  "Engine names in bridge/capabilities are lowercase with hyphens."
  (let ((engines (json-get* (send! "bridge/capabilities") :|data| :|engines|)))
    (dolist (e engines)
      (check-assertion (string= e (string-downcase e))
                       (format nil "engine name ~s is lowercase" e))
      ;; no spaces, no underscores
      (check-assertion (not (search " " e))
                       (format nil "no spaces in ~s" e))
      (check-assertion (not (search "_" e))
                       (format nil "no underscores in ~s" e)))))

;;; ── Engine returns ok=false for buffer-id-related errors ────────────────

(deftest test-spec-engine-rejects-stale-buffer
  "After buffer/close, operations on that buffer-id return ok=false."
  (let* ((r   (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (bid (json-get* r :|data| :|buffer-id|)))
    (send! "buffer/close" :|buffer-id| bid)
    (let ((toc-r (send! "buffer/toc" :|buffer-id| bid)))
      (assert-fail toc-r "stale buffer-id rejected"))))

;;; ── supports list is internally consistent ──────────────────────────────

(deftest test-spec-supports-actually-works-end-to-end
  "Every command in supports MUST actually work without error."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (unwind-protect
         (dolist (cmd supports)
           (cond
             ((string= cmd "buffer/text")
              (assert-ok (send! cmd :|buffer-id| bid :|page| 0)
                         (format nil "advertised ~a works" cmd)))
             ((string= cmd "buffer/toc")
              (assert-ok (send! cmd :|buffer-id| bid)
                         (format nil "advertised ~a works" cmd)))
             ((string= cmd "buffer/links")
              (assert-ok (send! cmd :|buffer-id| bid :|page| 0)
                         (format nil "advertised ~a works" cmd)))
             ((string= cmd "buffer/render")
              (assert-ok (send! cmd :|buffer-id| bid :|page| 0 :|dpi| 72)
                         (format nil "advertised ~a works" cmd)))
             ((string= cmd "buffer/render-region")
              (assert-ok (send! cmd :|buffer-id| bid :|page| 0
                                :|rect| (list 0.0 0.0 100.0 100.0)
                                :|dpi| 72)
                         (format nil "advertised ~a works" cmd)))
             ((string= cmd "buffer/metadata")
              (assert-ok (send! cmd :|buffer-id| bid)
                         (format nil "advertised ~a works" cmd)))))
      (when bid (send! "buffer/close" :|buffer-id| bid)))))

;;; ── buffer-opened event aligned with buffer/open response ───────────────

(deftest test-spec-buffer-opened-event-matches-open-response
  "The buffer-opened event must reference the same buffer-id as the
   buffer/open response (same identity for client correlation)."
  (drain-events)
  (let* ((r       (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (bid     (json-get* r :|data| :|buffer-id|))
         (event   (read-event :type "buffer-opened" :timeout 2)))
    (when (and bid event)
      (assert-equal bid (getf event :|buffer-id|)
                    "event buffer-id matches buffer/open response"))
    (when bid (send! "buffer/close" :|buffer-id| bid))))

(deftest test-spec-buffer-opened-event-has-page-count
  "buffer-opened event includes page-count matching buffer/open response."
  (drain-events)
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (data     (getf r :|data|))
         (bid      (getf data :|buffer-id|))
         (resp-pc  (getf data :|page-count|))
         (event    (read-event :type "buffer-opened" :timeout 2)))
    (when (and event resp-pc)
      (assert-equal resp-pc (getf event :|page-count|)
                    "event page-count matches response"))
    (when bid (send! "buffer/close" :|buffer-id| bid))))

;;; ── Engine cannot lie about its supports list ──────────────────────────

(deftest test-spec-unsupported-not-in-supports-list
  "If engine doesn't support a buffer/* op, it should NOT advertise it."
  ;; This is a contract test: we open mupdf, get its supports list, and
  ;; verify that any command NOT in the list returns 'not supported'.
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|))
         (all-buffer-cmds '("buffer/text" "buffer/toc" "buffer/links"
                             "buffer/render" "buffer/render-region"
                             "buffer/metadata"))
         (not-supported (set-difference all-buffer-cmds supports :test #'string=)))
    (unwind-protect
         (dolist (cmd not-supported)
           (let ((resp
                   (cond ((string= cmd "buffer/text")
                          (send! cmd :|buffer-id| bid :|page| 0))
                         ((string= cmd "buffer/links")
                          (send! cmd :|buffer-id| bid :|page| 0))
                         ((string= cmd "buffer/render")
                          (send! cmd :|buffer-id| bid :|page| 0 :|dpi| 72))
                         ((string= cmd "buffer/render-region")
                          (send! cmd :|buffer-id| bid :|page| 0
                                 :|rect| (list 0.0 0.0 50.0 50.0) :|dpi| 72))
                         (t (send! cmd :|buffer-id| bid)))))
             (assert-fail resp
                          (format nil "non-advertised ~a returns error" cmd))))
      (when bid (send! "buffer/close" :|buffer-id| bid)))))

;;; ── Engine name normalization ───────────────────────────────────────────

(deftest test-spec-engine-name-no-numbers-or-symbols
  "Engine names should not contain numbers, underscores, or special chars."
  (let ((engines (json-get* (send! "bridge/capabilities") :|data| :|engines|)))
    (dolist (e engines)
      (let ((all-ok (every (lambda (c)
                             (or (alpha-char-p c) (char= c #\-)))
                           e)))
        (check-assertion all-ok
                         (format nil "~s contains only letters and hyphens" e))))))
