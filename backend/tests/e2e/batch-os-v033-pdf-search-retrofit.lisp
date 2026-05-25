;;;; v0.33 retrofit — pdf-search 改用 face、theme 切換 live update
;;;;
;;;; v0.27 pdf-search 高亮原本 hard-code 黃色；v0.33 retrofit 後改用
;;;; pdf-search-match face。本測試驗：
;;;;
;;;; Ω1 載入 pdf、搜尋一字 → 黃色高亮 pixel = pdf-search-match face 預設
;;;; Ω2 改 face foreground → 重 search 後高亮顏色跟著變

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(load (concatenate 'string *bdir* "tests/e2e/load-limn-system.lisp"))

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

(let* ((sock (format nil "/tmp/limn-e2e-v033pdfretro-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v033pdfretro.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)

  (let* ((er (limn:call "bridge/engine-load"
                         :|engine| "mupdf"
                         :|path| (b/ "tests/fixtures/test.pdf")
                         :|win-id| "w1"))
         (buf (and (ok? er) (getf (data er) :|buffer-id|))))
    (check (format nil "setup — buffer (~a)" buf) (stringp buf))

    ;;; v0.37 Phase F (driver-A7): the original test called
    ;;; (limn:call "buffer/search-pdf" ...) but the C++ wire command is
    ;;; "buffer/search" — and it only RETURNS hits, it doesn't push
    ;;; highlight overlays.  Helper below does both: run search, then
    ;;; push a single view/overlays call with rect layers tagged with
    ;;; the pdf-search-match face.  The retrofit being tested is the
    ;;; face-based color routing — i.e. changing the face's foreground
    ;;; should change the highlight color on the next push.

    (defun run-search-and-push (query face)
      "Run buffer/search; push hit rects as view/overlays layers
       tagged with FACE so they pick up the synced color."
      (let* ((r (limn:call "buffer/search" :|buffer-id| buf :|query| query))
             (hits (and (ok? r) (or (getf (data r) :|hits|) '())))
             (layers
               (loop for hit in hits
                     for page = (getf hit :|page|)
                     for rects = (or (getf hit :|rects|) '())
                     append
                     (loop for rect in rects
                           collect
                           (list :|type| "rect"
                                 :|page| page
                                 :|rect| rect
                                 :|face| face
                                 :|opacity| 0.5)))))
        (cons (ok? r)
              (limn:call "view/overlays" :|win-id| "w1"
                          :|layers| layers))))

    ;; Ω1 baseline: pdf-search-match face → 黃 (#FFD700) 預設
    (format t "~%── Ω1: pdf-search 用 pdf-search-match face 預設黃 ──~%")
    (check "Ω1a — sync default yellow"
           (ok? (sync-face! "pdf-search-match" "#ffd700")))
    (let ((rsp (run-search-and-push "the" "pdf-search-match")))
      (check "Ω1b — pdf-search executes"
             (and (car rsp) (ok? (cdr rsp)))))
    (sleep 0.3)
    (let* ((pr (page-rect "w1" 0))
           (bbox (and pr (region-bbox (getf pr :|x|) (getf pr :|y|)
                                       (getf pr :|w|) (getf pr :|h|)
                                       "#ffd700"))))
      (check (format nil "Ω1c — yellow search highlight visible (~s)" bbox)
             (not (null bbox))))

    ;; Ω2: 改 face → 重 search → 新顏色
    (format t "~%── Ω2: theme 改 face → 高亮顏色跟著變 ──~%")
    (check "Ω2a — sync orange (#FFA500)"
           (ok? (sync-face! "pdf-search-match" "#ffa500")))
    (let ((rsp (run-search-and-push "the" "pdf-search-match")))
      (check "Ω2b — pdf-search re-run"
             (and (car rsp) (ok? (cdr rsp)))))
    (sleep 0.3)
    (let* ((pr (page-rect "w1" 0))
           (bbox (and pr (region-bbox (getf pr :|x|) (getf pr :|y|)
                                       (getf pr :|w|) (getf pr :|h|)
                                       "#ffa500"))))
      (check (format nil "Ω2c — orange search highlight visible (~s)" bbox)
             (not (null bbox)))))

  (format t "~%── v033-pdf-search-retrofit results ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
