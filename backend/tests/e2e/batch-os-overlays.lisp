;;;; Batch 24: v0.14 view/overlays paintGL — VM-level e2e.
;;;;
;;;; 把 view/overlays 的 v0.14 新 contract 在真實 Linux container + Xvfb +
;;;; openbox 環境裡跑一遍。Qt-level suite 已驗 state + paint 細節；
;;;; 這層的職責是「整段 pipeline 在真 OS 上仍通」：
;;;;
;;;;   - 真 binary 跑 / 真 socket
;;;;   - 真實 Xvfb backing store paint（不是 offscreen mock）
;;;;   - overlays survive 真實 key inject (j/k 翻頁、minibuffer 開合)
;;;;   - engine-load 真的把 overlays 重置（contract）
;;;;   - 多視窗 (bridge/win-split) overlays 不互相污染
;;;;
;;;; 全部 RED 直到 v0.14 ship 完真實 paintGL + state persist + view/get
;;;; :overlays + :overlay-count 欄位 + engine-load auto-reset。

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(defun xdotool (&rest args)
  (let ((p (sb-ext:run-program "xdotool" args :search t
                                :wait t :output t :error t)))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "xdotool ~{~a~^ ~} exited non-zero" args))))

(defun xdotool-stdout (&rest args)
  (with-output-to-string (s)
    (let ((p (sb-ext:run-program "xdotool" args :search t
                                  :wait t :output s :error t)))
      (unless (zerop (sb-ext:process-exit-code p))
        (error "xdotool ~{~a~^ ~} exited non-zero" args)))))

(defun wait-for-window-by-name (name &key (timeout 5))
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (let ((s (string-trim '(#\Space #\Newline #\Tab)
                             (handler-case
                                 (xdotool-stdout "search" "--name" name)
                               (error () "")))))
        (unless (zerop (length s))
          (return (parse-integer
                   (subseq s 0 (or (position #\Newline s) (length s)))))))
      (when (> (get-universal-time) deadline)
        (error "Timed out waiting for window named ~s" name))
      (sleep 0.1))))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-ov"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun grab-lum ()
  "test/grab-window → avg-luminance (real Xvfb backing store)."
  (let ((r (limn:call "test/grab-window")))
    (getf (limn/bridge:response-data r) :|avg-luminance|)))

(let* ((sock (format nil "/tmp/limn-e2e-ov-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-ov.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

;;; ── Ω1: state round-trip via real socket ──────────────────────────

    (format t "~%── Ω1: view/get :overlays round-trip ──~%")
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.1 0.1 0.5 0.5)
                                   :|color| "#FF0000" :|opacity| 0.7)))
    (sleep 0.2)
    (let* ((d (limn/bridge:response-data (limn:call "view/get" :|win-id| "w1")))
           (ov (getf d :|overlays|))
           (oc (getf d :|overlay-count|)))
      (check (format nil "Ω1 — view/get returns :overlay-count == 1 (got ~a)" oc)
             (eql oc 1))
      (check (format nil "Ω1 — view/get returns :overlays list len 1 (got ~a)"
                     (and (listp ov) (length ov)))
             (and (listp ov) (= 1 (length ov))))
      (when (and (listp ov) (= 1 (length ov)))
        (let ((l (first ov)))
          (check (format nil "Ω1 — round-trip preserves :type (got ~s)"
                         (getf l :|type|))
                 (equal "rect" (getf l :|type|)))
          (check (format nil "Ω1 — round-trip preserves :color (got ~s)"
                         (getf l :|color|))
                 (equal "#FF0000" (getf l :|color|))))))

;;; ── Ω2: paintGL actually paints on real Xvfb ──────────────────────

    (format t "~%── Ω2: real Xvfb paint reflects overlay ──~%")
    (limn:call "view/overlays" :|win-id| "w1" :|layers| nil)
    (sleep 0.3)
    (let ((baseline (grab-lum)))
      (limn:call "view/overlays" :|win-id| "w1"
                  :|layers| (list '(:|type| "rect" :|page| 0
                                     :|rect| (0.0 0.0 1.0 1.0)
                                     :|color| "#000000" :|opacity| 1.0)))
      (sleep 0.3)
      (let ((after (grab-lum)))
        (check (format nil "Ω2 — full-black overlay drops luminance (baseline=~a after=~a)"
                       baseline after)
               (and baseline after (> (- baseline after) 5.0)))))

;;; ── Ω3: clear restores paint state ────────────────────────────────

    (format t "~%── Ω3: clear restores paint baseline ──~%")
    (let ((baseline (grab-lum)))
      (limn:call "view/overlays" :|win-id| "w1"
                  :|layers| (list '(:|type| "rect" :|page| 0
                                     :|rect| (0.0 0.0 1.0 1.0)
                                     :|color| "#000000" :|opacity| 1.0)))
      (sleep 0.3)
      (limn:call "view/overlays" :|win-id| "w1" :|layers| nil)
      (sleep 0.3)
      (let ((after (grab-lum)))
        (check (format nil "Ω3 — after clear lum ≈ baseline (~a vs ~a)"
                       baseline after)
               (and baseline after (< (abs (- baseline after)) 2.0)))))

;;; ── Ω4: overlays survive key inject (page nav) ────────────────────

    (format t "~%── Ω4: overlays survive xdotool key inject ──~%")
    (limn:call "view/set" :|win-id| "w1" :|page| 0)
    (sleep 0.2)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.2 0.2 0.4 0.4)
                                   :|color| "#0000FF" :|opacity| 0.8)
                                '(:|type| "rect" :|page| 0
                                   :|rect| (0.6 0.6 0.8 0.8)
                                   :|color| "#00FF00" :|opacity| 0.8)))
    (sleep 0.2)
    ;; xdotool key inject — j/k should not touch overlays
    (xdotool "key" "--clearmodifiers" "j")
    (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "k")
    (sleep 0.2)
    (let* ((d (limn/bridge:response-data (limn:call "view/get" :|win-id| "w1")))
           (oc (getf d :|overlay-count|))
           (ov (getf d :|overlays|)))
      (check (format nil "Ω4 — :overlay-count == 2 after j/k inject (got ~a)" oc)
             (eql oc 2))
      (check (format nil "Ω4 — :overlays list len 2 (got ~a)"
                     (and (listp ov) (length ov)))
             (and (listp ov) (= 2 (length ov)))))

