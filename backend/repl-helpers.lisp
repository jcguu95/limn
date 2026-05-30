;;;; repl-helpers — one-letter shortcuts for poking at limn from SBCL.
;;;;
;;;; All symbols land in :CL-USER so you can just type (o ...) at the
;;;; prompt without any package prefix. The intent is "feel out the API,
;;;; surface friction"; nothing here is structural — if a shortcut isn't
;;;; pulling its weight, delete it.

(in-package #:cl-user)

(defvar *limn-events* '()
  "Most-recent events, newest first. Capped at 200.")

(defun %record-event (ev)
  (push ev *limn-events*)
  (when (> (length *limn-events*) 200)
    (setf *limn-events* (subseq *limn-events* 0 200))))

;;; ── opening / closing buffers ──────────────────────────────────────────

(defun o (path &key (engine "mupdf") (win-id "w1"))
  "Open a buffer in WIN-ID (default w1). Returns the buffer-id, or NIL on
   failure (logs error). Resolves PATH against cwd so relative paths work."
  (let* ((abs  (namestring (truename (merge-pathnames path))))
         (r    (limn:open-buffer abs :engine engine :win-id win-id)))
    (cond
      ((not (limn/bridge:response-ok? r))
       (format t "  ✗ open failed: ~a~%" (limn/bridge:response-error r))
       nil)
      (t
       (let* ((data (limn/bridge:response-data r))
              (id   (getf data :|buffer-id|)))
         (format t "  buffer-id: ~a~%" id)
         (format t "  supports : ~a~%" (getf data :|supports|))
         id)))))

(defun close-buf (buffer-id)
  "Close a buffer."
  (limn:close-buffer buffer-id))

;;; ── view ───────────────────────────────────────────────────────────────

(defun v (win-id &rest fields)
  "view/set on WIN-ID. Pass plain :page / :zoom etc — they encode correctly.
   E.g.  (v \"w1\" :page 3 :zoom 1.5)"
  (let ((r (apply #'limn:view-set win-id fields)))
    (format t "  ok: ~a   data: ~a~%"
            (limn/bridge:response-ok? r)
            (limn/bridge:response-data r))
    r))

(defun vg (win-id)
  "view/get on WIN-ID."
  (let ((r (limn:view-get win-id)))
    (format t "  ~s~%" (limn/bridge:response-data r))
    r))

;;; ── windows (split / focus / close) ─────────────────────────────────────
;;; Phase 3b dogfood shortcuts. bridge/win-* are frontend-handled commands
;;; (the backend sends them); from the REPL we drive them directly via
;;; limn:call. A split shows a REAL second pane with its own DocumentView.

(defun sp (&optional (dir "h") (win-id "w1"))
  "Split WIN-ID (default w1). DIR is \"h\" (side-by-side) or \"v\" (top/bottom).
   Returns the NEW window-id (win-b), or NIL on failure. The new pane shows
   the same buffer + view-state as the source, but renders independently."
  (let ((r (limn:call "bridge/win-split" :|win-id| win-id :|dir| dir)))
    (cond
      ((not (limn/bridge:response-ok? r))
       (format t "  ✗ split failed: ~a~%" (limn/bridge:response-error r))
       nil)
      (t (let* ((data (limn/bridge:response-data r))
                (a    (getf data :|win-a|))
                (b    (getf data :|win-b|)))
           ;; Register the new pane's active buffer so key events stamped
           ;; with its win-id resolve the source buffer's mode-buffer
           ;; (pdf-mode keymap).  A split reuses an already-open buffer, so
           ;; NO buffer-opened event fires — without this j/k/etc. are
           ;; unbound in the new pane.  See %register-window-buffer.
           (let ((src-buf (limn/pdf-mode::%window-active-buffer a)))
             (when (and b src-buf)
               (limn/pdf-mode::%register-window-buffer b src-buf)))
           (format t "  split ~a → ~a + ~a~%" win-id a b)
           b)))))

(defun wf (win-id)
  "Focus WIN-ID — moves the focus border AND repoints which pane keyboard
   navigation (j/k/etc) drives. Returns the response."
  (let ((r (limn:call "bridge/win-focus" :|win-id| win-id)))
    (format t "  ok: ~a~%" (limn/bridge:response-ok? r))
    r))

(defun wc (win-id)
  "Close WIN-ID — destroys its pane. Focus auto-transfers to a surviving
   tiled window. Refuses to close the last tiled window."
  (let ((r (limn:call "bridge/win-close" :|win-id| win-id)))
    (if (limn/bridge:response-ok? r)
        (format t "  closed ~a~%" win-id)
        (format t "  ✗ close failed: ~a~%" (limn/bridge:response-error r)))
    r))

;;; ── events / pump ──────────────────────────────────────────────────────

(defun p ()
  "Drain pending socket lines, fire event hooks. Prints what arrived."
  (let* ((before (length *limn-events*))
         (n      (limn:pump))
         (delta  (- (length *limn-events*) before)))
    (format t "  pumped: ~a line~:p, ~a tapped event~:p~%" n delta)
    (when (plusp delta)
      (format t "  newest first:~%")
      (loop for ev in (subseq *limn-events* 0 (min delta 10))
            do (format t "    ~s~%" ev)))
    n))

(defun events (&optional (n 10))
  "Last N events (newest first)."
  (subseq *limn-events* 0 (min n (length *limn-events*))))

(defun clear-events ()
  (setf *limn-events* '()))

;;; ── keymap ─────────────────────────────────────────────────────────────

(defun k (spec fn)
  "Bind a key sequence (e.g. \"C-x C-f\" or \"j\") to FN.
   FN is called with the originating key event plist."
  (limn:bind spec fn)
  (format t "  bound: ~a~%" spec)
  spec)

(defun unk (spec)
  (limn:unbind spec)
  (format t "  unbound: ~a~%" spec))

;;; ── event taps (print stream for a given event type) ───────────────────

(defvar *taps* (make-hash-table :test 'equal))

(defun tap (event-type)
  "Start printing every event of EVENT-TYPE as it arrives (and record it
   into *limn-events*). EVENT-TYPE is a string like \"key\", \"buffer-opened\"."
  (when (gethash event-type *taps*)
    (format t "  already tapped: ~a~%" event-type)
    (return-from tap event-type))
  (let ((fn (lambda (ev)
              (%record-event ev)
              (format t "  [event ~a] ~s~%" event-type ev))))
    (setf (gethash event-type *taps*) fn)
    (limn:on-event event-type fn)
    (format t "  tapped: ~a~%" event-type))
  event-type)

(defun untap (event-type)
  (let ((fn (gethash event-type *taps*)))
    (when fn
      (limn:off-event event-type fn)
      (remhash event-type *taps*)
      (format t "  untapped: ~a~%" event-type))))

(defun tap-all ()
  "Tap a useful default set."
  (dolist (e '("key" "buffer-opened" "buffer-closed" "error"
               "mouse-click" "resize" "heartbeat"))
    (tap e)))

;;; ── direct commands / introspection ───────────────────────────────────

(defun caps ()
  (let ((r (limn:capabilities)))
    (format t "  ~s~%" (limn/bridge:response-data r))
    r))

(defun wins ()
  (let ((r (limn:win-list)))
    (format t "  ~s~%" (limn/bridge:response-data r))
    r))

(defun snap ()
  "test/snapshot — counts of buffers, overlays, etc."
  (let ((r (limn:call "test/snapshot")))
    (format t "  ~s~%" (limn/bridge:response-data r))
    r))

(defun tree ()
  "test/widget-tree — print Qt widget hierarchy."
  (let ((r (limn:call "test/widget-tree")))
    (labels ((walk (n depth)
               (format t "~a~a ~a~a~%"
                       (make-string (* depth 2) :initial-element #\Space)
                       (getf n :|class|)
                       (getf n :|geometry|)
                       (if (eq t (getf n :|focus|)) " *FOCUS*" ""))
               (dolist (kid (getf n :|children|)) (walk kid (1+ depth)))))
      (walk (getf (limn/bridge:response-data r) :|tree|) 0))
    r))

;;; ── grab a screenshot to disk ─────────────────────────────────────────

(defun base64-string-to-bytes (s)
  "Minimal base64 decoder — enough for PNG payloads from test/grab-window.
   Keeps the accumulator in fixnum range by masking after each extraction;
   without this, decoding a 100KB+ payload allocates absurd amounts of
   bignum garbage (we hit ~113 GB consed before this was fixed)."
  (declare (optimize (speed 3) (safety 1)))
  (let* ((len (length s))
         (out (make-array (* 3 (ceiling len 4))
                          :element-type '(unsigned-byte 8)
                          :fill-pointer 0))
         (val 0)
         (bits 0))
    (declare (type (unsigned-byte 16) val)
             (type (integer 0 16)     bits))
    (loop for c across s do
      (let ((d (cond ((char= c #\=) nil)
                     ((and (char>= c #\A) (char<= c #\Z)) (- (char-code c) (char-code #\A)))
                     ((and (char>= c #\a) (char<= c #\z)) (+ 26 (- (char-code c) (char-code #\a))))
                     ((and (char>= c #\0) (char<= c #\9)) (+ 52 (- (char-code c) (char-code #\0))))
                     ((char= c #\+) 62)
                     ((char= c #\/) 63))))
        (declare (type (or null (integer 0 63)) d))
        (when d
          (setf val  (logand (logior (ash val 6) d) #xFFFF))  ; mask to 16 bits
          (incf bits 6)
          (when (>= bits 8)
            (decf bits 8)
            ;; Extract the top byte; mask val down to the remaining bits
            ;; so it never grows past ~12 bits in practice.
            (vector-push (ldb (byte 8 bits) val) out)
            (setf val (logand val (1- (ash 1 bits))))))))
    out))

(defun grab (out-path)
  "Save a fresh test/grab-window PNG to OUT-PATH so you can open it."
  (let* ((r    (limn:call "test/grab-window"))
         (data (limn/bridge:response-data r))
         (b64  (getf data :|png|))
         (raw  (base64-string-to-bytes b64)))
    (with-open-file (s out-path :direction :output
                                :element-type '(unsigned-byte 8)
                                :if-exists :supersede)
      (write-sequence raw s))
    (format t "  saved ~a bytes → ~a   (~ax~a, avg-lum ~,1f)~%"
            (length raw) out-path
            (getf data :|width|) (getf data :|height|)
            (getf data :|avg-luminance|))
    out-path))

;;; ── helpers for digging into responses ────────────────────────────────

(defun jg (plist &rest keys)
  "Walk a JSON-decoded plist. Case-insensitive on the key (so :page
   matches both :page and :|page|)."
  (labels ((maybe (acc k)
             (when (listp acc)
               (or (getf acc k)
                   (getf acc (intern (string-downcase (string k)) :keyword))
                   (getf acc (intern (string-upcase   (string k)) :keyword))))))
    (reduce #'maybe keys :initial-value plist)))

;;; ── shutdown ───────────────────────────────────────────────────────────

(defun q ()
  "Quit: disconnect, kill limn subprocess."
  (handler-case (limn:stop) (error () nil))
  (when (and (boundp '*limn-process*) *limn-process*
             (sb-ext:process-alive-p *limn-process*))
    (format t "  killing limn pid ~a~%" (sb-ext:process-pid *limn-process*))
    (sb-ext:process-kill *limn-process* 15)
    (sb-ext:process-wait *limn-process*)
    (setf *limn-process* nil))
  (sb-ext:exit :code 0))

;;; ── banner ─────────────────────────────────────────────────────────────

(defun banner ()
  (format t "~%─────────────────────────────────────────────────────────────~%")
  (format t " limn REPL ready~%")
  (when (boundp '*limn-socket-path*)
    (format t "   socket: ~a~%" *limn-socket-path*))
  (when (and (boundp '*limn-process*) *limn-process*)
    (format t "   pid   : ~a~%" (sb-ext:process-pid *limn-process*)))
  (format t "~%")
  (format t "   (o \"path.pdf\")        open a buffer~%")
  (format t "   (v \"w1\" :page 3)      view/set~%")
  (format t "   (vg \"w1\")             view/get~%")
  (format t "   (sp \"h\") / (sp \"v\")   split window → real 2nd pane~%")
  (format t "   (wf \"w2\")             focus a window (moves border + kbd)~%")
  (format t "   (wc \"w2\")             close a window (destroys pane)~%")
  (format t "   (k \"j\" #'fn)          bind a key~%")
  (format t "   (tap \"key\") / (tap-all) / (untap \"key\")~%")
  (format t "   (p)                   pump events (drain socket)~%")
  (format t "   (events 10)           last 10 events~%")
  (format t "   (caps) (wins) (snap) (tree)   introspection~%")
  (format t "   (grab \"/tmp/g.png\")  save current Qt grab to disk~%")
  (format t "   (jg plist :key ...)   case-insensitive plist walk~%")
  (format t "   (q)                   quit (kill limn)~%")
  (format t "─────────────────────────────────────────────────────────────~%~%"))
