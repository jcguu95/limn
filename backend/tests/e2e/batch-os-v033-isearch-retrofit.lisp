;;;; v0.33 retrofit — isearch 改用 isearch-match / lazy-highlight face
;;;;
;;;; v0.26 isearch 原本 hard-code 黃/橘；v0.33 retrofit 後分別走
;;;; isearch-match (primary) 跟 lazy-highlight (其他 match) face。
;;;;
;;;; Ω1 isearch "foo" → 黃高亮（primary）= isearch-match face
;;;; Ω2 同 query 多 match → 其他 match 用 lazy-highlight face（不同色）
;;;; Ω3 primary 色 ≠ lazy 色（兩 face 走獨立 pipeline）

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v033isearch"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp"
             "limn-text-mode.lisp"
             "limn-isearch.lisp"
             "limn.lisp"))
  (handler-case (load (b/ f))
    (error (e) (format t "  !! skipped ~A: ~A~%" f e))))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

(defun sync-face! (name fg)
  (limn:call "display/sync-faces"
             :|faces| (list (list :|name| name :|foreground| fg))))

(defun page-rect (win page)
  (data (limn:call "test/page-pixel-rect" :|win-id| win :|page| page)))

(defun region-bbox (px py pw ph color)
  (data (limn:call "test/region-bbox"
                    :|x0| px :|y0| py
                    :|x1| (+ px pw) :|y1| (+ py ph)
                    :|match-color| color)))

(let* ((sock (format nil "/tmp/limn-e2e-v033isearch-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033isearch.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)

  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "text" :|path| "" :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — text buf (~a)" buf) (stringp buf))

    ;; 三個 foo match 用來區分 primary vs lazy
    (limn:call "buffer/insert"
               :|buffer-id| buf
               :|text| "alpha foo beta foo gamma foo delta")
    (sleep 0.1)

    ;; 為 isearch-match (primary) 設黃、lazy-highlight 設淡橘
    (check "setup — sync isearch-match yellow"
           (ok? (sync-face! "isearch-match" "#ffd700")))
    (check "setup — sync lazy-highlight light orange"
           (ok? (sync-face! "lazy-highlight" "#ffaa55")))

    ;; 觸發 isearch（命令名 limn/isearch:isearch-forward）
    (format t "~%── Ω1: isearch foo + primary match ──~%")
    (let ((r (limn:call "limn/cmd"
                         :|name| "isearch-forward"
                         :|query| "foo"
                         :|buffer-id| buf)))
      (check "Ω1a — isearch-forward executes"
             (ok? r)))
    (sleep 0.3)

    (let* ((pr (page-rect "w1" 0))
           (primary-bbox (and pr (region-bbox
                                  (getf pr :|x|) (getf pr :|y|)
                                  (getf pr :|w|) (getf pr :|h|)
                                  "#ffd700")))
           (lazy-bbox    (and pr (region-bbox
                                  (getf pr :|x|) (getf pr :|y|)
                                  (getf pr :|w|) (getf pr :|h|)
                                  "#ffaa55"))))
      (check (format nil "Ω1b — primary 黃 highlight visible (~s)" primary-bbox)
             (not (null primary-bbox)))
      (check (format nil "Ω2 — lazy orange highlight visible (~s)" lazy-bbox)
             (not (null lazy-bbox)))
      (check "Ω3 — primary != lazy face wire path is separate"
             (and primary-bbox lazy-bbox
                  (not (and (= (getf primary-bbox :|x|) (getf lazy-bbox :|x|))
                            (= (getf primary-bbox :|y|) (getf lazy-bbox :|y|))))))))

  (format t "~%── v033-isearch-retrofit results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
