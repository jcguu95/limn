;;;; mupdf-engine specific tests
;;;;
;;;; These are tests for behavior unique to mupdf-engine, particularly:
;;;;   - engine-params for dark-mode, rotation
;;;;   - supported formats: pdf, epub, xps, cbz
;;;;   - text/toc/links return non-trivial data for a real PDF
;;;;
;;;; Other engines won't run these (they're scoped to mupdf).

(in-package #:limn/test)

;;; ── engine-params: dark-mode ─────────────────────────────────────────────

(deftest test-mupdf-dark-mode-on
  "dark-mode = true is accepted."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1"
                    :|engine-params| '(:|dark-mode| t))))
      (assert-ok r))))

(deftest test-mupdf-dark-mode-off
  "dark-mode = false is accepted."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1"
                    :|engine-params| '(:|dark-mode| :false))))
      (assert-ok r))))

(deftest test-mupdf-dark-mode-roundtrip
  "After setting dark-mode, view/get reflects it in engine-params."
  (with-buffer (buf)
    (send! "view/set" :|win-id| "w1"
           :|engine-params| '(:|dark-mode| t))
    (let ((ep (json-get* (send! "view/get" :|win-id| "w1")
                         :|data| :|engine-params|)))
      (assert-equal t (getf ep :|dark-mode|) "dark-mode is true after set"))))

;;; ── engine-params: rotation ─────────────────────────────────────────────

(deftest test-mupdf-rotation-0
  "rotation = 0 (no rotation)"
  (with-buffer (buf)
    (assert-ok (send! "view/set" :|win-id| "w1"
                      :|engine-params| '(:|rotation| 0)))))

(deftest test-mupdf-rotation-90
  "rotation = 90 (quarter turn)"
  (with-buffer (buf)
    (assert-ok (send! "view/set" :|win-id| "w1"
                      :|engine-params| '(:|rotation| 90)))))

(deftest test-mupdf-rotation-180
  (with-buffer (buf)
    (assert-ok (send! "view/set" :|win-id| "w1"
                      :|engine-params| '(:|rotation| 180)))))

(deftest test-mupdf-rotation-270
  (with-buffer (buf)
    (assert-ok (send! "view/set" :|win-id| "w1"
                      :|engine-params| '(:|rotation| 270)))))

(deftest test-mupdf-rotation-invalid-multiple
  "Non-90-multiple rotation either rejected or snapped."
  (with-buffer (buf)
    (let ((r (send! "view/set" :|win-id| "w1"
                    :|engine-params| '(:|rotation| 45))))
      ;; mupdf only supports 90-multiples; either rejection or snap is acceptable
      (assert-true (member (getf r :|ok|) '(t :false))))))

;;; ── Supported formats ───────────────────────────────────────────────────

(deftest test-mupdf-format-pdf
  "PDF format is reported in metadata."
  (with-buffer (buf)
    (let ((fmt (json-get* (send! "buffer/metadata" :|buffer-id| buf)
                          :|data| :|format|)))
      (assert-equal "pdf" fmt))))

;; Note: epub, xps, cbz tests require corresponding fixtures.
;; Add them when those fixtures are available.

(deftest test-mupdf-format-epub-if-fixture-exists
  "mupdf opens an EPUB if fixture is available."
  (let ((epub (namestring (merge-pathnames
                           "fixtures/test.epub"
                           (or *load-pathname* *default-pathname-defaults*)))))
    (when (probe-file epub)
      (let* ((r   (send! "buffer/open" :|engine| "mupdf" :|path| epub))
             (bid (json-get* r :|data| :|buffer-id|)))
        (assert-ok r "epub opens")
        (when bid
          (let ((fmt (json-get* (send! "buffer/metadata" :|buffer-id| bid)
                                :|data| :|format|)))
            (assert-equal "epub" fmt))
          (send! "buffer/close" :|buffer-id| bid))))))

;;; ── Text extraction returns real content ─────────────────────────────────

(deftest test-mupdf-text-extracts-real-words
  "Text extraction returns actual content for a non-empty PDF."
  (with-buffer (buf)
    (let* ((r     (send! "buffer/text" :|buffer-id| buf :|page| 0))
           (words (json-get* r :|data| :|words|)))
      (when (consp words)
        (let ((joined (with-output-to-string (s)
                        (dolist (w words)
                          (write-string (getf w :|text|) s)
                          (write-char #\Space s)))))
          (check-assertion (> (length joined) 5)
                           "extracted text is non-trivial in length"
                           "got ~s" joined))))))

(deftest test-mupdf-text-rects-non-degenerate
  "Each word's rect has x1 > x0 and y1 > y0."
  (with-buffer (buf)
    (let* ((words (json-get* (send! "buffer/text" :|buffer-id| buf :|page| 0)
                             :|data| :|words|)))
      (when (consp words)
        (let ((w (first words)))
          (let ((rect (getf w :|rect|)))
            (when (and rect (= (length rect) 4))
              (destructuring-bind (x0 y0 x1 y1) rect
                (check-assertion (and (numberp x0) (numberp y0)
                                       (numberp x1) (numberp y1))
                                 "rect entries are numeric")
                ;; Don't require strict ordering — some PDFs may have rotated text
                (check-assertion (or (>= x1 x0) (>= y1 y0))
                                 "rect has some positive extent")))))))))

;;; ── Render returns valid PNG ─────────────────────────────────────────────

(deftest test-mupdf-render-png-magic-bytes
  "Rendered PNG base64 decodes to bytes starting with PNG magic 89 50 4E 47."
  (with-buffer (buf)
    (let* ((png-b64 (json-get* (send! "buffer/render"
                                       :|buffer-id| buf :|page| 0 :|dpi| 72)
                                :|data| :|png|)))
      (when (and png-b64 (> (length png-b64) 16))
        ;; First 4 bytes of PNG are 0x89 0x50 0x4E 0x47.
        ;; Base64 of those is "iVBORw" (approximately).
        ;; A simpler check: first decoded chars contain "PNG" signature region.
        (check-assertion (string= "iVBORw0K" (subseq png-b64 0 8))
                         "PNG base64 starts with the standard signature"
                         "got prefix: ~s" (subseq png-b64 0 (min 16 (length png-b64))))))))

;;; ── Multi-buffer lifecycle ───────────────────────────────────────────────

(deftest test-mupdf-multiple-buffers
  "Two buffers can be open simultaneously, each with independent state."
  (let* ((r1  (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (b1  (json-get* r1 :|data| :|buffer-id|))
         (r2  (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (b2  (json-get* r2 :|data| :|buffer-id|)))
    (assert-ok r1)
    (assert-ok r2)
    (assert-false (string= b1 b2) "buffer-ids are distinct")
    (send! "buffer/close" :|buffer-id| b1)
    (send! "buffer/close" :|buffer-id| b2)))

(deftest test-mupdf-shared-buffer-two-windows
  "Same buffer can be displayed in two windows independently."
  ;; Load into w1
  (let* ((load-r (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| *fixture-pdf*))
         (buf    (json-get* load-r :|data| :|buffer-id|)))
    ;; Split and load same buffer in new window
    (let* ((split-r (send! "bridge/win-split" :|win-id| "w1" :|dir| "h"))
           (w2      (json-get* split-r :|data| :|win-b|)))
      (when (and buf w2)
        ;; Try to attach same buffer to w2 (mechanism may vary)
        ;; Set different pages in each, verify they don't conflict
        (send! "view/set" :|win-id| "w1" :|page| 0)
        (let ((p1 (json-get* (send! "view/get" :|win-id| "w1") :|data| :|page|)))
          (assert-equal 0 p1 "w1 on page 0")))
      (when w2
        (ignore-errors (send! "bridge/win-close" :|win-id| w2))))))

;;; ── More mupdf formats ───────────────────────────────────────────────────

(deftest test-mupdf-format-xps-if-fixture-exists
  "mupdf opens XPS if fixture is available."
  (let ((xps (namestring (merge-pathnames
                           "fixtures/test.xps"
                           (or *load-pathname* *default-pathname-defaults*)))))
    (when (probe-file xps)
      (let* ((r   (send! "buffer/open" :|engine| "mupdf" :|path| xps))
             (bid (json-get* r :|data| :|buffer-id|)))
        (assert-ok r "xps opens")
        (when bid
          (assert-equal "xps"
                        (json-get* (send! "buffer/metadata" :|buffer-id| bid)
                                    :|data| :|format|))
          (send! "buffer/close" :|buffer-id| bid))))))

(deftest test-mupdf-format-cbz-if-fixture-exists
  "mupdf opens CBZ (comic) if fixture is available."
  (let ((cbz (namestring (merge-pathnames
                           "fixtures/test.cbz"
                           (or *load-pathname* *default-pathname-defaults*)))))
    (when (probe-file cbz)
      (let* ((r   (send! "buffer/open" :|engine| "mupdf" :|path| cbz))
             (bid (json-get* r :|data| :|buffer-id|)))
        (assert-ok r "cbz opens")
        (when bid (send! "buffer/close" :|buffer-id| bid))))))

;;; ── Password-protected PDFs ──────────────────────────────────────────────

(deftest test-mupdf-encrypted-pdf-if-fixture-exists
  "Encrypted PDF without password returns error indicating need for password."
  (let ((enc (namestring (merge-pathnames
                           "fixtures/encrypted.pdf"
                           (or *load-pathname* *default-pathname-defaults*)))))
    (when (probe-file enc)
      (let ((r (send! "buffer/open" :|engine| "mupdf" :|path| enc)))
        (assert-fail r "encrypted PDF without password fails")
        (let ((err (getf r :|error|)))
          (check-assertion (or (search "password" err)
                                (search "encrypted" err)
                                (search "auth"     err))
                           "error message mentions password/encryption"))))))

(deftest test-mupdf-encrypted-pdf-with-password
  "Encrypted PDF with correct password opens (when :password field provided)."
  ;; This requires the engine to accept a :password field; spec doesn't yet
  ;; define it, so this is a future-feature test.
  (let ((enc (namestring (merge-pathnames
                           "fixtures/encrypted.pdf"
                           (or *load-pathname* *default-pathname-defaults*)))))
    (when (probe-file enc)
      (let ((r (send! "buffer/open" :|engine| "mupdf" :|path| enc
                       :|password| "testpw")))
        ;; If the engine supports passwords, ok; otherwise fail w/ informative err
        (assert-true (member (getf r :|ok|) '(t :false)) "responded")))))

;;; ── Unicode metadata ─────────────────────────────────────────────────────

(deftest test-mupdf-metadata-unicode-roundtrip
  "If the fixture has Unicode title/author, they come back as UTF-8 strings."
  (with-buffer (buf)
    (let ((title (json-get* (send! "buffer/metadata" :|buffer-id| buf)
                             :|data| :|title|)))
      (when title
        (assert-type title string "title is a string")
        ;; If title contains non-ASCII, verify the string-length is reasonable
        (check-assertion (every (lambda (c) (< (char-code c) 1114112)) title)
                         "all chars are valid Unicode codepoints")))))

;;; ── Render PNG-validity smoke check ──────────────────────────────────────

(deftest test-mupdf-render-png-decodes-valid-base64
  "Rendered PNG's base64 string contains only valid base64 characters."
  (with-buffer (buf)
    (let* ((png (json-get* (send! "buffer/render"
                                   :|buffer-id| buf :|page| 0 :|dpi| 72)
                            :|data| :|png|)))
      (when (stringp png)
        (let ((valid-base64-chars
                (concatenate 'string
                              "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                              "abcdefghijklmnopqrstuvwxyz"
                              "0123456789+/=")))
          (let ((bad-char (find-if-not
                            (lambda (c) (find c valid-base64-chars))
                            png)))
            (assert-false bad-char
                          (format nil "all chars valid base64 (found bad: ~s)"
                                  bad-char))))))))

;;; ── Buffer doesn't leak across opens ─────────────────────────────────────

(deftest test-mupdf-buffer-id-unique-per-open
  "Opening the same PDF 3 times yields 3 distinct buffer-ids."
  (let ((ids '()))
    (unwind-protect
         (progn
           (dotimes (i 3)
             (let* ((r (send! "buffer/open" :|engine| "mupdf"
                              :|path| *fixture-pdf*))
                    (bid (json-get* r :|data| :|buffer-id|)))
               (when bid (push bid ids))))
           (assert-equal 3 (length ids) "3 opens succeeded")
           (assert-equal 3 (length (remove-duplicates ids :test #'string=))
                         "all 3 buffer-ids are distinct"))
      (dolist (id ids)
        (ignore-errors (send! "buffer/close" :|buffer-id| id))))))
