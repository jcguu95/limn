;;;; text engine tests — SPEC §7.6.
;;;;
;;;; The `text` engine is one of two MUST-bundled engines (the other is
;;;; `mupdf`). All chrome primitives (minibuffer, echo area, *Messages*,
;;;; modeline) are text-engine buffers. These tests only verify the
;;;; engine is registered & openable; chrome behaviour is tested in
;;;; chrome.lisp and minibuffer.lisp.

(in-package #:limn/test)

(deftest test-text-engine-bundled-in-capabilities
  "Frontend MUST list 'text' alongside 'mupdf' in bridge/capabilities."
  (let ((engines (json-get* (send! "bridge/capabilities")
                            :|data| :|engines|)))
    (assert-contains "text"  engines)
    (assert-contains "mupdf" engines)))

(deftest test-text-engine-open-empty-buffer
  "engine=text with empty path creates a fresh empty text buffer."
  (let* ((r  (send! "bridge/engine-load"
                    :|win-id| "w1" :|engine| "text" :|path| ""))
         (id (json-get* r :|data| :|buffer-id|)))
    (assert-ok r "engine-load text ok")
    (assert-true (and (stringp id) (> (length id) 0))
                 "got buffer-id")
    (when id (ignore-errors (send! "buffer/close" :|buffer-id| id)))))

(deftest test-text-engine-supports-buffer-text
  "text engine's supports list MUST include buffer/text."
  (let* ((r        (send! "bridge/engine-load"
                          :|win-id| "w1" :|engine| "text" :|path| ""))
         (id       (json-get* r :|data| :|buffer-id|))
         (supports (json-get* r :|data| :|supports|)))
    (assert-contains "buffer/text" supports)
    (when id (ignore-errors (send! "buffer/close" :|buffer-id| id)))))
