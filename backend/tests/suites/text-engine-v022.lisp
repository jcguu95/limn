;;;; v0.22 text-engine 編輯能力 — Phase A RED tests
;;;;
;;;; SPEC §12 v0.22 Phase A：新增兩條 wire 命令
;;;;
;;;;   buffer/load-file  讀磁碟內容進 text-engine buffer + cursor 歸零
;;;;                     + 記住 path 到 buffer_paths
;;;;   buffer/save       把 buffer 寫回 buffer_paths 綁定的 path
;;;;
;;;; 兩條命令均只對 text-engine buffer 有效；mupdf 回 "not supported"。
;;;;
;;;; 本檔 v0.22 Phase A C++ 實作前全紅。
;;;;
;;;; 依賴：v0.20 gap-buffer 已 ship、wire contract 不變。

(in-package #:limn/test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defmacro with-text-buffer-v022 ((var) &body body)
  "Open a fresh text-engine buffer (path empty), bind buffer-id to VAR."
  (let ((r (gensym)))
    `(let* ((,r (send! "bridge/engine-load"
                       :|win-id| "w1" :|engine| "text" :|path| ""))
            (,var (json-get* ,r :|data| :|buffer-id|)))
       (unwind-protect (progn ,@body)
         (when ,var (ignore-errors (send! "buffer/close" :|buffer-id| ,var)))))))

(defun temp-text-file (content &key (suffix ".txt"))
  "Write CONTENT to a fresh temp file, return its path. CONTENT may be
   a string (UTF-8 encoded) or a byte vector (written verbatim)."
  (let* ((path (format nil "/tmp/limn-v022-~a-~a~a"
                       (sb-posix:getpid)
                       (random 1000000)
                       suffix)))
    (with-open-file (s path :direction :output
                            :if-exists :supersede
                            :element-type (if (stringp content) 'character '(unsigned-byte 8))
                            :external-format :utf-8)
      (if (stringp content)
          (write-string content s)
          (loop for b across content do (write-byte b s))))
    path))

(defun read-file-string (path)
  "Read PATH back as UTF-8 string."
  (with-open-file (s path :direction :input :external-format :utf-8)
    (with-output-to-string (out)
      (loop for ch = (read-char s nil nil) while ch do (write-char ch out)))))

;;; ── A1. round-trip basic ──────────────────────────────────────────────

(deftest v022-load-file-basic-roundtrip
  "buffer/load-file reads disk content into the buffer; buffer/text reads
   it back identically."
  (with-text-buffer-v022 (buf)
    (let* ((path (temp-text-file "hello world"))
           (r    (send! "buffer/load-file"
                        :|buffer-id| buf :|path| path)))
      (assert-ok r "buffer/load-file returns ok")
      (let ((t-r (send! "buffer/text" :|buffer-id| buf)))
        (assert-ok t-r "buffer/text on loaded buffer")
        (assert-equal "hello world" (json-get* t-r :|data| :|text|)))
      (let ((c-r (send! "buffer/cursor-get" :|buffer-id| buf)))
        (assert-equal 0 (json-get* c-r :|data| :|offset|)
                      "cursor reset to 0 after load")))))

;;; ── A2. save round-trip ───────────────────────────────────────────────

(deftest v022-save-writes-buffer-to-disk
  "After load-file, edits, and save, the on-disk file matches buffer text."
  (with-text-buffer-v022 (buf)
    (let ((path (temp-text-file "original")))
      (send! "buffer/load-file" :|buffer-id| buf :|path| path)
      (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 8)
      (send! "buffer/insert"     :|buffer-id| buf :|text| " plus more")
      (let ((s-r (send! "buffer/save" :|buffer-id| buf)))
        (assert-ok s-r "buffer/save returns ok"))
      (assert-equal "original plus more" (read-file-string path)
                    "disk content matches buffer"))))

;;; ── A3. save without bound path → fail ────────────────────────────────

(deftest v022-save-fresh-buffer-no-path-fails
  "Calling buffer/save on a never-loaded buffer fails with 'no path'."
  (with-text-buffer-v022 (buf)
    (send! "buffer/insert" :|buffer-id| buf :|text| "scratch")
    (let ((r (send! "buffer/save" :|buffer-id| buf)))
      (assert-fail r "save with no bound path fails")
      (assert-true (search "no path"
                           (or (getf r :|error|) ""))
                   "error message mentions 'no path'"))))

;;; ── A4. error paths ───────────────────────────────────────────────────

(deftest v022-load-file-nonexistent-fails
  "buffer/load-file with a nonexistent path fails cleanly (no crash)."
  (with-text-buffer-v022 (buf)
    (let ((r (send! "buffer/load-file"
                    :|buffer-id| buf
                    :|path|      "/tmp/limn-v022-does-not-exist-xyz")))
      (assert-fail r "load-file on missing path fails")
      (assert-true (search "not found"
                           (or (getf r :|error|) ""))
                   "error mentions 'not found'"))))

(deftest v022-load-file-empty-path-fails
  "buffer/load-file with empty path string fails (path required)."
  (with-text-buffer-v022 (buf)
    (let ((r (send! "buffer/load-file" :|buffer-id| buf :|path| "")))
      (assert-fail r "empty path rejected"))))

;;; ── A5. engine restriction ────────────────────────────────────────────

(deftest v022-load-file-on-mupdf-not-supported
  "buffer/load-file on a mupdf buffer fails with 'not supported'."
  (let* ((r (send! "buffer/load-file"
                   :|buffer-id| "b1"
                   :|path|      "/tmp/whatever.txt"))
         (e (or (getf r :|error|) "")))
    (assert-fail r "load-file on mupdf buffer fails")
    (assert-true (search "not supported" e)
                 "error mentions 'not supported'")))

(deftest v022-save-on-mupdf-not-supported
  "buffer/save on a mupdf buffer fails with 'not supported'."
  (let* ((r (send! "buffer/save" :|buffer-id| "b1"))
         (e (or (getf r :|error|) "")))
    (assert-fail r "save on mupdf buffer fails")
    (assert-true (search "not supported" e)
                 "error mentions 'not supported'")))

;;; ── A6. CJK / UTF-8 content ───────────────────────────────────────────

(deftest v022-load-file-cjk-utf8
  "load-file reads a UTF-8 file with CJK content correctly."
  (with-text-buffer-v022 (buf)
    (let* ((cjk  "你好世界 — limn テスト")
           (path (temp-text-file cjk))
           (r    (send! "buffer/load-file" :|buffer-id| buf :|path| path)))
      (assert-ok r "load-file on CJK content")
      (let* ((tr (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal cjk (json-get* tr :|data| :|text|)
                      "CJK content round-trips bit-for-bit")))))

(deftest v022-save-cjk-utf8
  "save writes CJK content back as valid UTF-8."
  (with-text-buffer-v022 (buf)
    (let* ((path (temp-text-file "")))
      (send! "buffer/load-file" :|buffer-id| buf :|path| path)
      (send! "buffer/insert" :|buffer-id| buf :|text| "你好")
      (send! "buffer/save"   :|buffer-id| buf)
      (assert-equal "你好" (read-file-string path)
                    "CJK saved as UTF-8 on disk"))))

;;; ── A7. empty file ────────────────────────────────────────────────────

(deftest v022-load-empty-file
  "Loading an empty file leaves the buffer empty + cursor 0."
  (with-text-buffer-v022 (buf)
    (let* ((path (temp-text-file ""))
           (r    (send! "buffer/load-file" :|buffer-id| buf :|path| path)))
      (assert-ok r)
      (let ((tr (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal "" (or (json-get* tr :|data| :|text|) ""))))))

;;; ── A8. re-load replaces ──────────────────────────────────────────────

(deftest v022-load-file-replaces-existing-content
  "Loading a second file replaces existing buffer content + resets cursor."
  (with-text-buffer-v022 (buf)
    (let ((p1 (temp-text-file "first content"))
          (p2 (temp-text-file "second")))
      (send! "buffer/load-file" :|buffer-id| buf :|path| p1)
      (send! "buffer/cursor-set" :|buffer-id| buf :|offset| 5)
      (send! "buffer/load-file" :|buffer-id| buf :|path| p2)
      (let ((tr (send! "buffer/text" :|buffer-id| buf))
            (cr (send! "buffer/cursor-get" :|buffer-id| buf)))
        (assert-equal "second" (json-get* tr :|data| :|text|))
        (assert-equal 0 (json-get* cr :|data| :|offset|)
                      "cursor reset after second load")))))

;;; ── A9. save uses last-loaded path ────────────────────────────────────

(deftest v022-save-after-reload-uses-second-path
  "After load-file p1 then load-file p2, save writes to p2 (not p1)."
  (with-text-buffer-v022 (buf)
    (let ((p1 (temp-text-file "one"))
          (p2 (temp-text-file "two")))
      (send! "buffer/load-file" :|buffer-id| buf :|path| p1)
      (send! "buffer/load-file" :|buffer-id| buf :|path| p2)
      (send! "buffer/insert"    :|buffer-id| buf :|text| " edited")
      (send! "buffer/save"      :|buffer-id| buf)
      ;; p1 must be untouched, p2 must have new content
      (assert-equal "one" (read-file-string p1)
                    "p1 untouched after second load+save")
      (assert-true (search "edited" (read-file-string p2))
                   "p2 received the save"))))

;;; ── A10. multiline content ────────────────────────────────────────────

(deftest v022-load-file-multiline
  "Newlines preserved through load-file round-trip."
  (with-text-buffer-v022 (buf)
    (let* ((txt  (format nil "line one~%line two~%line three"))
           (path (temp-text-file txt))
           (r    (send! "buffer/load-file" :|buffer-id| buf :|path| path)))
      (assert-ok r)
      (let ((tr (send! "buffer/text" :|buffer-id| buf)))
        (assert-equal txt (json-get* tr :|data| :|text|)
                      "multiline content preserved")))))

;;; ── A11. larger file ──────────────────────────────────────────────────

(deftest v022-load-file-10kb
  "load-file handles a 10KB file without truncation."
  (with-text-buffer-v022 (buf)
    (let* ((big  (with-output-to-string (s)
                   (dotimes (i 1000)
                     (format s "~a abcdefghi~%" i))))
           (path (temp-text-file big)))
      (send! "buffer/load-file" :|buffer-id| buf :|path| path)
      (let* ((tr  (send! "buffer/text" :|buffer-id| buf))
             (got (or (json-get* tr :|data| :|text|) "")))
        (assert-equal (length big) (length got)
                      "length matches across 10KB roundtrip")
        (assert-equal big got "full content preserved")))))

;;; ── A12. event emission ───────────────────────────────────────────────

(deftest v022-load-file-emits-text-changed-event
  "After load-file, a text-changed event for the buffer is observable."
  (with-text-buffer-v022 (buf)
    (drain-events)
    (let ((path (temp-text-file "hello")))
      (send! "buffer/load-file" :|buffer-id| buf :|path| path))
    (let ((ev (read-event :type "text-changed" :timeout 2)))
      (assert-true ev "a text-changed event was emitted")
      (when ev
        (assert-equal buf (getf ev :|buffer-id|)
                      "event names the right buffer")))))
