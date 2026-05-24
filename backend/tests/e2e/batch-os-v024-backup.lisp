;;;; v0.24 §G — backup OS-tier
;;;;
;;;; Filesystem-driven. backup-buffer copies the visited file to a "~"
;;;; (or numbered ".~N~") backup before the next save. The OS-tier value
;;;; is verifying real files appear/disappear on disk and the pruning
;;;; arithmetic is correct.
;;;;
;;;; Pruning math (read straight from %prune-numbered): given N existing
;;;; numbered backups foo.~1~ ... foo.~N~, keep the first
;;;; *kept-old-versions* and the last *kept-new-versions*; delete the
;;;; middle slice.  E.g. N=6, old=2, new=2 → delete slots 3 and 4,
;;;; leaving 1, 2, 5, 6.
;;;;
;;;; No Xvfb needed.
;;;;
;;;; Ω1   make-backup-file-name single-file mode → path~
;;;; Ω2   make-backup-file-name version-control t → next free .~N~ slot
;;;; Ω3   backup-buffer creates "path~" on disk with original content
;;;; Ω4   backed-up-p is t after backup-buffer
;;;; Ω5   second save without clear-backed-up is no-op
;;;; Ω6   *make-backup-files* nil → backup-buffer writes nothing
;;;; Ω7   *version-control* t: 3 saves → .~1~ .~2~ .~3~ all present
;;;; Ω8   pruning: 6 numbered backups, kept-old=2 kept-new=2 →
;;;;        slots 3 and 4 deleted, 1/2/5/6 remain
;;;; Ω9   *before-backup-hook* + *after-backup-hook* fire in order

(in-package :cl-user)
(require :sb-posix) (require :sb-bsd-sockets)

(defparameter *bdir*
  (or (sb-posix:getenv "LIMN_BACKEND_DIR")
      (namestring (merge-pathnames "../../"
                                    (make-pathname :defaults *load-truename*
                                                   :name nil :type nil)))))
