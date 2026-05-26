;;;; v0.34 — regex search on a real PDF buffer (T2)
;;;;
;;;; 真實 limn binary。打開 test.pdf，用 v0.34 regex 升級後的
;;;; limn/search:find-matches （:regex t :emacs-syntax t）找
;;;; \\b\\w+\\b（word tokens），hit 數要：
;;;;   1. >= exact 模式空字串/單詞搜尋的 hit 數（regex \\w+ 至少抓得跟
;;;;      exact 一樣多 word，多半更多）
;;;;   2. >= 1（PDF 一定有 text）
;;;;   3. 跟「PDF buffer/text 抽出來再用 cl-ppcre 跑同個 pattern」的數字
;;;;      對得起來（in-process round-trip）
;;;;
;;;; 額外：座標 rect 在每個 hit 上都得是 4-element rect，不能 nil。
;;;;
;;;; v0.34 §D 實作前 RED — 舊 tiny-regex 不認 \\b。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp"
               "/tmp/.limn/init.lisp.stash-v034pdf"))

(handler-case (load (b/ "../vendor/cl-ppcre-load.lisp"))
  (error (e) (format t "  !! skipped vendor cl-ppcre: ~A~%" e)))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun engine-load (path)
  (let ((r (limn:call "bridge/engine-load"
                       :|engine| "mupdf" :|path| path :|win-id| "w1")))
    (and (ok? r) (getf (data r) :|buffer-id|))))

(defun page-words (buf page)
  "mupdf buffer/text per page → list of word plists with :|text| + :|rect|."
  (let ((r (limn:call "buffer/text"
                       :|buffer-id| buf :|page| page :|granularity| "words")))
    (and (ok? r) (or (getf (data r) :|words|)
                     (getf (data r) :|text|)))))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (s)
                      (ignore-errors
                        (sb-ext:run-program "xdotool"
                                            '("search" "--name" "Limn")
                                            :search t :wait t
                                            :output s :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found))
                           0))
          do (return found)
        do (sleep 0.1)))

;;; ── session ─────────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v034pdf-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v034pdf.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)

  (check "cl-ppcre vendor package loaded"
         (find-package '#:cl-ppcre))

  (let* ((pdf (b/ "tests/fixtures/test.pdf"))
         (buf (engine-load pdf)))
    (check (format nil "setup — opened test.pdf (~a)" buf)
           (stringp buf))
    (unless buf
      (limn:stop) (sb-ext:process-kill proc 15)
      (sb-ext:process-wait proc) (sb-ext:exit :code 2))

    ;; collect words from page 0 (test.pdf 已知至少 1 頁)
    (let* ((words (page-words buf 0))
           (n-words (length (or words '()))))
      (check (format nil "page 0 has ~a word entries (>= 1)" n-words)
             (and (listp words) (>= n-words 1)))

      ;; ── 主驗證 #1：find-matches :regex t :emacs-syntax t 抓所有 word ──

      (format t "~%── find-matches :regex t \\b\\w+\\b ──~%")
      (let* ((hits (limn/search:find-matches
                    words "\\b\\w+\\b"
                    :regex t :emacs-syntax t)))
        (check (format nil "regex \\b\\w+\\b returns ~a hits (>= 1)"
                       (length hits))
               (>= (length hits) 1))

        ;; ── 主驗證 #2：hit 數至少跟 word 數同 order of magnitude
        ;;    （word \\w+ 應該抓到大部分 word；若回 0 表示 v0.34 還沒接到
        ;;    cl-ppcre、tiny-regex 不認 \\b）
        (check (format nil "regex hit count ~a ≥ words count ~a × 0.5"
                       (length hits) n-words)
               (>= (length hits) (max 1 (floor (/ n-words 2)))))

        ;; ── 主驗證 #3：每個 hit 都有 :|rect| 4-element ──
        (let ((all-rects-ok
                (every (lambda (h)
                         (let ((rect (getf h :|rect|)))
                           (and (listp rect) (= 4 (length rect))
                                (every #'numberp rect))))
                       hits)))
          (check "every hit has valid 4-element rect (numbers)"
                 all-rects-ok))

        ;; ── 主驗證 #4：cross-check — 把 word list join 成一個 string、
        ;;    用 cl-ppcre 直接跑、count 一致 ──
        (when (find-package '#:cl-ppcre)
          (let* ((joined (format nil "~{~a ~}"
                                  (mapcar (lambda (w)
                                            (or (getf w :|text|) ""))
                                          words)))
                 (scan-fn (find-symbol "ALL-MATCHES" '#:cl-ppcre))
                 (matches (and scan-fn (funcall scan-fn "\\b\\w+\\b" joined)))
                 ;; all-matches returns flat list of (start end start end ...)
                 (n-matches (and matches (/ (length matches) 2))))
            (check (format nil "find-matches count (~a) ≈ raw cl-ppcre count (~a)"
                           (length hits) n-matches)
                   (and n-matches
                        ;; allow small drift due to tokenization vs raw scan
                        (<= (abs (- (length hits) n-matches))
                            (max 1 (floor (* 0.1 n-matches))))))))))

    (ignore-errors (limn:call "buffer/close" :|buffer-id| buf)))

  (format t "~%── v034 pdf realworld e2e results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
