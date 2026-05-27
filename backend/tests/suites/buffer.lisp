;;;; buffer/ namespace tests
;;;;
;;;; Covers section 5.3 of LIMN-SPEC:
;;;;   buffer/open, buffer/close, buffer/toc, buffer/text,
;;;;   buffer/links, buffer/render, buffer/render-region, buffer/metadata
;;;;
;;;; These are content operations. Behavior depends on the engine, but the
;;;; protocol shape is universal: every engine returns the same JSON structure
;;;; (or 'not supported' if it doesn't implement the optional command).

(in-package #:limn/test)

;;; ─── buffer/open ──────────────────────────────────────────────────────────

(deftest test-buffer-open-ok
  "buffer/open with valid file returns ok and required fields."
  (let ((r (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*)))
    (assert-ok r)
    (let ((data (getf r :|data|)))
      (assert-has-key :|buffer-id|  data "buffer-id present")
      (assert-has-key :|page-count| data "page-count present")
      (assert-has-key :|supports|   data "supports list present"))
    ;; cleanup
    (send! "buffer/close" :|buffer-id| (json-get* r :|data| :|buffer-id|))))

(deftest test-buffer-open-buffer-id-string
  "buffer-id is a non-empty string."
  (let* ((r   (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (bid (json-get* r :|data| :|buffer-id|)))
    (assert-type bid string)
    (check-assertion (and bid (> (length bid) 0)) "buffer-id non-empty")
    (send! "buffer/close" :|buffer-id| bid)))

(deftest test-buffer-open-page-count-positive
  "page-count is a positive integer."
  (let* ((r  (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (n  (json-get* r :|data| :|page-count|))
         (bid (json-get* r :|data| :|buffer-id|)))
    (assert-type n integer)
    (check-assertion (and (integerp n) (> n 0)) "page-count > 0")
    (send! "buffer/close" :|buffer-id| bid)))

(deftest test-buffer-open-supports-is-list
  "supports field is a list of strings."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (assert-type supports list)
    (assert-list-of #'stringp supports "supports is list of strings")
    (send! "buffer/close" :|buffer-id| bid)))

(deftest test-buffer-open-supports-mupdf-capabilities
  "mupdf engine declares it supports text, toc, links, render."
  (let* ((r        (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (supports (json-get* r :|data| :|supports|))
         (bid      (json-get* r :|data| :|buffer-id|)))
    (assert-contains "buffer/text"   supports)
    (assert-contains "buffer/toc"    supports)
    (assert-contains "buffer/links"  supports)
    (assert-contains "buffer/render" supports)
    (send! "buffer/close" :|buffer-id| bid)))

(deftest test-buffer-open-missing-file
  "buffer/open of nonexistent file fails."
  (let ((r (send! "buffer/open" :|engine| "mupdf" :|path| "/no/such/file.pdf")))
    (assert-fail r)))

(deftest test-buffer-open-unknown-engine
  "buffer/open with unknown engine fails."
  (let ((r (send! "buffer/open" :|engine| "no-such" :|path| *fixture-pdf*)))
    (assert-fail r)))

(deftest test-buffer-open-no-args
  "buffer/open with no args fails."
  (let ((r (send! "buffer/open")))
    (assert-fail r)))

;;; ─── buffer/close ─────────────────────────────────────────────────────────

(deftest test-buffer-close-ok
  "Closing an opened buffer succeeds."
  (let* ((open-r (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (bid    (json-get* open-r :|data| :|buffer-id|)))
    (let ((r (send! "buffer/close" :|buffer-id| bid)))
      (assert-ok r))))

(deftest test-buffer-close-twice
  "Closing the same buffer twice — second close fails (already closed)."
  (let* ((open-r (send! "buffer/open" :|engine| "mupdf" :|path| *fixture-pdf*))
         (bid    (json-get* open-r :|data| :|buffer-id|)))
    (send! "buffer/close" :|buffer-id| bid)
    (let ((r (send! "buffer/close" :|buffer-id| bid)))
      (assert-fail r "second close on same buffer fails"))))

(deftest test-buffer-close-unknown-id
  "Closing a never-existed buffer-id fails."
  (let ((r (send! "buffer/close" :|buffer-id| "b-nonexistent")))
    (assert-fail r)))

;;; ─── buffer/toc ───────────────────────────────────────────────────────────

(deftest test-buffer-toc-ok
  "buffer/toc returns a list (may be empty for PDFs without outline)."
  (with-buffer (buf)
    (let ((r (send! "buffer/toc" :|buffer-id| buf)))
      (assert-ok r)
      (assert-type (getf r :|data|) list "toc is a list"))))

(deftest test-buffer-toc-entry-shape
  "Each toc entry has title, page, children."
  (with-buffer (buf)
    (let* ((r  (send! "buffer/toc" :|buffer-id| buf))
           (toc (getf r :|data|)))
      (when toc
        (let ((entry (first toc)))
          (assert-has-key :|title|    entry)
          (assert-has-key :|page|     entry)
          (assert-has-key :|children| entry)
          (assert-type (getf entry :|title|) string "title is string")
          (assert-type (getf entry :|page|)  integer "page is integer")
          (assert-type (getf entry :|children|) list "children is list"))))))

(deftest test-buffer-toc-children-recursive
  "If a toc entry has nested children, they follow the same shape."
  (with-buffer (buf)
    (let* ((r   (send! "buffer/toc" :|buffer-id| buf))
           (toc (getf r :|data|)))
      (labels ((check-node (n depth)
                 (when (>= depth 3) (return-from check-node))
                 (assert-has-key :|title| n)
                 (assert-has-key :|page| n)
                 (dolist (child (getf n :|children|))
                   (check-node child (1+ depth)))))
        (dolist (top toc) (check-node top 0))))))

(deftest test-buffer-toc-unknown-buffer
  "buffer/toc on unknown buffer-id fails."
  (let ((r (send! "buffer/toc" :|buffer-id| "b-nope")))
    (assert-fail r)))

;;; ─── buffer/text ──────────────────────────────────────────────────────────

(deftest test-buffer-text-page-zero
  "buffer/text for page 0 returns words with rects."
  (with-buffer (buf)
    (let* ((r    (send! "buffer/text" :|buffer-id| buf :|page| 0))
           (data (getf r :|data|)))
      (assert-ok r)
      (assert-has-key :|words| data "words list present")
      (assert-type (getf data :|words|) list))))

(deftest test-buffer-text-word-shape
  "Each word has text and rect."
  (with-buffer (buf)
    (let* ((r     (send! "buffer/text" :|buffer-id| buf :|page| 0))
           (words (json-get* r :|data| :|words|)))
      (when words
        (let ((w (first words)))
          (assert-has-key :|text| w)
          (assert-has-key :|rect| w)
          (assert-type (getf w :|text|) string)
          (assert-type (getf w :|rect|) list)
          (check-assertion (= (length (getf w :|rect|)) 4)
                           "rect has 4 numbers (x0 y0 x1 y1)"))))))

(deftest test-buffer-text-out-of-range-page
  "buffer/text with out-of-range page returns error."
  (with-buffer (buf)
    (let ((r (send! "buffer/text" :|buffer-id| buf :|page| 99999)))
      (assert-fail r))))

(deftest test-buffer-text-negative-page
  "buffer/text with negative page returns error."
  (with-buffer (buf)
    (let ((r (send! "buffer/text" :|buffer-id| buf :|page| -1)))
      (assert-fail r))))

(deftest test-buffer-text-unknown-buffer
  "buffer/text on unknown buffer fails."
  (let ((r (send! "buffer/text" :|buffer-id| "b-nope" :|page| 0)))
    (assert-fail r)))

;;; ─── buffer/links ─────────────────────────────────────────────────────────

(deftest test-buffer-links-shape
  "buffer/links returns a list (possibly empty)."
  (with-buffer (buf)
    (let ((r (send! "buffer/links" :|buffer-id| buf :|page| 0)))
      (assert-ok r)
      (assert-type (getf r :|data|) list))))

(deftest test-buffer-links-entry-shape
  "Each link has type, rect, and dest-page or uri."
  (with-buffer (buf)
    (let* ((r     (send! "buffer/links" :|buffer-id| buf :|page| 0))
           (links (getf r :|data|)))
      (when links
        (let ((link (first links)))
          (assert-has-key :|type| link)
          (assert-has-key :|rect| link)
          (let ((type (getf link :|type|)))
            (assert-contains type '("internal" "uri")
                             "type is 'internal' or 'uri'")
            (cond
              ((string= type "internal")
               (assert-has-key :|dest-page| link))
              ((string= type "uri")
               (assert-has-key :|uri| link)))))))))

(deftest test-buffer-links-out-of-range
  "buffer/links with bad page fails."
  (with-buffer (buf)
    (assert-fail (send! "buffer/links" :|buffer-id| buf :|page| 99999))))

;;; ─── buffer/render ────────────────────────────────────────────────────────

(deftest test-buffer-render-ok
  "buffer/render returns PNG base64 data."
  (with-buffer (buf)
    (let* ((r    (send! "buffer/render"
                        :|buffer-id| buf :|page| 0 :|dpi| 72))
           (data (getf r :|data|)))
      (assert-ok r)
      (assert-has-key :|png| data)
      (let ((png (getf data :|png|)))
        (assert-type png string)
        (check-assertion (> (length png) 100)
                         "png data substantially long (looks like a real image)")))))

(deftest test-buffer-render-different-dpi
  "Higher DPI produces larger PNG payload than lower DPI."
  (with-buffer (buf)
    (let* ((low  (length (json-get*
                          (send! "buffer/render"
                                 :|buffer-id| buf :|page| 0 :|dpi| 36)
                          :|data| :|png|)))
           (high (length (json-get*
                          (send! "buffer/render"
                                 :|buffer-id| buf :|page| 0 :|dpi| 144)
                          :|data| :|png|))))
      (check-assertion (> high low)
                       "high-dpi PNG is larger than low-dpi"
                       "low=~a, high=~a" low high))))

(deftest test-buffer-render-default-dpi
  "buffer/render without explicit dpi uses a sensible default."
  (with-buffer (buf)
    (let ((r (send! "buffer/render" :|buffer-id| buf :|page| 0)))
      (assert-ok r "render with default dpi"))))

(deftest test-buffer-render-out-of-range
  "buffer/render with bad page fails."
  (with-buffer (buf)
    (assert-fail (send! "buffer/render"
                        :|buffer-id| buf :|page| 99999 :|dpi| 72))))

;;; ─── buffer/render-region ────────────────────────────────────────────────

(deftest test-buffer-render-region-ok
  "buffer/render-region returns PNG of the cropped region."
  (with-buffer (buf)
    (let ((r (send! "buffer/render-region"
                    :|buffer-id| buf :|page| 0
                    :|rect| (list 0.0 0.0 100.0 100.0)
                    :|dpi| 72)))
      (assert-ok r)
      (assert-has-key :|png| (getf r :|data|)))))

(deftest test-buffer-render-region-bad-rect
  "render-region with invalid rect (x1 < x0) returns error or normalizes."
  (with-buffer (buf)
    (let ((r (send! "buffer/render-region"
                    :|buffer-id| buf :|page| 0
                    :|rect| (list 100.0 100.0 50.0 50.0)
                    :|dpi| 72)))
      ;; either ok (normalized) or fail — must respond
      (assert-true (member (getf r :|ok|) '(t :false)) "responds"))))

;;; ─── buffer/metadata ─────────────────────────────────────────────────────

(deftest test-buffer-metadata-ok
  "buffer/metadata returns ok with data object."
  (with-buffer (buf)
    (let ((r (send! "buffer/metadata" :|buffer-id| buf)))
      (assert-ok r)
      (let ((data (getf r :|data|)))
        (assert-type data list "metadata is an object")
        (assert-has-key :|page-count| data "page-count in metadata")
        (assert-has-key :|format|     data "format in metadata")))))

(deftest test-buffer-metadata-format-pdf
  "PDF buffer has format='pdf'."
  (with-buffer (buf)
    (let ((fmt (json-get* (send! "buffer/metadata" :|buffer-id| buf)
                          :|data| :|format|)))
      (assert-equal "pdf" fmt))))

(deftest test-buffer-metadata-unknown-buffer
  "metadata for unknown buffer fails."
  (let ((r (send! "buffer/metadata" :|buffer-id| "b-nope")))
    (assert-fail r)))

;;; ─── buffer/open with file:// URL ─────────────────────────────────────────

(deftest test-buffer-open-with-file-url
  "Spec says path or URL; file:// URL should also work."
  (let ((url (format nil "file://~a" *fixture-pdf*)))
    (let ((r (send! "buffer/open" :|engine| "mupdf" :|path| url)))
      (when (eq (getf r :|ok|) t)
        ;; If the implementation supports URLs, verify shape; if not, that's OK too
        (assert-has-key :|buffer-id| (getf r :|data|))
        (send! "buffer/close" :|buffer-id| (json-get* r :|data| :|buffer-id|))))))

;;; ─── Metadata type checks ────────────────────────────────────────────────

(deftest test-buffer-metadata-fields-types
  "Metadata fields, if present, are correct types: title and author are strings."
  (with-buffer (buf)
    (let ((data (getf (send! "buffer/metadata" :|buffer-id| buf) :|data|)))
      (when (getf data :|title|)
        (assert-type (getf data :|title|) string "title is string"))
      (when (getf data :|author|)
        (assert-type (getf data :|author|) string "author is string"))
      (assert-type (getf data :|page-count|) integer "page-count is integer")
      (assert-type (getf data :|format|)     string  "format is string"))))

;;; ─── buffer/text edge cases ──────────────────────────────────────────────

(deftest test-buffer-text-each-word-has-text-and-rect
  "Every word in buffer/text response has both :text and :rect fields."
  (with-buffer (buf)
    (let* ((data  (getf (send! "buffer/text"
                                :|buffer-id| buf :|page| 0)
                        :|data|))
           (words (getf data :|words|)))
      (when (consp words)
        (let ((all-have-text  (every (lambda (w) (getf w :|text|))  words))
              (all-have-rect  (every (lambda (w) (getf w :|rect|))  words))
              (all-rects-4    (every (lambda (w) (= 4 (length (getf w :|rect|))))
                                     words)))
          (assert-true all-have-text "every word has :text")
          (assert-true all-have-rect "every word has :rect")
          (assert-true all-rects-4 "every rect has 4 numbers"))))))

(deftest test-buffer-text-rects-are-numeric
  "Each rect entry is a number, not a string."
  (with-buffer (buf)
    (let* ((words (json-get* (send! "buffer/text"
                                     :|buffer-id| buf :|page| 0)
                              :|data| :|words|)))
      (when (consp words)
        (let ((all-numeric (every (lambda (w)
                                    (every #'numberp (getf w :|rect|)))
                                  words)))
          (assert-true all-numeric "all rect values are numeric"))))))

;;; ─── buffer/links validation ─────────────────────────────────────────────

(deftest test-buffer-links-internal-has-page-not-uri
  "Internal links have dest-page, NOT uri."
  (with-buffer (buf)
    (let ((links (getf (send! "buffer/links"
                               :|buffer-id| buf :|page| 0)
                       :|data|)))
      (dolist (link links)
        (when (string= (getf link :|type|) "internal")
          (assert-has-key :|dest-page| link "internal has dest-page")
          (assert-false  (getf link :|uri|) "internal has no uri"))))))

(deftest test-buffer-links-uri-has-uri-not-page
  "URI links have uri, NOT dest-page."
  (with-buffer (buf)
    (let ((links (getf (send! "buffer/links"
                               :|buffer-id| buf :|page| 0)
                       :|data|)))
      (dolist (link links)
        (when (string= (getf link :|type|) "uri")
          (assert-has-key :|uri| link "uri link has uri")
          (assert-type (getf link :|uri|) string))))))

;;; ─── render-region stricter validation ───────────────────────────────────

(deftest test-buffer-render-region-zero-area-rect
  "Zero-area rect (x0==x1) should be rejected or return empty/transparent PNG."
  (with-buffer (buf)
    (let ((r (send! "buffer/render-region"
                    :|buffer-id| buf :|page| 0
                    :|rect| (list 50.0 50.0 50.0 50.0)
                    :|dpi| 72)))
      ;; Either reject or return some PNG — but must not hang/crash.
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))

(deftest test-buffer-render-region-rect-wrong-arity
  "rect with not exactly 4 elements is rejected."
  (with-buffer (buf)
    (let ((r (send! "buffer/render-region"
                    :|buffer-id| buf :|page| 0
                    :|rect| (list 0.0 0.0 100.0)
                    :|dpi| 72)))
      (assert-fail r "3-element rect rejected"))))

;;; ─── buffer/render edge cases ────────────────────────────────────────────

(deftest test-buffer-render-zero-dpi
  "DPI of 0 is rejected (would produce degenerate image)."
  (with-buffer (buf)
    (let ((r (send! "buffer/render" :|buffer-id| buf :|page| 0 :|dpi| 0)))
      (assert-fail r "dpi=0 rejected"))))

(deftest test-buffer-render-negative-dpi
  (with-buffer (buf)
    (let ((r (send! "buffer/render" :|buffer-id| buf :|page| 0 :|dpi| -1)))
      (assert-fail r "negative dpi rejected"))))

(deftest test-buffer-render-very-high-dpi
  "Extremely high DPI is either accepted or rejected — but must not crash."
  (with-buffer (buf)
    (let ((r (send! "buffer/render" :|buffer-id| buf :|page| 0 :|dpi| 2400)))
      (assert-true (member (getf r :|ok|) '(t :false)) "responded"))))

;;; ─── v0.39 W20 — buffer/list ──────────────────────────────────────────────
;;;
;;; Pre-v0.39 buffer/list didn't exist; the dogfood W20 driver called it and
;;; the wire returned err.  Now: enumerates mupdf buffers from `registry`
;;; plus text-engine buffers from `text_buffers`, each as
;;; { buffer-id, path, engine, kind }.

(deftest test-buffer-list-includes-chrome-by-default
  "Fresh session ships *minibuffer* / *echo-area* / *messages* text buffers;
   buffer/list should report them with engine=text kind=chrome."
  (let* ((r (send! "buffer/list"))
         (entries (getf r :|data|)))
    (assert-ok r)
    (assert-true (listp entries) "data is a list of entries")
    (let ((chrome-ids (loop for e in entries
                            when (and (equal (getf e :|engine|) "text")
                                      (equal (getf e :|kind|)   "chrome"))
                              collect (getf e :|buffer-id|))))
      (assert-true (find "*minibuffer*" chrome-ids :test #'equal)
                   "*minibuffer* in list")
      (assert-true (find "*echo-area*"  chrome-ids :test #'equal)
                   "*echo-area* in list")
      (assert-true (find "*messages*"   chrome-ids :test #'equal)
                   "*messages* in list"))))

(deftest test-buffer-list-reports-mupdf-buffer
  "After bridge/engine-load engine=mupdf, the loaded PDF must show up in
   buffer/list with engine=mupdf kind=file and the original path."
  (with-buffer (buf)
    (let* ((r (send! "buffer/list"))
           (entries (getf r :|data|))
           (mine (find-if (lambda (e) (equal (getf e :|buffer-id|) buf))
                          entries)))
      (assert-true mine "the just-opened buffer is in the list")
      (assert-equal "mupdf" (getf mine :|engine|) "engine=mupdf")
      (assert-equal "file"  (getf mine :|kind|)   "kind=file")
      (assert-true (and (stringp (getf mine :|path|))
                        (plusp (length (getf mine :|path|))))
                   "path is a non-empty string"))))

(deftest test-buffer-list-reports-text-engine-buffer-with-path
  "After bridge/engine-load engine=text + buffer/load-file, the text buffer
   should appear with engine=text kind=file and the path it was loaded from
   (this is the assertion the W20 dogfood driver makes)."
  (let* ((tmp "/tmp/test-buffer-list-text.txt"))
    (with-open-file (s tmp :direction :output :if-exists :supersede)
      (write-string "hi" s))
    (unwind-protect
         (let* ((eng (send! "bridge/engine-load"
                            :|win-id| "w1" :|engine| "text" :|path| ""))
                (tid (getf (getf eng :|data|) :|buffer-id|)))
           (send! "buffer/load-file" :|buffer-id| tid :|path| tmp)
           (let* ((r (send! "buffer/list"))
                  (entries (getf r :|data|))
                  (mine (find-if (lambda (e)
                                   (equal (getf e :|buffer-id|) tid))
                                 entries)))
             (assert-true mine "text buffer in list")
             (assert-equal "text" (getf mine :|engine|))
             (assert-equal "file" (getf mine :|kind|))
             (assert-equal tmp    (getf mine :|path|))
             ;; clean up
             (send! "buffer/close" :|buffer-id| tid)))
      (ignore-errors (delete-file tmp)))))