(defun b/ (f) (concatenate 'string *bdir* f))

(when (probe-file "/tmp/.limn/init.lisp")
  (rename-file "/tmp/.limn/init.lisp" "/tmp/.limn/init.lisp.stash-v024bk"))

(dolist (f '("limn-hooks.lisp" "limn-log.lisp" "limn-error.lisp"
             "limn-buffer.lisp" "limn-bridge.lisp"
             "limn-keys.lisp" "limn-undo.lisp" "limn-search.lisp"
             "limn-client.lisp" "limn-dispatch.lisp"
             "limn-mode.lisp" "limn-cmd.lisp"
             "limn-runtime.lisp" "limn-introspect.lisp" "limn.lisp"
             "limn-backup.lisp"))
  (load (b/ f)))

(defparameter *failures* nil)
(defun check (msg ok &optional details)
  (format t "  ~a ~a~%" (if ok "✓" "✗") msg)
  (when (and (not ok) details) (format t "    ~a~%" details))
  (unless ok (push msg *failures*)))

(defun slurp (path)
  (with-open-file (s path :direction :input :if-does-not-exist :error)
    (let ((buf (make-string (file-length s))))
      (read-sequence buf s)
      buf)))

(defun write-file (path content)
  (with-open-file (s path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (write-string content s)))

(defun nuke (path)
  (ignore-errors (delete-file path)))

(format t "~%=== batch-os-v024-backup ===~%")

(let* ((sock     (format nil "/tmp/limn-e2e-v024bk-~a" (sb-posix:getpid)))
       (limn-bin (or (sb-posix:getenv "LIMN_BIN")
                     (probe-file "/limn/sioyek/limn")
                     (probe-file (b/ "../sioyek/limn.app/Contents/MacOS/limn"))
                     (probe-file (b/ "../sioyek/sioyek.app/Contents/MacOS/sioyek"))))
       (proc (sb-ext:run-program
              (namestring limn-bin)
              (list "--test-mode" "--socket" sock)
              :wait nil :search nil
              :output "/tmp/limn-os-v024bk.log"
              :if-output-exists :supersede :error :output)))
  (loop repeat 100 until (probe-file sock) do (sleep 0.05))
  (limn:start sock)
  (sleep 0.2)

  (let* ((path "/tmp/limn-v024-bk.txt")
         (tilde (concatenate 'string path "~"))
         (n1  (concatenate 'string path ".~1~"))
         (n2  (concatenate 'string path ".~2~"))
         (n3  (concatenate 'string path ".~3~"))
         (n4  (concatenate 'string path ".~4~"))
         (n5  (concatenate 'string path ".~5~"))
         (n6  (concatenate 'string path ".~6~")))

    ;; Cleanup any stale leftovers from previous runs.
    (dolist (p (list path tilde n1 n2 n3 n4 n5 n6)) (nuke p))

    ;; Wire *buffer-path-fn* to a constant map (we only need one buffer).
    (setf limn/backup:*buffer-path-fn*
          (lambda (bid) (when (equal bid "b-1") path)))

    ;;; ── Ω1: single-file backup name ──────────────────────────────────
    (format t "~%── Ω1: make-backup-file-name (single) ──~%")
    (let ((limn/backup:*version-control* nil))
      (let ((name (limn/backup:make-backup-file-name path)))
        (check (format nil "Ω1 name = path~~  (got ~s)" name)
               (equal name tilde))))

    ;;; ── Ω2: numbered backup name ─────────────────────────────────────
    (format t "~%── Ω2: make-backup-file-name (version-control) ──~%")
    (let ((limn/backup:*version-control* t))
      ;; No existing .~N~ → next free is .~1~.
      (let ((name (limn/backup:make-backup-file-name path)))
        (check (format nil "Ω2a first slot = .~~1~~ (got ~s)" name)
               (equal name n1)))
      ;; If .~1~ and .~2~ exist, next free should be .~3~.
      (write-file n1 "stub1")
      (write-file n2 "stub2")
      (let ((name (limn/backup:make-backup-file-name path)))
        (check (format nil "Ω2b next free slot = .~~3~~ (got ~s)" name)
               (equal name n3)))
      (nuke n1) (nuke n2))

    ;;; ── Ω3: backup-buffer creates ~ file ─────────────────────────────
    (format t "~%── Ω3: backup-buffer copies original ──~%")
    (let ((limn/backup:*version-control* nil)
          (limn/backup:*make-backup-files* t))
      (write-file path "original content\n")
      (limn/backup:clear-backed-up "b-1")
      (limn/backup:backup-buffer "b-1")
      (check (format nil "Ω3a path~~ exists on disk (got ~a)" (probe-file tilde))
             (probe-file tilde))
      (when (probe-file tilde)
        (check (format nil "Ω3b backup content = original (got ~s)" (slurp tilde))
               (equal (slurp tilde) "original content\n"))))

    ;;; ── Ω4 + Ω5: backed-up-p tracking + no-op on repeat ──────────────
    (format t "~%── Ω4+Ω5: backed-up-p tracking ──~%")
    (check "Ω4 backed-up-p t after first backup"
           (limn/backup:backed-up-p "b-1"))
    ;; Overwrite the original; second backup-buffer should NOT touch ~ file.
    (write-file path "new content (should NOT be in backup)\n")
    (write-file tilde "captured original")   ; reset ~ content to a sentinel
    (limn/backup:backup-buffer "b-1")
    (check (format nil "Ω5 repeat backup is no-op (~~ still sentinel; got ~s)"
                   (slurp tilde))
           (equal (slurp tilde) "captured original"))

    ;;; ── Ω6: *make-backup-files* nil ─────────────────────────────────
    (format t "~%── Ω6: *make-backup-files* nil ──~%")
    (nuke tilde)
    (limn/backup:clear-backed-up "b-1")
    (let ((limn/backup:*make-backup-files* nil))
      (limn/backup:backup-buffer "b-1")
      (check (format nil "Ω6 no ~~ file when *make-backup-files* nil (probe=~a)"
                     (probe-file tilde))
             (null (probe-file tilde))))

    ;;; ── Ω7: numbered backups stack ──────────────────────────────────
    (format t "~%── Ω7: version-control numbered ──~%")
    (dolist (p (list tilde n1 n2 n3 n4 n5 n6)) (nuke p))
    (let ((limn/backup:*version-control* t)
          (limn/backup:*make-backup-files* t)
          ;; Set kept-old/new high enough that no pruning happens within
          ;; three backups (we test pruning explicitly in Ω8).
          (limn/backup:*kept-old-versions* 99)
          (limn/backup:*kept-new-versions* 99))
      (dotimes (i 3)
        (write-file path (format nil "save ~a~%" (1+ i)))
        (limn/backup:clear-backed-up "b-1")
        (limn/backup:backup-buffer "b-1"))
      (check (format nil "Ω7a .~~1~~ exists (probe=~a)" (probe-file n1))
             (probe-file n1))
      (check (format nil "Ω7b .~~2~~ exists (probe=~a)" (probe-file n2))
             (probe-file n2))
      (check (format nil "Ω7c .~~3~~ exists (probe=~a)" (probe-file n3))
             (probe-file n3)))

    ;;; ── Ω8: pruning ─────────────────────────────────────────────────
    (format t "~%── Ω8: pruning math (keep-old=2 keep-new=2 on 6 slots) ──~%")
    (dolist (p (list n1 n2 n3 n4 n5 n6)) (nuke p))
    (let ((limn/backup:*version-control* t)
          (limn/backup:*make-backup-files* t)
          (limn/backup:*kept-old-versions* 2)
          (limn/backup:*kept-new-versions* 2))
      (dotimes (i 6)
        (write-file path (format nil "save ~a~%" (1+ i)))
        (limn/backup:clear-backed-up "b-1")
        (limn/backup:backup-buffer "b-1"))
      ;; Expect slots 1, 2, 5, 6 to survive; slots 3 and 4 deleted.
      (check (format nil "Ω8a .~~1~~ retained (oldest old, probe=~a)" (probe-file n1))
             (probe-file n1))
      (check (format nil "Ω8b .~~2~~ retained (kept-old #2, probe=~a)" (probe-file n2))
             (probe-file n2))
      (check (format nil "Ω8c .~~3~~ pruned (middle, probe=~a)" (probe-file n3))
             (null (probe-file n3)))
      (check (format nil "Ω8d .~~4~~ pruned (middle, probe=~a)" (probe-file n4))
             (null (probe-file n4)))
      (check (format nil "Ω8e .~~5~~ retained (kept-new #1, probe=~a)" (probe-file n5))
             (probe-file n5))
      (check (format nil "Ω8f .~~6~~ retained (newest, probe=~a)" (probe-file n6))
             (probe-file n6)))

    ;;; ── Ω9: hook firing order ────────────────────────────────────────
    (format t "~%── Ω9: before/after-backup-hook ──~%")
    (dolist (p (list tilde n1 n2 n3 n4 n5 n6)) (nuke p))
    (let ((trace nil))
      (let ((limn/backup:*before-backup-hook*
              (list (lambda (bid) (declare (ignore bid)) (push :before trace))))
            (limn/backup:*after-backup-hook*
              (list (lambda (bid) (declare (ignore bid)) (push :after trace))))
            (limn/backup:*version-control* nil)
            (limn/backup:*make-backup-files* t))
        (write-file path "fresh\n")
        (limn/backup:clear-backed-up "b-1")
        (limn/backup:backup-buffer "b-1")
        (check (format nil "Ω9 hooks fire in :before → :after order (trace=~s)"
                       (reverse trace))
               (equal (reverse trace) '(:before :after)))))

    ;; Cleanup
    (dolist (p (list path tilde n1 n2 n3 n4 n5 n6)) (nuke p)))

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
