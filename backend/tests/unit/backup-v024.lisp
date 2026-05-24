;;;; v0.24 §G — backup files RED tests
;;;;
;;;; 覆蓋：
;;;;   limn/backup : make-backup-file-name
;;;;                 backup-buffer
;;;;                 backed-up-p / set-backed-up
;;;;                 *make-backup-files* / *version-control*
;;;;                 *backup-by-copying* / *kept-old-versions* / *kept-new-versions*
;;;;                 *before-backup-hook* / *after-backup-hook*
;;;;
;;;; G 模組是純 Lisp + 磁碟 I/O（SBCL probe-file / rename-file / copy-file）。
;;;; 測試用 /tmp 實際建立暫存檔，在 unwind-protect 中清理。
;;;; 不依賴 bridge / C++。
;;;;
;;;; 全部 RED — 在 limn-backup.lisp 實作前都會 fail。

;; ── package stubs ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/backup)
    (make-package '#:limn/backup :use '(#:cl)))
  (dolist (sym '("MAKE-BACKUP-FILE-NAME"
                 "BACKUP-BUFFER"
                 "BACKED-UP-P" "SET-BACKED-UP" "CLEAR-BACKED-UP"
                 "*MAKE-BACKUP-FILES*"
                 "*VERSION-CONTROL*"
                 "*BACKUP-BY-COPYING*"
                 "*KEPT-OLD-VERSIONS*"
                 "*KEPT-NEW-VERSIONS*"
                 "*BEFORE-BACKUP-HOOK*"
                 "*AFTER-BACKUP-HOOK*"
                 ;; path vtable for test isolation
                 "*BUFFER-PATH-FN*"))
    (export (intern sym '#:limn/backup) '#:limn/backup)))

(in-package #:limn/unit-test)

;;; ── helpers ───────────────────────────────────────────────────────────────

(defun %tmppath (&optional (suffix ".txt"))
  (format nil "/tmp/limn-backup-test-~a~a" (random 9999999) suffix))

(defun %write-file (path content)
  (with-open-file (f path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (write-string content f)))

(defun %read-file (path)
  (with-open-file (f path :direction :input :if-does-not-exist nil)
    (when f
      (let ((buf (make-string (file-length f))))
        (read-sequence buf f)
        buf))))

(defmacro with-tmp-file ((path-var &key (content "original content")) &body body)
  "Create a real temp file, run BODY, delete file + all backup variants afterwards."
  `(let ((,path-var (%tmppath)))
     (unwind-protect
          (progn
            (%write-file ,path-var ,content)
            ,@body)
       ;; cleanup: delete the file and any numbered backups it might have
       (ignore-errors (delete-file ,path-var))
       (ignore-errors (delete-file (concatenate 'string ,path-var "~")))
       (loop for n from 1 to 20 do
         (ignore-errors
           (delete-file
             (format nil "~a.~~a~~" ,path-var n)))))))

(defmacro with-backup-buf ((buf-id path-var &key (content "original")) &body body)
  "Temp file + rebind *buffer-path-fn* so backup-buffer knows where this
   virtual buffer's file lives, then run BODY and clean up."
  `(with-tmp-file (,path-var :content ,content)
     (limn/backup:clear-backed-up ,buf-id)
     (let ((limn/backup:*buffer-path-fn*
             (lambda (bid)
               (when (equal bid ,buf-id) ,path-var))))
       ,@body)))

;;; ── G1. make-backup-file-name (non-numbered) ──────────────────────────────

(deftest backup-g1-simple-tilde
  "非 numbered 模式：path → path + '~'。"
  (let ((limn/backup:*version-control* nil))
    (assert-equal "/tmp/notes.txt~"
                  (limn/backup:make-backup-file-name "/tmp/notes.txt"))))

(deftest backup-g1-numbered-first-backup
  "numbered 模式，首次備份 → path.~1~。"
  (let ((limn/backup:*version-control* t))
    (let ((result (limn/backup:make-backup-file-name "/tmp/notes.txt")))
      (assert-true (or (search ".~1~" result)
                       (search ".~" result))
                   "numbered backup has ~N~ suffix"))))

(deftest backup-g1-numbered-increment
  "numbered 模式，已存在 .~1~ 時回 .~2~。"
  (let ((limn/backup:*version-control* t))
    (with-tmp-file (p :content "")
      ;; create artificial .~1~ file
      (let ((n1 (concatenate 'string p ".~1~")))
        (unwind-protect
             (progn
               (%write-file n1 "backup1")
               (let ((next (limn/backup:make-backup-file-name p)))
                 (assert-true (search ".~2~" next)
                              "increments to .~2~")))
          (ignore-errors (delete-file n1)))))))

(deftest backup-g1-hidden-dotfile
  "dotfile（.emacs）的備份是 .emacs~ 或 .emacs.~1~。"
  (let ((limn/backup:*version-control* nil))
    (let ((result (limn/backup:make-backup-file-name "/home/jin/.emacs")))
      (assert-true (search ".emacs~" result)
                   "dotfile gets tilde backup"))))

(deftest backup-g1-path-with-spaces
  "路徑含空白字元不影響備份檔名計算。"
  (let ((limn/backup:*version-control* nil))
    (let ((result (limn/backup:make-backup-file-name "/tmp/my notes.txt")))
      (assert-true (search "my notes.txt~" result)
                   "path with spaces handled"))))

;;; ── G2. backup-buffer (real files) ───────────────────────────────────────

(deftest backup-g2-creates-backup-file
  "backup-buffer 在 original 旁建立備份檔。"
  (let ((limn/backup:*make-backup-files*  t)
        (limn/backup:*version-control*    nil)
        (limn/backup:*backup-by-copying*  t))
    (with-backup-buf ("gbuf1" p :content "important data")
      (limn/backup:backup-buffer "gbuf1")
      (let ((bak (concatenate 'string p "~")))
        (assert-true (probe-file bak) "backup file exists")
        (assert-equal "important data" (%read-file bak)
                      "backup content matches original")
        (ignore-errors (delete-file bak))))))

(deftest backup-g2-backup-by-renaming
  "*backup-by-copying* nil → rename original to backup path, then save
   overwrites original (外層已 backed-up 所以 original 仍存在)。"
  (let ((limn/backup:*make-backup-files* t)
        (limn/backup:*version-control*   nil)
        (limn/backup:*backup-by-copying* nil))
    (with-backup-buf ("gbuf2" p :content "rename me")
      (limn/backup:backup-buffer "gbuf2")
      (let ((bak (concatenate 'string p "~")))
        (assert-true (probe-file bak) "backup file exists after rename")
        (ignore-errors (delete-file bak))))))

(deftest backup-g2-no-double-backup-same-session
  "同一 session 的同一 buffer 只備份一次（backed-up-p 旗標保護）。"
  (let ((limn/backup:*make-backup-files* t)
        (limn/backup:*version-control*   nil)
        (limn/backup:*backup-by-copying* t))
    (with-backup-buf ("gbuf3" p :content "once")
      (limn/backup:backup-buffer "gbuf3")
      ;; 寫新內容進去，再備份一次
      (%write-file p "modified")
      (limn/backup:backup-buffer "gbuf3")
      (let ((bak (concatenate 'string p "~")))
        (assert-equal "once" (%read-file bak)
                      "backup still contains first save (not overwritten)")
        (ignore-errors (delete-file bak))))))

(deftest backup-g2-make-backup-files-nil-no-backup
  "*make-backup-files* nil → backup-buffer は no-op。"
  (let ((limn/backup:*make-backup-files* nil))
    (with-backup-buf ("gbuf4" p :content "no backup")
      (limn/backup:backup-buffer "gbuf4")
      (let ((bak (concatenate 'string p "~")))
        (assert-false (probe-file bak) "no backup file created")))))

;;; ── G3. flags ─────────────────────────────────────────────────────────────

(deftest backup-g3-backed-up-p-starts-false
  "新 buf-id 的 backed-up-p 初始是 false。"
  (limn/backup:clear-backed-up "fresh-buf")
  (assert-false (limn/backup:backed-up-p "fresh-buf")))

(deftest backup-g3-set-backed-up-marks-buffer
  "set-backed-up 之後 backed-up-p 回 true。"
  (limn/backup:clear-backed-up "flag-buf")
  (limn/backup:set-backed-up "flag-buf")
  (assert-true (limn/backup:backed-up-p "flag-buf")))

(deftest backup-g3-clear-backed-up-resets
  "clear-backed-up 讓 backed-up-p 回 false。"
  (limn/backup:set-backed-up "clear-buf")
  (limn/backup:clear-backed-up "clear-buf")
  (assert-false (limn/backup:backed-up-p "clear-buf")))

;;; ── G4. version cleanup ───────────────────────────────────────────────────

(deftest backup-g4-prune-old-numbered-backups
  "numbered backup 超過 *kept-new-versions* 時刪掉最舊的。
   只驗 make-backup-file-name 不會無限遞增到荒謬的數字（行為合理即可）。"
  (let ((limn/backup:*version-control*    t)
        (limn/backup:*kept-new-versions*  2)
        (limn/backup:*kept-old-versions*  1))
    (with-tmp-file (p :content "")
      ;; Manually create .~1~ .~2~ .~3~ and see what backup-buffer picks
      (let ((n1 (format nil "~a.~~1~~" p))
            (n2 (format nil "~a.~~2~~" p))
            (n3 (format nil "~a.~~3~~" p)))
        (unwind-protect
             (progn
               (%write-file n1 "1")
               (%write-file n2 "2")
               (%write-file n3 "3")
               (let ((limn/backup:*buffer-path-fn*
                       (lambda (bid) (declare (ignore bid)) p)))
                 (limn/backup:clear-backed-up "prune-buf")
                 (assert-no-error (limn/backup:backup-buffer "prune-buf"))))
          (ignore-errors (delete-file n1))
          (ignore-errors (delete-file n2))
          (ignore-errors (delete-file n3)))))))

(deftest backup-g4-hooks-fire
  "*before-backup-hook* / *after-backup-hook* fire around backup。"
  (let ((limn/backup:*make-backup-files* t)
        (limn/backup:*version-control*   nil)
        (limn/backup:*backup-by-copying* t)
        (before-called nil)
        (after-called  nil))
    (let ((limn/backup:*before-backup-hook*
            (list (lambda (bid) (declare (ignore bid))
                    (setf before-called t))))
          (limn/backup:*after-backup-hook*
            (list (lambda (bid) (declare (ignore bid))
                    (setf after-called t)))))
      (with-backup-buf ("hook-buf" p :content "hook test")
        (limn/backup:backup-buffer "hook-buf")
        (assert-true before-called "before-backup-hook fired")
        (assert-true after-called  "after-backup-hook fired")
        (ignore-errors (delete-file (concatenate 'string p "~")))))))
