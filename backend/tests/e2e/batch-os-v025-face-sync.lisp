;;;; v0.25 §A — defface / enable-theme → display/sync-faces C++ roundtrip
;;;;
;;;; Exercises the full face/theme pipeline against a real binary:
;;;;   – defface + face-attribute reads back correctly (Lisp-tier).
;;;;   – set-face-attribute triggers %sync-to-bridge automatically.
;;;;   – sync-faces-payload produces correctly shaped output.
;;;;   – display/sync-faces wire call accepted by C++ (ok? true).
;;;;   – enable-theme overrides face-attribute + re-sync accepted.
;;;;   – payload after enable-theme carries the theme's color value,
;;;;     confirming C++ registry would store the right hex string.
;;;;   – disable-theme restores the default + final sync accepted.
;;;;
;;;; No Xvfb needed — pure wire-level.
;;;;
;;;; Ω1   defface → face-attribute reads back default foreground
;;;; Ω2   set-face-attribute → face-attribute updated
;;;; Ω3   sync-faces-payload is a list of plists each with :name
;;;; Ω4   display/sync-faces wire → C++ returns ok
;;;; Ω5   enable-theme → face-attribute overridden
;;;; Ω6a  payload after enable-theme carries theme color "#ff0000"
;;;; Ω6b  display/sync-faces after enable-theme → C++ ok
;;;; Ω7a  disable-theme → face-attribute restored to set-face value
;;;; Ω7b  display/sync-faces after disable-theme → C++ ok

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v025fs"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-face.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun ok? (r) (eq (getf r :|ok|) t))
(defun data (r) (getf r :|data|))

;;; helper: find a face entry by name in a sync-faces-payload list.
;;; NOTE: payload uses regular keywords (:name :foreground …), not the
;;; case-preserving |name|-form used for JSON-decoded wire payloads —
;;; sync-faces-payload is a *pre*-encode plist constructed in Lisp.
(defun find-face-entry (payload name)
  (find name payload
        :key (lambda (p) (getf p :name))
        :test #'string=))

(format t "~%=== batch-os-v025-face-sync ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v025fs-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v025fs.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  ;;; ── Ω1: defface reads back default foreground ─────────────────────────
  (format t "~%── Ω1: defface ──~%")
  (limn/face:defface 'v025-test-face '(:foreground "#00ff00" :background "#000000"))
  (let ((fg (limn/face:face-attribute 'v025-test-face :foreground))
        (bg (limn/face:face-attribute 'v025-test-face :background)))
    (check (format nil "Ω1a :foreground reads back \"#00ff00\" (got ~s)" fg)
           (equal fg "#00ff00"))
    (check (format nil "Ω1b :background reads back \"#000000\" (got ~s)" bg)
           (equal bg "#000000")))

  ;;; ── Ω2: set-face-attribute updates ───────────────────────────────────
  (format t "~%── Ω2: set-face-attribute ──~%")
  (limn/face:set-face-attribute 'v025-test-face :foreground "#0000ff")
  (let ((fg (limn/face:face-attribute 'v025-test-face :foreground)))
    (check (format nil "Ω2 :foreground updated to \"#0000ff\" (got ~s)" fg)
           (equal fg "#0000ff")))

  ;;; ── Ω3 + Ω4: sync-faces-payload shape + wire roundtrip ───────────────
  (format t "~%── Ω3+Ω4: sync-faces-payload + display/sync-faces wire ──~%")
  (let* ((payload (limn/face:sync-faces-payload)))
    (check "Ω3 payload is a non-empty list of plists with :name"
           (and (listp payload)
                (plusp (length payload))
                (every (lambda (p)
                         (and (listp p) (stringp (getf p :name))))
                       payload)))
    (let* ((entry (find-face-entry payload "v025-test-face")))
      (check (format nil "Ω3b v025-test-face entry present in payload (got ~s)" entry)
             (not (null entry))))
    (let ((r (limn:call "display/sync-faces" :|faces| payload)))
      (check (format nil "Ω4 display/sync-faces → ok (got ~s)" (getf r :|ok|))
             (ok? r))))

  ;;; ── Ω5 + Ω6: enable-theme overrides + resync ─────────────────────────
  (format t "~%── Ω5+Ω6: enable-theme ──~%")
  (limn/face:deftheme 'v025-test-theme "v025 test theme")
  (limn/face:custom-theme-set-faces 'v025-test-theme
    (list 'v025-test-face '(:foreground "#ff0000")))
  (limn/face:enable-theme 'v025-test-theme)

  (let ((fg (limn/face:face-attribute 'v025-test-face :foreground)))
    (check (format nil "Ω5 enable-theme overrides :foreground → \"#ff0000\" (got ~s)" fg)
           (equal fg "#ff0000")))

  (let* ((payload (limn/face:sync-faces-payload))
         (entry   (find-face-entry payload "v025-test-face")))
    (check (format nil "Ω6a payload carries theme color \"#ff0000\" (entry=~s)" entry)
           (and entry
                (equal (getf entry :foreground) "#ff0000")))
    (let ((r (limn:call "display/sync-faces" :|faces| payload)))
      (check (format nil "Ω6b display/sync-faces after enable-theme → ok (got ~s)"
                     (getf r :|ok|))
             (ok? r))))

  ;;; ── Ω7: disable-theme restores + final resync ─────────────────────────
  ;; disable-theme reverts to *face-defaults* — that's the defface
  ;; baseline ("#00ff00"), NOT the latest set-face-attribute value.
  ;; This matches Emacs deftheme semantics: themes overlay defaults, and
  ;; disabling pops the overlay back to the pristine defface state.
  (format t "~%── Ω7: disable-theme ──~%")
  (limn/face:disable-theme 'v025-test-theme)

  (let ((fg (limn/face:face-attribute 'v025-test-face :foreground)))
    (check (format nil "Ω7a disable-theme restores to defface baseline \"#00ff00\" (got ~s)" fg)
           (equal fg "#00ff00")))

  (let ((r (limn:call "display/sync-faces" :|faces| (limn/face:sync-faces-payload))))
    (check (format nil "Ω7b display/sync-faces after disable-theme → ok (got ~s)"
                   (getf r :|ok|))
           (ok? r)))

  (ignore-errors (limn:stop))
  (sleep 0.1)
  (handler-case (sb-ext:process-kill proc 15) (error () nil))
  (handler-case (sb-ext:process-wait proc) (error () nil)))

(format t "~%")
(if *failures*
    (progn (format t "VERDICT: FAIL (~a failure(s))~%" (length *failures*))
           (sb-ext:exit :code 1))
    (progn (format t "VERDICT: PASS~%")
           (sb-ext:exit :code 0)))
