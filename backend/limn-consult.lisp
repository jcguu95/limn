;;;; limn-consult — Consult 搜尋/導航指令（minad Consult 的 Lisp 等價後端）
;;;;
;;;; 照抄 minad consult 設計：每個 consult 指令的模式都是
;;;;   建候選集 → 建 Vertico session → 使用者輸入/選取 → 執行 action
;;;;
;;;; 實作：
;;;;   consult-buffer-candidates() → 已開啟的 buffer 名稱 list
;;;;   consult-line-candidates(buffer-content) → "N:text" 格式的行 list
;;;;   consult-find-file-candidates(directory) → filename list
;;;;   run-consult(candidates action-fn &key prompt move) → headless 模擬
;;;;
;;;; 動態變數供 mock injection，方便 unit test 不靠真實檔案系統或 buffer registry。
;;;;
;;;; 純後端、headless 可驗。

(defpackage #:limn/consult
  (:use #:cl)
  (:export #:consult-buffer-candidates
           #:consult-line-candidates
           #:consult-find-file-candidates
           #:run-consult
           ;; mock injection hooks
           #:*consult-buffer-list-fn*
           #:*consult-directory-files-fn*))

(in-package #:limn/consult)

;;; ─── Mock injection hooks ────────────────────────────────────────────

(defvar *consult-buffer-list-fn* nil
  "If non-nil, a thunk () → list of buffer-name strings.
   Default fallback: try limn/excursion:buffer-list → buffer-name.")

(defvar *consult-directory-files-fn* nil
  "If non-nil, a function (directory) → list of filename strings.
   Default fallback: try uiop:directory-files or sb-posix directory listing.")

;;; ─── consult-buffer-candidates ───────────────────────────────────────

(defun consult-buffer-candidates ()
  "回傳目前已開啟的所有 buffer 名稱 list。
   優先使用 *consult-buffer-list-fn*（若已設定），否則 fallback 到
   limn/excursion 的 buffer-list → buffer-name。"
  (if *consult-buffer-list-fn*
      (funcall *consult-buffer-list-fn*)
      (let ((excursion-pkg (find-package '#:limn/excursion)))
        (if excursion-pkg
            (let ((buffer-list-sym (find-symbol "BUFFER-LIST" excursion-pkg))
                  (buffer-name-sym (find-symbol "BUFFER-NAME" excursion-pkg)))
              (if (and buffer-list-sym (fboundp buffer-list-sym)
                       buffer-name-sym (fboundp buffer-name-sym))
                  (let ((bufs (funcall buffer-list-sym))
                        (names '()))
                    (dolist (b bufs)
                      (let ((n (funcall buffer-name-sym b)))
                        (when n (push n names))))
                    (nreverse names))
                  ;; fallback: empty
                  '()))
            ;; no limn/excursion loaded → empty
            '()))))

;;; ─── consult-line-candidates ─────────────────────────────────────────

(defun consult-line-candidates (buffer-content)
  "將 BUFFER-CONTENT 字串按行拆分，回傳 \"N:text\" 格式的候選 list。
   N 為 1-based 行號。空行也會產生一個候選（N:）。"
  (let ((lines '())
        (n 1)
        (start 0)
        (len (length buffer-content)))
    (if (zerop len)
        ;; 空內容仍有一行（空行）
        '("1:")
        (progn
          (loop for i from 0 below len
                when (char= (char buffer-content i) #\Newline)
                  do (push (format nil "~a:~a" n (subseq buffer-content start i)) lines)
                     (incf n)
                     (setf start (1+ i)))
          ;; 最後一行（換行後仍有內容，或結尾無換行的最後一行）
          (push (format nil "~a:~a" n (subseq buffer-content start len)) lines)
          (nreverse lines)))))

;;; ─── consult-find-file-candidates ────────────────────────────────────

(defun consult-find-file-candidates (&optional (directory
                                                (let ((file-pkg (find-package '#:limn/file)))
                                                  (if file-pkg
                                                      (let ((dd-sym (find-symbol "*DEFAULT-DIRECTORY*" file-pkg)))
                                                        (if (and dd-sym (boundp dd-sym))
                                                            (symbol-value dd-sym)
                                                            "/"))
                                                      "/"))))
  "回傳 DIRECTORY 下的 filename list（不含子目錄內容，僅檔名）。
   優先使用 *consult-directory-files-fn*（若已設定），否則 fallback 到
   uiop:directory-files 或 sb-posix:readdir。"
  (if *consult-directory-files-fn*
      (funcall *consult-directory-files-fn* directory)
      ;; fallback: try uiop then sb-posix
      (let* ((uiop-pkg (find-package '#:uiop))
             (dir-fn  (and uiop-pkg
                           (find-symbol "DIRECTORY-FILES" uiop-pkg))))
        (cond
          ((and dir-fn (fboundp dir-fn))
           (funcall dir-fn directory))
          (t
           ;; Last-resort: try sb-posix readdir
           (handler-case
               (let* ((dir (sb-posix:opendir directory))
                      (files '()))
                 (unwind-protect
                      (loop for entry = (sb-posix:readdir dir)
                            while entry
                            for name = (sb-posix:dirent-name entry)
                            do (unless (or (string= name ".")
                                           (string= name ".."))
                                 (push name files)))
                   (sb-posix:closedir dir))
                 (nreverse files))
             (error ()
               ;; In headless test with no real filesystem, return empty list.
               ;; Caller should use *consult-directory-files-fn* to mock.
               '())))))))

;;; ─── run-consult（headless 模擬）─────────────────────────────────────

(defun run-consult (candidates action-fn &key (prompt "") (move 0))
  "Headless 模擬 completing-read + vertico session 的完整流程。
   
   建立 Vertico session（候選集 = CANDIDATES）、
   套用 MOVE 偏移（選中非第一個候選）、
   取目前選中候選並呼叫 ACTION-FN。
   
   回傳 ACTION-FN 的結果。
   
   MOVE: 從第一個候選（index 0）偏移的步數，正數向下、負數向上。
   PROMPT: 提示字串（headless 模式僅記錄，不顯示）。
   
   若候選集為空或 current 為 nil，則 signal error。"
  (declare (ignore prompt))
  (unless candidates
    (error "run-consult: empty candidates list"))
  (let ((session (limn/vertico:make-session candidates :window-size (max 10 (length candidates)))))
    ;; 若有 move，則移動選中索引
    (unless (zerop move)
      (limn/vertico:session-move session move))
    (let ((candidate (limn/vertico:session-current session)))
      (unless candidate
        (error "run-consult: no candidate at index ~a (filtered=~a)"
               (limn/vertico:session-index session)
               (limn/vertico:session-filtered-candidates session)))
      (funcall action-fn candidate))))
