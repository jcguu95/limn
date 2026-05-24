;;;; v0.22 Phase C — OS-tier visual driver
;;;;
;;;; 驗 text-engine 在畫面上真的有字、字型對、換行對、cursor 同步對。
;;;; 全部用新 wire 命令 test/text-widget-snapshot：
;;;;   { png, width, height, avg-luminance, pixel-variance }
;;;; 不用 OCR、不用 ImageMagick；只靠 stats + bytes 比較。
;;;;
;;;; QPlainTextEdit 不走 OpenGL，在 Xvfb 下會真的 render（這跟
;;;; batch-os-visual.lisp F2 的 infra 限制相反）。
;;;;
;;;; 全部 v0.22 Phase C 實作前紅。

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v022d"))

(dolist (f '("limn-hooks.lisp" "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp"  "limn-undo.lisp"   "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp"  "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp"
             "limn-text-mode.lisp" "limn.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun snap (&optional (win "w1"))
  "Call test/text-widget-snapshot for WIN, return plist of stats + png."
  (let* ((r (limn:call "test/text-widget-snapshot" :|win-id| win))
         (d (limn/bridge:response-data r)))
    (list :ok       (eq (getf r :|ok|) t)
          :width    (getf d :|width|)
          :height   (getf d :|height|)
          :lum      (getf d :|avg-luminance|)
          :var      (getf d :|pixel-variance|)
          :png      (getf d :|png|)
          :png-len  (length (or (getf d :|png|) "")))))

(defun snaps-differ-p (s1 s2)
  "Two snaps differ if their PNG bytes (base64 strings) are not equal."
  (not (equal (getf s1 :png) (getf s2 :png))))

(defun set-text (buf str)
  "Replace buffer content via wire (no xdotool — for visual setup)."
  (let* ((tr  (limn:call "buffer/text" :|buffer-id| buf))
         (old (or (getf (limn/bridge:response-data tr) :|text|) "")))
    (when (plusp (length old))
      (limn:call "buffer/delete" :|buffer-id| buf
                  :|from| 0 :|to| (length old)))
    (when (plusp (length str))
      (limn:call "buffer/insert" :|buffer-id| buf :|text| str))))

(defun open-text-buffer (&optional (win "w1"))
  (let* ((r (limn:call "bridge/engine-load"
                        :|win-id| win :|engine| "text" :|path| ""))
         (d (limn/bridge:response-data r)))
    (getf d :|buffer-id|)))

(let* ((sock (format nil "/tmp/limn-e2e-v022d-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v022d.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.4)

;;; ── C0. 命令存在性 sanity ───────────────────────────────────────────

    (format t "~%── C0: test/text-widget-snapshot is wired ──~%")
    (let* ((buf (open-text-buffer))
           (s   (snap)))
      (declare (ignorable buf))
      (check "command returns ok" (getf s :ok)
             (format nil "snap=~s" s))
      (check "width > 0" (and (integerp (getf s :width))
                              (> (getf s :width) 0)))
      (check "height > 0" (and (integerp (getf s :height))
                               (> (getf s :height) 0)))
      (check "png bytes non-empty" (> (getf s :png-len) 0)))

;;; ── C1. 基本顯示 ───────────────────────────────────────────────────

    (format t "~%── C1: empty buffer renders bright + uniform ──~%")
    (let* ((buf (open-text-buffer))
           (s   (snap)))
      (declare (ignorable buf))
      ;; Empty buffer = white background → high luminance, low variance.
      (check (format nil "empty: lum >= 200 (got ~a)" (getf s :lum))
             (and (numberp (getf s :lum)) (>= (getf s :lum) 200)))
      (check (format nil "empty: variance < 200 (got ~a)" (getf s :var))
             (and (numberp (getf s :var)) (< (getf s :var) 200))))

    (format t "~%── C1b: text increases variance ──~%")
    (let* ((buf (open-text-buffer))
           (s0  (snap)))
      (set-text buf "LIMN TEXT ENGINE TEST")
      (sleep 0.2)
      (let ((s1 (snap)))
        (check "snapshot changed after inserting text"
               (snaps-differ-p s0 s1))
        (check (format nil "variance went UP (~a → ~a)"
                        (getf s0 :var) (getf s1 :var))
               (and (numberp (getf s0 :var)) (numberp (getf s1 :var))
                    (> (getf s1 :var) (getf s0 :var))))))

    (format t "~%── C1c: delete restores variance close to empty ──~%")
    (let* ((buf (open-text-buffer))
           (empty (snap)))
      (set-text buf "ABCDEF")
      (sleep 0.15)
      (let ((with-text (snap)))
        (set-text buf "")  ; clear
        (sleep 0.15)
        (let ((after-delete (snap)))
          (check "with-text variance > empty variance"
                 (> (getf with-text :var) (getf empty :var)))
          (check "after-delete returns to near-empty variance"
                 (< (abs (- (getf after-delete :var) (getf empty :var))) 50)
                 (format nil "empty=~a, after=~a"
                         (getf empty :var) (getf after-delete :var))))))

;;; ── C2. 換行行為 ──────────────────────────────────────────────────

    (format t "~%── C2: line wrap on long text ──~%")
    (let* ((buf (open-text-buffer)))
      (set-text buf "short")
      (sleep 0.15)
      (let ((short-snap (snap)))
        (set-text buf
          (with-output-to-string (s)
            (dotimes (i 30) (format s "verylongword~a " i))))
        (sleep 0.2)
        (let ((long-snap (snap)))
          (check "long-text snapshot differs from short"
                 (snaps-differ-p short-snap long-snap))
          (check "long-text has higher variance (more rows of pixels)"
                 (> (getf long-snap :var) (getf short-snap :var))
                 (format nil "short.var=~a, long.var=~a"
                         (getf short-snap :var) (getf long-snap :var))))))

    (format t "~%── C2b: explicit \\n produces multi-row layout ──~%")
    (let* ((buf (open-text-buffer)))
      (set-text buf "one")
      (sleep 0.15)
      (let ((one (snap)))
        (set-text buf "one
two
three")
        (sleep 0.15)
        (let ((three (snap)))
          (check "multi-line snap differs from single-line"
                 (snaps-differ-p one three))
          ;; Each extra line adds dark pixels → lower avg-luminance
          (check "multi-line average luminance is lower"
                 (< (getf three :lum) (getf one :lum))
                 (format nil "one.lum=~a, three.lum=~a"
                         (getf one :lum) (getf three :lum))))))

;;; ── C3. Tofu box 偵測（字型對 / CJK glyph 真的有畫） ──────────────

    (format t "~%── C3: ASCII vs CJK render differently (tofu detection) ──~%")
    (let* ((buf (open-text-buffer)))
      (set-text buf "abc")
      (sleep 0.15)
      (let ((s-ascii (snap)))
        (set-text buf "一二三")
        (sleep 0.15)
        (let ((s-cjk (snap)))
          ;; Tofu would produce IDENTICAL PNG bytes (same hollow box per
          ;; missing glyph). Different PNG bytes = different glyphs rendered.
          (check "CJK snapshot differs from ASCII (not all rendered as tofu)"
                 (snaps-differ-p s-ascii s-cjk)))))

    (format t "~%── C3b: mixed ASCII+CJK renders distinctly from pure ASCII ──~%")
    (let* ((buf (open-text-buffer)))
      (set-text buf "aaa bbb ccc ddd eee")
      (sleep 0.15)
      (let ((s-ascii (snap)))
        (set-text buf "abc 一二三 hello 世界")
        (sleep 0.15)
        (let ((s-mixed (snap)))
          (check "mixed-script snapshot differs from pure-ASCII baseline"
                 (snaps-differ-p s-ascii s-mixed)))))

;;; ── C4. cursor 與同步 ─────────────────────────────────────────────

    (format t "~%── C4: insert at mid-cursor shows mid-text, not at end ──~%")
    (let* ((buf (open-text-buffer)))
      (set-text buf "AAAAAA")
      (sleep 0.15)
      ;; Insert "X" at start vs end → snapshots should differ.
      (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 0)
      (limn:call "buffer/insert" :|buffer-id| buf :|text| "X")
      (sleep 0.15)
      (let ((at-start (snap)))
        (set-text buf "AAAAAA")
        (sleep 0.15)
        (limn:call "buffer/cursor-set" :|buffer-id| buf :|offset| 6)
        (limn:call "buffer/insert" :|buffer-id| buf :|text| "X")
        (sleep 0.15)
        (let ((at-end (snap)))
          (check "inserting at offset 0 vs offset 6 produces different visuals"
                 (snaps-differ-p at-start at-end)))))

    (format t "~%── C4b: rapid inserts stay in sync ──~%")
    (let* ((buf (open-text-buffer)))
      (set-text buf "")
      (dotimes (i 10)
        (limn:call "buffer/insert" :|buffer-id| buf :|text| "X"))
      (sleep 0.3)
      (let* ((tr (limn:call "buffer/text" :|buffer-id| buf))
             (got (getf (limn/bridge:response-data tr) :|text|)))
        (check "10 rapid wire inserts: text is 'XXXXXXXXXX'"
               (equal got "XXXXXXXXXX")
               (format nil "got ~s" got))
        ;; And snapshot reflects something present (text widget no longer empty)
        (let ((s0 (snap)))
          (set-text buf "")
          (sleep 0.15)
          (let ((s1 (snap)))
            (check "10 inserts produces a visibly different snapshot than empty"
                   (snaps-differ-p s0 s1))))))

;;; ── C5. widget 切換 ───────────────────────────────────────────────

    (format t "~%── C5: PDF→text raises luminance (text widget visible) ──~%")
    (limn:call "bridge/engine-load" :|win-id| "w1" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf"))
    (sleep 0.4)
    (let* ((pdf-grab (limn:call "test/grab-window" :|win-id| "w1"))
           (pdf-d    (limn/bridge:response-data pdf-grab))
           (pdf-lum  (getf pdf-d :|avg-luminance|)))
      ;; Open text engine on same window.
      (let* ((buf (open-text-buffer)))
        (set-text buf "switched to text")
        (sleep 0.3)
        (let* ((s (snap))
               (text-lum (getf s :lum)))
          (check "text widget luminance > PDF (blank/dark) luminance"
                 (and (numberp pdf-lum) (numberp text-lum)
                      (> text-lum pdf-lum))
                 (format nil "pdf.lum=~a, text.lum=~a" pdf-lum text-lum)))))

;;; ── C6. 大檔案 ────────────────────────────────────────────────────

    (format t "~%── C6: loading a 10KB file renders without hang ──~%")
    (let* ((tmp (format nil "/tmp/limn-v022d-big-~a.txt" (sb-posix:getpid)))
           (big (with-output-to-string (s)
                  (dotimes (i 800) (format s "line ~a abcdefghi~%" i)))))
      (with-open-file (s tmp :direction :output :if-exists :supersede
                              :external-format :utf-8)
        (write-string big s))
      (let* ((buf (open-text-buffer))
             (load-r (limn:call "buffer/load-file"
                                 :|buffer-id| buf :|path| tmp)))
        (declare (ignorable buf))
        (check "buffer/load-file on 10KB returns ok"
               (eq (getf load-r :|ok|) t))
        (sleep 0.3)
        (let ((s (snap)))
          (check "snapshot still returns ok after large load"
                 (getf s :ok))
          (check "variance non-trivial after large load"
                 (> (getf s :var) 100)
                 (format nil "var=~a" (getf s :var))))))

;;; ── final verdict ──────────────────────────────────────────────────

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — v0.22 C text-display driver green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-v022d")
        (rename-file "/tmp/.limn/init.lisp.stash-v022d" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
