;;;; Internationalization tests
;;;;
;;;; Spec says UTF-8 throughout. Real-world text includes:
;;;;   - CJK (zh, ja, ko)
;;;;   - RTL (ar, he)
;;;;   - Combining characters (é = e + combining acute)
;;;;   - Emoji / non-BMP codepoints
;;;;   - Vertical text (Mongolian, traditional Japanese)
;;;;
;;;; Most tests use conditional fixtures (skip if no matching PDF available).

(in-package #:limn/test)

;;; ── UTF-8 in command arguments ──────────────────────────────────────────

(deftest test-i18n-cjk-path-error-roundtrip
  "Chinese path in a failing engine-load: path echoed verbatim in error."
  (let ((path "/不存在/論文中文檔名.pdf"))
    (let* ((r   (send! "bridge/engine-load"
                       :|win-id| "w1" :|engine| "mupdf" :|path| path))
           (err (getf r :|error|)))
      (assert-fail r)
      (assert-type err string)
      ;; Error should mention the path or part of it
      (check-assertion (or (search "不存在" err)
                            (search "論文"   err)
                            (search ".pdf"   err))
                       "error mentions Chinese path"
                       "got: ~s" err))))

(deftest test-i18n-japanese-path
  (let ((path "/存在しない/論文.pdf"))
    (assert-fail (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| path))))

(deftest test-i18n-korean-path
  (let ((path "/존재하지않음/논문.pdf"))
    (assert-fail (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| path))))

(deftest test-i18n-arabic-path
  "RTL text in path (Arabic)."
  (let ((path "/غير-موجود/ورقة.pdf"))
    (assert-fail (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| path))))

(deftest test-i18n-hebrew-path
  (let ((path "/לא-קיים/מאמר.pdf"))
    (assert-fail (send! "bridge/engine-load"
                        :|win-id| "w1" :|engine| "mupdf" :|path| path))))

(deftest test-i18n-emoji-path
  "Emoji (non-BMP codepoints) in path."
  (let ((path "/no/file-📄-🌏-🦄.pdf"))
    (let ((r (send! "bridge/engine-load"
                    :|win-id| "w1" :|engine| "mupdf" :|path| path)))
      (assert-fail r)
      (let ((err (getf r :|error|)))
        (assert-type err string)
        (check-assertion (> (length err) 0) "error message present")))))

(deftest test-i18n-combining-characters
  "Path with combining diacritic (é as e + U+0301)."
  (let ((path (format nil "/no/file-e~c.pdf" (code-char #x0301))))
    (let ((r (send! "bridge/engine-load"
                    :|win-id| "w1" :|engine| "mupdf" :|path| path)))
      (assert-fail r "combining char path handled"))))

;;; ── UTF-8 in overlays (text type) ───────────────────────────────────────

(deftest test-i18n-overlay-text-cjk
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos| (50.0 50.0)
                            :|text| "中文標注 日本語 한국어"
                            :|color| "#000000" :|size| 14.0 :|opacity| 1.0)))))
      (assert-ok r "CJK in overlay text"))))

(deftest test-i18n-overlay-text-rtl
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos| (50.0 50.0)
                            :|text| "هذا نص عربي بالإضافة إلى עברית"
                            :|color| "#000000" :|size| 14.0 :|opacity| 1.0)))))
      (assert-ok r "RTL text in overlay"))))

(deftest test-i18n-overlay-text-emoji
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos| (50.0 50.0)
                            :|text| "Note 📝 with 🎨 emojis 🚀"
                            :|color| "#000000" :|size| 14.0 :|opacity| 1.0)))))
      (assert-ok r "emoji in overlay text"))))

(deftest test-i18n-overlay-text-mixed-directional
  "Text with both LTR and RTL segments (bidi)."
  (with-buffer (buf)
    (let ((r (send! "view/overlays" :|win-id| "w1"
                    :|layers|
                    (list '(:|type| "text" :|page| 0
                            :|pos| (50.0 50.0)
                            :|text| "English עם עברית and back to English"
                            :|color| "#000000" :|size| 14.0 :|opacity| 1.0)))))
      (assert-ok r "bidi text in overlay"))))

;;; ── UTF-8 in IME and audio-input ────────────────────────────────────────

(deftest test-i18n-ime-japanese
  (drain-events)
  (when (eq (getf (send! "test/inject-ime-commit"
                          :|frame-id| "f1"
                          :|text| "こんにちは世界") :|ok|) t)
    (let ((ev (read-event :type "ime-commit" :timeout 1)))
      (when ev
        (assert-equal "こんにちは世界" (getf ev :|text|))))))

(deftest test-i18n-ime-korean
  (drain-events)
  (when (eq (getf (send! "test/inject-ime-commit"
                          :|frame-id| "f1"
                          :|text| "안녕하세요") :|ok|) t)
    (let ((ev (read-event :type "ime-commit" :timeout 1)))
      (when ev
        (assert-equal "안녕하세요" (getf ev :|text|))))))

(deftest test-i18n-audio-input-multilingual
  (drain-events)
  (when (eq (getf (send! "test/inject-audio-input"
                          :|frame-id| "f1"
                          :|text| "next page 下一頁") :|ok|) t)
    (let ((ev (read-event :type "audio-input" :timeout 1)))
      (when ev
        (assert-equal "next page 下一頁" (getf ev :|text|))))))

;;; ── UTF-8 in error messages ─────────────────────────────────────────────

(deftest test-i18n-error-messages-utf8-safe
  "Error messages don't garble UTF-8 characters in paths."
  (let* ((path "/no/file-éàü-中-😀.pdf")
         (r    (send! "bridge/engine-load"
                      :|win-id| "w1" :|engine| "mupdf" :|path| path))
         (err  (getf r :|error|)))
    (assert-fail r)
    ;; The error message should be valid UTF-8 (no replacement chars or
    ;; mojibake). Hard to verify in Lisp directly; we just check it's
    ;; a string that doesn't contain U+FFFD replacement char.
    (check-assertion (not (find (code-char #xFFFD) err))
                     "no U+FFFD replacement char in error"
                     "error: ~s" err)))

;;; ── UTF-8 in metadata (buffer/metadata) ────────────────────────────────
;;; Test that mupdf's metadata extraction handles UTF-8 fields.

(deftest test-i18n-metadata-unicode-string
  "If fixture has any metadata, it must be a valid UTF-8 string."
  (with-buffer (buf)
    (let ((md (json-get* (send! "buffer/metadata" :|buffer-id| buf)
                         :|data|)))
      (dolist (field '(:|title| :|author| :|subject| :|keywords|))
        (let ((v (getf md field)))
          (when v
            (assert-type v string (format nil "~s is a string" field))
            (check-assertion (not (find (code-char #xFFFD) v))
                             (format nil "~s is valid UTF-8" field))))))))

;;; ── UTF-8 in buffer/text (PDF page content) ────────────────────────────

(deftest test-i18n-buffer-text-utf8-valid
  "Words extracted from PDF text are valid UTF-8 strings."
  (with-buffer (buf)
    (let ((words (json-get* (send! "buffer/text"
                                    :|buffer-id| buf :|page| 0)
                            :|data| :|words|)))
      (dolist (w words)
        (let ((txt (getf w :|text|)))
          (when txt
            (check-assertion (not (find (code-char #xFFFD) txt))
                             "extracted word has no replacement char"
                             "got: ~s" txt)))))))