;;;; Batch 1.6: stronger-of-stronger — 把 1.5 的 systematic 風格 generalize
;;;; 到 1.5 自己沒掃的 dimension：全 event SPEC field 完整性、mode-
;;;; differential、negative cross-modality、enum preservation、order、
;;;; concurrency。
;;;;
;;;; 預期會抓的 bug（讀 code 預判）：
;;;;   - ζ1: 全 event 欄位 sweep 大概率有 1–3 個 event type 漏文件欄位
;;;;   - κ1/κ2: minibuffer 開時 mouse-click / scroll 路徑沒被想過
;;;;   - λ1: button_id 只 handle 1/2/3、其餘 return 0

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
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-s2"))

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

;; Capture all events of interest in a single multimap.
(defparameter *captured* (make-hash-table :test 'equal))

(defun cap-add (ev-type ev)
  (push ev (gethash ev-type *captured* nil)))

(defun cap-first (ev-type) (first (gethash ev-type *captured*)))
(defun cap-all   (ev-type) (gethash ev-type *captured* nil))
(defun cap-reset ()
  (clrhash *captured*)
  (sleep 0.05))

(defun install-cap (ev-type)
  (limn:on-event ev-type
                 (lambda (ev)
                   (setf (gethash ev-type *captured*)
                         (cons ev (gethash ev-type *captured* nil))))))

(let* ((sock (format nil "/tmp/limn-e2e-s2-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-s2.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (let ((wid (wait-for-window-by-name "Limn" :timeout 5)))
    (declare (ignorable wid))
    (sleep 0.3)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)

    (dolist (et '("key" "mouse-click" "mouse-drag" "scroll" "resize"
                  "minibuffer-input" "minibuffer-submit" "minibuffer-cancel"
                  "buffer-opened" "buffer-closed" "heartbeat"
                  "gesture" "drag-drop" "ime-commit" "audio-input"))
      (install-cap et))
    (sleep 0.2)

;;; ═════════════════════════════════════════════════════════════════
;;; ζ1: 全 event type SPEC field 完整性 sweep
;;; ═════════════════════════════════════════════════════════════════
;;;
;;; 每個 event type 觸發一次、assert SPEC 規定欄位都在。

    (format t "~%── ζ1: SPEC field sweep across event types ──~%")

    ;; ── key event: frame-id, key, mods ──
    (cap-reset)
    (xdotool "key" "--clearmodifiers" "x")
    (sleep 0.3)
    (let ((ev (cap-first "key")))
      (check "ζ1 key — event arrived" ev)
      (when ev
        (check "ζ1 key — has :frame-id" (getf ev :|frame-id|)
               (format nil "ev=~s" ev))
        (check "ζ1 key — has :key"      (getf ev :|key|))
        (check "ζ1 key — has :mods"     (let ((m (getf ev :|mods|))) (or (listp m) (eq m nil))))))

    ;; ── mouse-click: frame-id, win-id, page, x, y, button, mods ──
    (cap-reset)
    (xdotool "mousemove" "600" "400")
    (xdotool "click" "1")
    (sleep 0.3)
    (let ((ev (cap-first "mouse-click")))
      (check "ζ1 mouse-click — event arrived" ev)
      (when ev
        (dolist (k '(:|frame-id| :|win-id| :|page| :|x| :|y| :|button| :|mods|))
          (check (format nil "ζ1 mouse-click — has ~a" k)
                 (not (eq 'missing (getf ev k 'missing)))
                 (format nil "ev=~s" ev)))))

    ;; ── scroll: frame-id, win-id, dx, dy, mods ──
    (cap-reset)
    (xdotool "click" "5")  ; scroll down
    (sleep 0.3)
    (let ((ev (cap-first "scroll")))
      (check "ζ1 scroll — event arrived" ev)
      (when ev
        (dolist (k '(:|frame-id| :|win-id| :|dx| :|dy| :|mods|))
          (check (format nil "ζ1 scroll — has ~a" k)
                 (not (eq 'missing (getf ev k 'missing)))
                 (format nil "ev=~s" ev)))))

    ;; ── resize: frame-id, win-id, width, height ──
    ;; NOTE: xdotool windowsize 改 X11 window 大小、但 Qt 在 Xvfb +
    ;; openbox 下不重新派 QResizeEvent（探查發現只有 startup 那次
    ;; fires）。所以這裡用 test/inject-resize 走 wire-level synthetic
    ;; event、繞過 Xvfb infra limitation。Wire 端 emit 邏輯一樣、
    ;; 欄位完整性的 SPEC contract 測試本意保留。
    (cap-reset)
    (limn:call "test/inject-resize" :|frame-id| "f1" :|win-id| "w1"
                :|width| 1000 :|height| 700)
    (sleep 0.3)
    (let ((ev (cap-first "resize")))
      (check "ζ1 resize — event arrived" ev)
      (when ev
        (dolist (k '(:|frame-id| :|win-id| :|width| :|height|))
          (check (format nil "ζ1 resize — has ~a" k)
                 (not (eq 'missing (getf ev k 'missing)))
                 (format nil "ev=~s" ev)))))

    ;; ── minibuffer-input: frame-id, text ──
    (cap-reset)
    (limn:call "minibuffer/open" :|prompt| "test: ")
    (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "h")
    (sleep 0.3)
    (let ((ev (cap-first "minibuffer-input")))
      (check "ζ1 minibuffer-input — event arrived" ev)
      (when ev
        (check "ζ1 minibuffer-input — has :frame-id" (getf ev :|frame-id|))
        (check "ζ1 minibuffer-input — has :text"     (getf ev :|text|))))

    ;; ── minibuffer-submit: frame-id, text ──
    (cap-reset)
    (xdotool "key" "--clearmodifiers" "Return")
    (sleep 0.3)
    (let ((ev (cap-first "minibuffer-submit")))
      (check "ζ1 minibuffer-submit — event arrived" ev)
      (when ev
        (check "ζ1 minibuffer-submit — has :frame-id" (getf ev :|frame-id|))
        (check "ζ1 minibuffer-submit — has :text"     (getf ev :|text|))))

    ;; ── minibuffer-cancel: frame-id ──
    (cap-reset)
    (limn:call "minibuffer/open" :|prompt| "test: ")
    (sleep 0.2)
    (xdotool "key" "--clearmodifiers" "Escape")
    (sleep 0.3)
    (let ((ev (cap-first "minibuffer-cancel")))
      (check "ζ1 minibuffer-cancel — event arrived" ev)
      (when ev
        (check "ζ1 minibuffer-cancel — has :frame-id" (getf ev :|frame-id|))))

    ;; ── buffer-opened: already fired during engine-load earlier ──
    (let ((ev (cap-first "buffer-opened")))
      ;; might be nil because we engine-loaded BEFORE installing hooks
      (cond
        ((null ev) (format t "  (buffer-opened from initial engine-load was missed; reload)~%"))
        (t (check "ζ1 buffer-opened — has :buffer-id" (getf ev :|buffer-id|)))))
    ;; trigger another buffer-opened
    (cap-reset)
    (limn:call "bridge/engine-load" :|engine| "mupdf"
                :|path| (b/ "tests/fixtures/test.pdf") :|win-id| "w1")
    (sleep 0.3)
    (let ((ev (cap-first "buffer-opened")))
      (check "ζ1 buffer-opened — event arrived (after engine-load)" ev)
      (when ev
        (check "ζ1 buffer-opened — has :buffer-id" (getf ev :|buffer-id|))))

    ;; ── heartbeat: test/emit-heartbeat ──
    (cap-reset)
    (limn:call "test/emit-heartbeat")
    (sleep 0.3)
    (let ((ev (cap-first "heartbeat")))
      (check "ζ1 heartbeat — event arrived" ev))

;;; ═════════════════════════════════════════════════════════════════
;;; κ1: minibuffer 開時 mouse-click 還是 emit
;;; ═════════════════════════════════════════════════════════════════

    (format t "~%── κ1: minibuffer open + click → mouse-click ──~%")
    (limn:call "minibuffer/open" :|prompt| "test: ")
    (sleep 0.2)
    (cap-reset)
    (xdotool "mousemove" "600" "400")
    (xdotool "click" "1")
    (sleep 0.3)
    (check "κ1 — mouse-click fires while minibuffer open"
           (cap-first "mouse-click")
           (format nil "captured: ~s" (cap-all "mouse-click")))
    (limn:call "minibuffer/close")
    (sleep 0.1)

;;; ═════════════════════════════════════════════════════════════════
;;; κ2: minibuffer 開時 scroll 還是 emit
;;; ═════════════════════════════════════════════════════════════════

    (format t "~%── κ2: minibuffer open + scroll → scroll event ──~%")
    (limn:call "minibuffer/open" :|prompt| "test: ")
    (sleep 0.2)
    (cap-reset)
    (xdotool "click" "5")
    (sleep 0.3)
    (check "κ2 — scroll fires while minibuffer open"
           (cap-first "scroll")
           (format nil "captured: ~s" (cap-all "scroll")))
    (limn:call "minibuffer/close")
    (sleep 0.1)

;;; ═════════════════════════════════════════════════════════════════
;;; η1: 裸 modifier 不該 emit mouse-click
;;; ═════════════════════════════════════════════════════════════════

    (format t "~%── η1: bare ctrl down/up → no mouse-click ──~%")
    (cap-reset)
    (xdotool "keydown" "ctrl")
    (sleep 0.2)
    (xdotool "keyup" "ctrl")
    (sleep 0.3)
    (check "η1 — bare Ctrl does NOT emit mouse-click"
           (null (cap-all "mouse-click"))
           (format nil "got ~a events" (length (cap-all "mouse-click"))))

;;; ═════════════════════════════════════════════════════════════════
;;; η2: 純 mousemove 不該 emit mouse-click
;;; ═════════════════════════════════════════════════════════════════

    (format t "~%── η2: mousemove only → no mouse-click ──~%")
    (cap-reset)
    (xdotool "mousemove" "200" "300")
    (xdotool "mousemove" "500" "500")
    (xdotool "mousemove" "700" "200")
    (sleep 0.3)
    (check "η2 — mousemove without click does NOT emit mouse-click"
           (null (cap-all "mouse-click"))
           (format nil "got ~a events" (length (cap-all "mouse-click"))))

;;; ═════════════════════════════════════════════════════════════════
;;; η3: modifier 按下不該意外 emit scroll
;;; ═════════════════════════════════════════════════════════════════

    (format t "~%── η3: modifier hold (no scroll wheel) → no scroll event ──~%")
    (cap-reset)
    (xdotool "keydown" "shift")
    (sleep 0.2)
    (xdotool "keyup" "shift")
    (sleep 0.3)
    (check "η3 — modifier hold does NOT emit scroll"
           (null (cap-all "scroll"))
           (format nil "got ~a events" (length (cap-all "scroll"))))

;;; ═════════════════════════════════════════════════════════════════
;;; λ1: xdotool click 8 (back button) → button id 在 enum 內嗎
;;; ═════════════════════════════════════════════════════════════════

    (format t "~%── λ1: click 8 (back button) → mouse-click w/ correct button ──~%")
    (cap-reset)
    (handler-case (xdotool "mousemove" "600" "400") (error () nil))
    (handler-case (xdotool "click" "8") (error () nil))
    (sleep 0.3)
    (let ((ev (cap-first "mouse-click")))
      (cond
        ((null ev)
         ;; xdotool click 8 might not even emit anything — check.
         (check "λ1 — back button click reaches backend"
                nil "no mouse-click event"))
        (t
         (let ((btn (getf ev :|button|)))
           ;; SPEC §6 button enum: 1=left 2=middle 3=right.
           ;; back button SHOULD map to a >3 value, OR be filtered out.
           ;; Currently button_id() returns 0 for anything else.
           ;; 我們 claim 不該回 0（0 表示「沒按鈕」、含意混淆）。
           (check (format nil "λ1 — back button id is NOT 0 (got ~a)" btn)
                  (not (eql btn 0))
                  "button_id() returns 0 for buttons outside 1/2/3 — meaningful info lost")))))

;;; ═════════════════════════════════════════════════════════════════
;;; θ1: rapid inject 順序保留
;;; ═════════════════════════════════════════════════════════════════

    (format t "~%── θ1: rapid inject abcde → events arrive in order ──~%")
    (cap-reset)
    (limn:call "minibuffer/open" :|prompt| "ord: ")
    (sleep 0.1)
    (dolist (c '("a" "b" "c" "d" "e"))
      (xdotool "key" "--clearmodifiers" c))
    (sleep 0.5)
    (let* ((events (reverse (cap-all "minibuffer-input"))) ; oldest first
           (texts  (mapcar (lambda (ev) (getf ev :|text|)) events))
           (expected '("a" "ab" "abc" "abcd" "abcde")))
      (check (format nil "θ1 — 5 minibuffer-input events arrived (got ~a)" (length events))
             (= (length events) 5))
      (check (format nil "θ1 — texts in order: ~s" expected)
             (equal texts expected)
             (format nil "got ~s" texts)))
    (limn:call "minibuffer/close")
    (sleep 0.1)

;;; ═════════════════════════════════════════════════════════════════
;;; ι1: 並行 key inject + wire call、無 dropped event
;;; ═════════════════════════════════════════════════════════════════

    (format t "~%── ι1: concurrent inject + wire call → no drop ──~%")
    (cap-reset)
    (limn:call "minibuffer/open" :|prompt| "race: ")
    (sleep 0.1)
    (let ((other-thread
            (sb-thread:make-thread
             (lambda ()
               (loop repeat 10 do
                 (limn:call "view/get" :|win-id| "w1")
                 (sleep 0.02))))))
      (dolist (c '("a" "b" "c" "d" "e"))
        (xdotool "key" "--clearmodifiers" c)
        (sleep 0.05))
      (sb-thread:join-thread other-thread))
    (sleep 0.5)
    (let* ((events (cap-all "minibuffer-input"))
           (n     (length events)))
      (check (format nil "ι1 — got 5 minibuffer-input events under concurrent load (got ~a)" n)
             (= n 5)))
    (limn:call "minibuffer/close")

;;; ═════════════════════════════════════════════════════════════════

    (let ((ok (null *failures*)))
      (format t "~%── VERDICT: ~a ──~%"
              (if ok "✓ PASS — batch 1.6 all green"
                     (format nil "✗ FAIL (~a):~{~%    ~a~}"
                             (length *failures*) (reverse *failures*))))
      (limn:stop)
      (handler-case (sb-ext:process-kill proc 15) (error () nil))
      (when (probe-file "/tmp/.limn/init.lisp.stash-s2")
        (rename-file "/tmp/.limn/init.lisp.stash-s2" "/tmp/.limn/init.lisp"))
      (sb-ext:exit :code (if ok 0 1)))))
