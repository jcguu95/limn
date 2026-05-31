;;;; limn-marginalia — 候選旁註解（minad Marginalia 的 Lisp 等價後端）
;;;;
;;;; 照抄 minad marginalia 設計：
;;;;   annotate(candidate category) → annotation-string or nil
;;;;
;;;; 支援的 category：
;;;;   :buffer  → 回傳 buffer 的 mode 名稱
;;;;   :file    → 回傳檔案大小與修改時間
;;;;   :command → 回傳 command 的 docstring 前 60 字
;;;;
;;;; 動態變數供 mock injection，方便 unit test 不靠真實檔案系統或 buffer registry。
;;;;
;;;; 純後端、headless 可驗。

(defpackage #:limn/marginalia
  (:use #:cl)
  (:export #:annotate
           ;; mock injection hooks
           #:*marginalia-buffer-mode-fn*
           #:*marginalia-file-attr-fn*
           #:*marginalia-command-doc-fn*))

(in-package #:limn/marginalia)

;;; ─── Mock injection hooks ────────────────────────────────────────────

(defvar *marginalia-buffer-mode-fn* nil
  "If non-nil, a function (buffer-name) → mode-name string or nil.
   Default fallback: try limn/excursion:get-buffer → limn/mode:major-mode → mode-name.")

(defvar *marginalia-file-attr-fn* nil
  "If non-nil, a function (file-name) → (size . mtime-seconds) or nil.
   size 為整數（bytes），mtime-seconds 為 universal time 整數。
   Default fallback: try probing file on disk.")

(defvar *marginalia-command-doc-fn* nil
  "If non-nil, a function (command-name) → docstring or nil.
   Default fallback: try limn/cmd or limn/introspect to look up docstring.")

;;; ─── annotate ────────────────────────────────────────────────────────

(defun annotate (candidate category)
  "為 CANDIDATE 產生 CATEGORY 對應的 annotation 字串。
   
   :buffer → 回傳該 buffer 的 major mode 名稱，如 \"text-mode\"。
             若無法取得 mode，回傳 nil。
   
   :file   → 回傳檔案大小與修改時間的格式化字串，如 \"12K 2025-06-01\"。
             若無法取得檔案屬性，回傳 nil。
   
   :command → 回傳該 command 的 docstring 前 60 字元，
              如 \"Insert a newline and indent...\"。
              若無法取得 docstring，回傳 nil。
   
   未知 category → 回傳 nil。"
  (case category
    (:buffer  (%annotate-buffer candidate))
    (:file    (%annotate-file candidate))
    (:command (%annotate-command candidate))
    (otherwise nil)))

;;; ─── buffer annotation ───────────────────────────────────────────────

(defun %annotate-buffer (candidate)
  "為 buffer CANDIDATE（名稱字串）產生 mode annotation。"
  (if *marginalia-buffer-mode-fn*
      (funcall *marginalia-buffer-mode-fn* candidate)
      ;; fallback: try limn/excursion:get-buffer → limn/mode:major-mode
      (let* ((excursion-pkg (find-package '#:limn/excursion))
             (mode-pkg      (find-package '#:limn/mode))
             (mode-name     nil))
        (when (and excursion-pkg mode-pkg)
          (let ((get-buf-sym  (find-symbol "GET-BUFFER" excursion-pkg))
                (major-sym    (find-symbol "MAJOR-MODE" mode-pkg))
                (find-mode-sym (find-symbol "FIND-MODE" mode-pkg)))
            (when (and get-buf-sym (fboundp get-buf-sym)
                       major-sym (fboundp major-sym)
                       find-mode-sym (fboundp find-mode-sym))
              (let ((buf (funcall get-buf-sym candidate)))
                (when buf
                  (let ((major (funcall major-sym buf)))
                    (when major
                      (let ((mode (funcall find-mode-sym major)))
                        (when mode
                          (setf mode-name
                                (let ((mn-sym (find-symbol "MODE-NAME" mode-pkg)))
                                  (if (and mn-sym (fboundp mn-sym))
                                      (funcall mn-sym mode)
                                      major))))))))))))
        (when mode-name
          (princ-to-string mode-name)))))

;;; ─── file annotation ─────────────────────────────────────────────────

(defun %annotate-file (candidate)
  "為檔案 CANDIDATE（路徑字串）產生檔案大小/時間 annotation。"
  (labels ((format-size (bytes)
             "格式化 bytes 為 human-readable 字串，如 12K、1.3M。"
             (cond
               ((>= bytes 1048576)
                (format nil "~,1fM" (/ bytes 1048576.0)))
               ((>= bytes 1024)
                (format nil "~dK" (round bytes 1024)))
               (t
                (format nil "~dB" bytes))))
           (format-time (universal-seconds)
             "格式化 universal time 為 YYYY-MM-DD 字串。"
             (multiple-value-bind (sec min hour day month year)
                 (decode-universal-time universal-seconds 0)
               (declare (ignore sec min hour))
               (format nil "~4,'0d-~2,'0d-~2,'0d" year month day))))
    (if *marginalia-file-attr-fn*
        (let ((attr (funcall *marginalia-file-attr-fn* candidate)))
          (when attr
            (format nil "~a ~a"
                    (format-size (car attr))
                    (format-time (cdr attr)))))
        ;; fallback: try probing file on disk
        (handler-case
            (let ((probe (probe-file candidate)))
              (when probe
                (let* ((size  (with-open-file (s probe :element-type '(unsigned-byte 8))
                                (file-length s)))
                       (mtime (file-write-date probe)))
                  (format nil "~a ~a"
                          (format-size size)
                          (format-time mtime)))))
          (error ()
            nil)))))

;;; ─── command annotation ──────────────────────────────────────────────

(defun %annotate-command (candidate)
  "為 command CANDIDATE（指令名稱 symbol 或字串）產生 docstring annotation。
   回傳 docstring 的前 60 字元。"
  (labels ((get-doc (name)
             "Try to get the function docstring for NAME (symbol)."
             (when (and (symbolp name) (fboundp name))
               (documentation name 'function)))
           (first-60 (doc)
             "Truncate DOC to first 60 characters."
             (if (and doc (> (length doc) 60))
                 (subseq doc 0 60)
                 doc)))
    (let ((raw (if *marginalia-command-doc-fn*
                   (funcall *marginalia-command-doc-fn* candidate)
                   ;; fallback: try to lookup the docstring directly
                   (let ((sym (if (symbolp candidate)
                                  candidate
                                  ;; Try to intern the string as a symbol in CL-USER
                                  (find-symbol (string-upcase candidate) '#:cl-user))))
                     (get-doc sym)))))
      (when raw
        (first-60 raw)))))
