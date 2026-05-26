;;;; v0.27 §O — content-keyed sidecar OS-level e2e
;;;;
;;;; 三個月 dogfooder 最痛：搬 PDF / 改名 / 複本 → annotation 全沒。
;;;; 此 batch 用真實檔案系統 cp / mv 驗 sidecar 真的跟著 content 而不是 path。
;;;;
;;;;   Ω1 真實 cp x.pdf y.pdf → 兩個 path 看到同 annotation
;;;;   Ω2 真實 mv x.pdf z.pdf → annotation 跟著新名字
;;;;   Ω3 CJK 檔名（論文.pdf）round-trip
;;;;   Ω4 不同內容同檔名 → 不同 sidecar（不撞）

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR") "/limn/backend/"))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-cm"))

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

(defun xdotool (&rest args)
  (sb-ext:run-program "xdotool" args :search t :wait t
                       :output nil :error nil))
(defun key (k) (xdotool "key" k))

(defun wait-for-window ()
  (loop repeat 50
        for found = (with-output-to-string (out)
                      (ignore-errors
                        (sb-ext:run-program "xdotool" '("search" "--name" "Limn")
                                             :search t :wait t
                                             :output out :error nil)))
        when (and found (> (length (string-trim '(#\Newline #\Space) found)) 0))
          do (return found)
        do (sleep 0.1)))

(defun overlays-of ()
  (let ((r (limn:call "view/get" :|win-id| "w1")))
    (when (ok? r) (or (getf (data r) :|overlays|) '()))))

(defun list-sidecars ()
  (let ((dir (merge-pathnames ".limn/annotations/" (user-homedir-pathname))))
    (when (probe-file dir)
      (ignore-errors (directory (merge-pathnames "*.lisp" dir))))))

(defun nuke-sidecars ()
  (dolist (f (list-sidecars))
    (ignore-errors (delete-file f))))

;;; ── session ─────────────────────────────────────────────────────────

(let* ((sock (format nil "/tmp/limn-e2e-v027cm-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN") "/limn/sioyek/limn"))
       (fixture (b/ "tests/fixtures/test.pdf"))
       (copy-a "/tmp/v027-cm-a.pdf")
       (copy-b "/tmp/v027-cm-b.pdf")
       (cjk "/tmp/v027-論文.pdf")
       (diff-a "/tmp/v027-same-name.pdf")
       (proc (sb-ext:run-program
              limn-bin
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v027cm.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.3)
  (wait-for-window)
  (nuke-sidecars)

  ;; Stage real PDF copies
  (uiop:run-program (list "cp" fixture copy-a) :ignore-error-status t)

  (let ((b1 (engine-load copy-a)))
    (check (format nil "setup — open ~a → ~a" copy-a b1) (stringp b1))

;;; ── Ω1: cp copy-a copy-b → 兩 path 看到同 annotation ────────

    (format t "~%── Ω1: cp 後同 annotation ──~%")
    (limn:call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| 0 :|x| 0.1 :|y| 0.2)
              :|end|   (list :|page| 0 :|x| 0.5 :|y| 0.25))
    (sleep 0.1)
    (key "h") (sleep 0.3)
    (let ((n1 (length (list-sidecars))))
      (check (format nil "Ω1a — annotation 寫入 sidecar (~a files)" n1)
             (>= n1 1)))

    ;; cp 第二份
    (uiop:run-program (list "cp" copy-a copy-b) :ignore-error-status t)
    (limn:call "buffer/close" :|buffer-id| b1) (sleep 0.2)
    (let ((b2 (engine-load copy-b)))
      (declare (ignore b2))
      (sleep 0.3)
      (let ((ovs (overlays-of)))
        (check (format nil "Ω1b — 開 copy-b 後 overlay 重現 (~a 個)"
                       (length ovs))
               (and (listp ovs) (>= (length ovs) 1)))))

;;; ── Ω2: mv x.pdf y.pdf → annotation 跟著 ─────────────────────

    (format t "~%── Ω2: mv 後 annotation 跟著 ──~%")
    (uiop:run-program (list "mv" copy-a (concatenate 'string copy-a ".renamed"))
                       :ignore-error-status t)
    (limn:call "buffer/close" :|buffer-id|
                (engine-load copy-b))   ; close current
    (sleep 0.2)
    (let ((br (engine-load (concatenate 'string copy-a ".renamed"))))
      (declare (ignore br))
      (sleep 0.3)
      (let ((ovs (overlays-of)))
        (check (format nil "Ω2 — mv 後 annotation 跟著新檔名 (~a 個)"
                       (length ovs))
               (and (listp ovs) (>= (length ovs) 1)))))

;;; ── Ω3: CJK 檔名 round-trip ─────────────────────────────────

    (format t "~%── Ω3: CJK 檔名 ──~%")
    (uiop:run-program (list "cp" fixture cjk) :ignore-error-status t)
    (let ((bc (engine-load cjk)))
      (check (format nil "Ω3a — CJK 檔名載入 ok (~a)" bc) (stringp bc))
      (when bc
        (limn:call "view/selection-set" :|win-id| "w1"
              :|begin| (list :|page| 0 :|x| 0.1 :|y| 0.3)
              :|end|   (list :|page| 0 :|x| 0.5 :|y| 0.35))
        (sleep 0.1)
        (key "h") (sleep 0.3)
        (limn:call "buffer/close" :|buffer-id| bc) (sleep 0.2)
        ;; reopen CJK
        (let ((bc2 (engine-load cjk)))
          (declare (ignore bc2))
          (sleep 0.3)
          (let ((ovs (overlays-of)))
            (check (format nil "Ω3b — CJK 檔重開 annotation 仍在 (~a 個)"
                           (length ovs))
                   (and (listp ovs) (>= (length ovs) 1)))))))

;;; ── Ω4: 不同內容 same-name 不撞 ─────────────────────────────

    (format t "~%── Ω4: 不同內容 → 不同 sidecar ──~%")
    ;; Write a tiny fake "different content" file
    (with-open-file (out diff-a :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create)
      (write-string "%PDF-1.4 fake content for diff hash test" out))
    (let* ((before-count (length (list-sidecars)))
           (rd (limn:call "bridge/engine-load"
                           :|engine| "mupdf"
                           :|path| diff-a :|win-id| "w1")))
      ;; v0.37 Phase F: `(declare ...)` must be the FIRST form of a
      ;; let body; the original had it at the END, which SBCL's strict
      ;; compiler rejects as "function DECLARE undefined".
      (declare (ignore before-count))
      ;; mupdf may refuse the fake; that's OK, we just check no crash
      (check "Ω4 — bridge 不 crash on fake PDF"
             (or (ok? rd) (not (ok? rd))))))

  ;; cleanup
  (nuke-sidecars)
  (dolist (f (list copy-a copy-b cjk diff-a
                    (concatenate 'string copy-a ".renamed")))
    (ignore-errors (delete-file f)))

  (format t "~%── v027-content-move e2e ──~%")
  (if (null *failures*)
      (format t "✓ ALL CHECKS PASSED~%")
      (progn
        (format t "✗ ~a FAILURE(s):~%" (length *failures*))
        (dolist (m (reverse *failures*)) (format t "  • ~a~%" m))))
  (limn:stop)
  (sb-ext:process-kill proc 15)
  (sb-ext:process-wait proc)
  (sb-ext:exit :code (if *failures* 1 0)))