;;; ── Ω5: engine-load resets overlays (contract) ────────────────────

    (format t "~%── Ω5: engine-load resets overlays ──~%")
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.0 0.0 0.5 0.5)
                                   :|color| "#FF0000" :|opacity| 0.5)))
    (sleep 0.2)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)
    (let* ((d (limn/bridge:response-data (limn:call "view/get" :|win-id| "w1")))
           (oc (getf d :|overlay-count|)))
      (check (format nil "Ω5 — engine-load resets :overlay-count to 0 (got ~a)" oc)
             (eql oc 0)))

;;; ── Ω6: page filter — overlay on wrong page invisible ────────────

    (format t "~%── Ω6: page-filtered overlay doesn't render off-page ──~%")
    (limn:call "view/set" :|win-id| "w1" :|page| 0)
    (sleep 0.2)
    (limn:call "view/overlays" :|win-id| "w1" :|layers| nil)
    (sleep 0.3)
    (let ((baseline (grab-lum)))
      (limn:call "view/overlays" :|win-id| "w1"
                  :|layers| (list '(:|type| "rect" :|page| 5
                                     :|rect| (0.0 0.0 1.0 1.0)
                                     :|color| "#000000" :|opacity| 1.0)))
      (sleep 0.3)
      (let ((after (grab-lum)))
        (check (format nil "Ω6 — page-5 overlay leaves page-0 view unchanged (~a vs ~a)"
                       baseline after)
               (and baseline after (< (abs (- baseline after)) 2.0)))))

;;; ── Ω7: multi-window isolation ────────────────────────────────────

    (format t "~%── Ω7: bridge/win-split — w2 doesn't see w1's overlays ──~%")
    (limn:call "view/overlays" :|win-id| "w1" :|layers| nil)
    (sleep 0.2)
    (limn:call "bridge/win-split" :|orient| "horizontal")
    (sleep 0.3)
    (limn:call "view/overlays" :|win-id| "w1"
                :|layers| (list '(:|type| "rect" :|page| 0
                                   :|rect| (0.0 0.0 0.5 0.5)
                                   :|color| "#FF0000" :|opacity| 0.5)))
    (sleep 0.2)
    (let* ((d2 (limn/bridge:response-data (limn:call "view/get" :|win-id| "w2")))
           (oc2 (getf d2 :|overlay-count|)))
      (check (format nil "Ω7 — w2's :overlay-count is 0 (got ~a)" oc2)
             (eql oc2 0)))

;;; ── final verdict ────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 24 overlays paintGL green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-ov")
        (rename-file "/tmp/.limn/init.lisp.stash-ov" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
