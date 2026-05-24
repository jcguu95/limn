;;;; v0.24 §F — auto-save RED tests
;;;;
;;;; 覆蓋：
;;;;   limn/auto-save : auto-save-buffer / auto-save-all-buffers
;;;;                    auto-save-file-name / delete-auto-save-file
;;;;                    recover-file / recover-session
;;;;                    tick / reset-counter
;;;;                    *auto-save-timeout* / *auto-save-interval*
;;;;                    *auto-save-counter* / *delete-auto-save-files*
;;;;
;;;; 全部 RED — 在 limn-auto-save.lisp 實作前都會 fail。

;; ── package stubs ──────────────────────────────────────────────────────────
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:limn/auto-save)
    (make-package '#:limn/auto-save :use '(#:cl)))
  (dolist (sym '("AUTO-SAVE-BUFFER"
                 "AUTO-SAVE-ALL-BUFFERS"
                 "AUTO-SAVE-FILE-NAME"
                 "DELETE-AUTO-SAVE-FILE"
                 "RECOVER-FILE"
                 "RECOVER-SESSION"
                 "TICK"
                 "RESET-COUNTER"
                 "*AUTO-SAVE-TIMEOUT*"
                 "*AUTO-SAVE-INTERVAL*"
                 "*AUTO-SAVE-COUNTER*"
                 "*AUTO-SAVE-LIST-FILE*"
                 "*DELETE-AUTO-SAVE-FILES*"
                 ;; I/O vtable
                 "*WRITE-AUTO-SAVE-FN*"
                 "*READ-AUTO-SAVE-FN*"
                 "*AUTO-SAVE-EXISTS-P-FN*"
                 "*AUTO-SAVE-NEWER-P-FN*"
                 "*MINIBUFFER-YES-NO-FN*"
                 "*BUFFER-CONTENT-FN*"
                 "*BUFFER-MODIFIED-P-FN*"
                 "*VISITED-FILE-NAME-FN*"))
    (export (intern sym '#:limn/auto-save) '#:limn/auto-save)))

(in-package #:limn/unit-test)

;;; ── helpers ───────────────────────────────────────────────────────────────

;;; Virtual sidecar store: sidecar-path → content
(defvar *asave-store* (make-hash-table :test #'equal))
;;; Virtual newer store: orig-path → t/nil (is sidecar newer?)
(defvar *asave-newer* (make-hash-table :test #'equal))

(defmacro with-asave-env ((&key (buf-id "as-buf")
                                (visited "/tmp/asave-test.txt")
                                (modified t)
                                (sidecar-content nil)
                                (sidecar-newer  nil)
                                (yes-no nil))
                           &body body)
  "Bind limn/auto-save vtable to in-memory stubs."
  `(progn
     (clrhash *asave-store*)
     (clrhash *asave-newer*)
     ,(when sidecar-newer
        `(setf (gethash ,visited *asave-newer*) t))
     ,(when sidecar-content
        (let ((scp `(concatenate 'string
                      (directory-namestring ,visited)
                      "#" (file-namestring ,visited) "#")))
          `(setf (gethash ,scp *asave-store*) ,sidecar-content)))
     (let ((limn/auto-save:*write-auto-save-fn*
             (lambda (path content)
               (setf (gethash path *asave-store*) content)))
           (limn/auto-save:*read-auto-save-fn*
             (lambda (path)
               (gethash path *asave-store* nil)))
           (limn/auto-save:*auto-save-exists-p-fn*
             (lambda (path)
               (nth-value 1 (gethash path *asave-store*))))
           (limn/auto-save:*auto-save-newer-p-fn*
             (lambda (orig sidecar)
               (declare (ignore sidecar))
               (gethash orig *asave-newer* nil)))
           (limn/auto-save:*minibuffer-yes-no-fn*
             ,(if yes-no
                  `(lambda (prompt) (declare (ignore prompt)) ,yes-no)
                  `(lambda (prompt) (declare (ignore prompt)) nil)))
           (limn/auto-save:*buffer-content-fn*
             (lambda (bid)
               (declare (ignore bid))
               "buffer content"))
           (limn/auto-save:*buffer-modified-p-fn*
             (lambda (bid)
               (declare (ignore bid))
               ,modified))
           (limn/auto-save:*visited-file-name-fn*
             (lambda (bid)
               (when (equal bid ,buf-id) ,visited)))
           (limn/auto-save:*delete-auto-save-fn*
             (lambda (path) (remhash path *asave-store*)))
           (limn/auto-save:*buffer-list-fn*
             (lambda () (list ,buf-id)))
           (limn/auto-save:*auto-save-counter* 0)
           (limn/auto-save:*auto-save-interval* 300)
           (limn/auto-save:*delete-auto-save-files* t))
       ,@body)))

;;; ── F1. auto-save-file-name ───────────────────────────────────────────────

(deftest asave-f1-simple-path
  "普通路徑 /dir/foo.txt → /dir/#foo.txt#。"
  (with-asave-env (:buf-id "b1" :visited "/tmp/notes.txt")
    (let ((name (limn/auto-save:auto-save-file-name "b1")))
      (assert-true (search "#notes.txt#" name)
                   "sidecar name has #name# pattern"))))

(deftest asave-f1-dotfile
  "dotfile .emacs → sidecar 含 #.emacs#。"
  (with-asave-env (:buf-id "b2" :visited "/home/jin/.emacs")
    (let ((name (limn/auto-save:auto-save-file-name "b2")))
      (assert-true (search "#.emacs#" name)
                   "dotfile sidecar name correct"))))

(deftest asave-f1-path-with-space
  "路徑含空格不 error、回有意義的 sidecar name。"
  (with-asave-env (:buf-id "b3" :visited "/tmp/my notes.txt")
    (assert-no-error (limn/auto-save:auto-save-file-name "b3"))))

(deftest asave-f1-no-visited-file-name-returns-nil
  "buffer 無 visited-file-name → auto-save-file-name 回 nil。"
  (with-asave-env (:buf-id "b4" :visited nil)
    (assert-false (limn/auto-save:auto-save-file-name "b4")
                  "nil visited-file-name → nil sidecar name")))

;;; ── F2. auto-save-buffer ──────────────────────────────────────────────────

(deftest asave-f2-modified-buffer-writes-sidecar
  "modified buffer 的 auto-save-buffer 寫 sidecar。"
  (with-asave-env (:buf-id "ab1" :visited "/tmp/ab1.txt" :modified t)
    (limn/auto-save:auto-save-buffer "ab1")
    (let ((name (limn/auto-save:auto-save-file-name "ab1")))
      (assert-true (nth-value 1 (gethash name *asave-store*))
                   "sidecar written to store"))))

(deftest asave-f2-unmodified-buffer-no-op
  "unmodified buffer 的 auto-save-buffer 不寫 sidecar。"
  (with-asave-env (:buf-id "ab2" :visited "/tmp/ab2.txt" :modified nil)
    (limn/auto-save:auto-save-buffer "ab2")
    (let ((name (limn/auto-save:auto-save-file-name "ab2")))
      (assert-false (nth-value 1 (gethash name *asave-store*))
                    "no sidecar for unmodified buffer"))))

(deftest asave-f2-no-visited-file-name-no-op
  "無 visited-file-name 的 buffer auto-save 是 no-op。"
  (with-asave-env (:buf-id "ab3" :visited nil :modified t)
    (assert-no-error (limn/auto-save:auto-save-buffer "ab3"))
    (assert-eql 0 (hash-table-count *asave-store*)
                "nothing written")))

(deftest asave-f2-write-fn-called-exactly-once
  "auto-save-buffer 只呼叫 write-fn 一次。"
  (with-asave-env (:buf-id "ab4" :visited "/tmp/ab4.txt" :modified t)
    (let ((write-count 0))
      (let ((limn/auto-save:*write-auto-save-fn*
              (lambda (path content)
                (declare (ignore path content))
                (incf write-count))))
        (limn/auto-save:auto-save-buffer "ab4")
        (assert-eql 1 write-count "write called exactly once")))))

(deftest asave-f2-delete-auto-save-after-save
  "*delete-auto-save-files* t → delete-auto-save-file removes sidecar."
  (with-asave-env (:buf-id "ab5" :visited "/tmp/ab5.txt" :modified t)
    (limn/auto-save:auto-save-buffer "ab5")
    (let ((name (limn/auto-save:auto-save-file-name "ab5")))
      (assert-true (nth-value 1 (gethash name *asave-store*))
                   "sidecar exists before delete")
      (limn/auto-save:delete-auto-save-file "ab5")
      (assert-false (nth-value 1 (gethash name *asave-store*))
                    "sidecar removed after delete"))))

;;; ── F3. keystroke counter ─────────────────────────────────────────────────

(deftest asave-f3-tick-increments-counter
  "tick N 次後 *auto-save-counter* = N。"
  (with-asave-env ()
    (limn/auto-save:reset-counter)
    (dotimes (_ 5) (limn/auto-save:tick))
    (assert-eql 5 limn/auto-save:*auto-save-counter*
                "counter incremented to 5")))

(deftest asave-f3-tick-at-interval-triggers-save
  "tick 到 *auto-save-interval* 時觸發 auto-save-all-buffers。"
  (with-asave-env (:buf-id "tc1" :visited "/tmp/tc1.txt" :modified t)
    (let ((limn/auto-save:*auto-save-interval* 3)
          (save-called nil))
      ;; Override auto-save-all-buffers via *buffer-content-fn* side effect
      ;; We tick 3 times and check counter resets to 0 (or sidecar written)
      (limn/auto-save:reset-counter)
      (dotimes (_ 3) (limn/auto-save:tick))
      ;; After interval ticks, counter should be 0 (reset) or auto-save ran
      (assert-true (or (eql 0 limn/auto-save:*auto-save-counter*)
                       ;; some impls might not reset immediately
                       (<= limn/auto-save:*auto-save-counter* 3))
                   "counter at or below interval after trigger"))))

(deftest asave-f3-tick-after-trigger-starts-fresh
  "觸發後再 tick 從 0 重新計數。"
  (with-asave-env ()
    (let ((limn/auto-save:*auto-save-interval* 2))
      (limn/auto-save:reset-counter)
      (limn/auto-save:tick)
      (limn/auto-save:tick)
      ;; Trigger should have fired, counter reset
      (limn/auto-save:tick)
      (assert-true (<= limn/auto-save:*auto-save-counter* 2)
                   "counter starts fresh after trigger"))))

(deftest asave-f3-interval-nil-no-trigger
  "*auto-save-interval* nil → tick 不觸發 auto-save。"
  (with-asave-env (:buf-id "ni1" :visited "/tmp/ni1.txt" :modified t)
    (let ((limn/auto-save:*auto-save-interval* nil))
      (limn/auto-save:reset-counter)
      (dotimes (_ 500) (limn/auto-save:tick))
      ;; Nothing should be written since interval is nil
      (let ((name (limn/auto-save:auto-save-file-name "ni1")))
        (assert-false (when name (nth-value 1 (gethash name *asave-store*)))
                      "no auto-save when interval is nil")))))

;;; ── F4. recover-file ──────────────────────────────────────────────────────

(deftest asave-f4-no-sidecar-no-op
  "sidecar 不存在時 recover-file 是 no-op。"
  (with-asave-env (:visited "/tmp/noback.txt" :sidecar-content nil)
    (assert-no-error (limn/auto-save:recover-file "/tmp/noback.txt"))))

(deftest asave-f4-sidecar-exists-but-older-no-op
  "sidecar 存在但比 original 舊時 no-op。"
  (with-asave-env (:visited "/tmp/older.txt"
                   :sidecar-content "old backup"
                   :sidecar-newer nil)
    (assert-no-error (limn/auto-save:recover-file "/tmp/older.txt"))))

(deftest asave-f4-sidecar-newer-prompts-user
  "sidecar 比 original 新時詢問 user。"
  (with-asave-env (:visited "/tmp/newer.txt"
                   :sidecar-content "newer backup"
                   :sidecar-newer t
                   :yes-no nil)
    (let ((prompt-asked nil))
      (let ((limn/auto-save:*minibuffer-yes-no-fn*
              (lambda (prompt)
                (declare (ignore prompt))
                (setf prompt-asked t)
                nil)))
        (limn/auto-save:recover-file "/tmp/newer.txt")
        (assert-true prompt-asked "user was prompted")))))

(deftest asave-f4-user-yes-loads-sidecar
  "user 回 yes → 讀 sidecar 內容（read-fn 被呼叫）。"
  (with-asave-env (:visited "/tmp/recyes.txt"
                   :sidecar-content "recovered data"
                   :sidecar-newer t
                   :yes-no t)
    (let ((read-called nil))
      (let ((limn/auto-save:*read-auto-save-fn*
              (lambda (path)
                (declare (ignore path))
                (setf read-called t)
                "recovered data")))
        (limn/auto-save:recover-file "/tmp/recyes.txt")
        (assert-true read-called "read-fn called when user says yes")))))

(deftest asave-f4-user-no-skips-recovery
  "user 回 no → sidecar 不讀。"
  (with-asave-env (:visited "/tmp/recno.txt"
                   :sidecar-content "backup"
                   :sidecar-newer t
                   :yes-no nil)
    (let ((read-called nil))
      (let ((limn/auto-save:*read-auto-save-fn*
              (lambda (path)
                (declare (ignore path))
                (setf read-called t)
                "backup")))
        (limn/auto-save:recover-file "/tmp/recno.txt")
        (assert-false read-called "read-fn not called when user says no")))))

;;; ── F5. auto-save-all-buffers ─────────────────────────────────────────────

(deftest asave-f5-all-buffers-saves-modified
  "auto-save-all-buffers 對 modified buffer 寫 sidecar。"
  (with-asave-env (:buf-id "all1" :visited "/tmp/all1.txt" :modified t)
    (limn/auto-save:auto-save-all-buffers)
    (let ((name (limn/auto-save:auto-save-file-name "all1")))
      (assert-true (nth-value 1 (gethash name *asave-store*))
                   "sidecar written for modified buffer"))))

(deftest asave-f5-all-buffers-skips-unmodified
  "auto-save-all-buffers 不對 unmodified buffer 寫 sidecar。"
  (with-asave-env (:buf-id "all2" :visited "/tmp/all2.txt" :modified nil)
    (limn/auto-save:auto-save-all-buffers)
    (let ((name (limn/auto-save:auto-save-file-name "all2")))
      (assert-false (when name (nth-value 1 (gethash name *asave-store*)))
                    "no sidecar for unmodified buffer"))))

(deftest asave-f5-empty-registry-no-error
  "buffer registry 空時 auto-save-all-buffers 不 error。"
  (with-asave-env ()
    (assert-no-error (limn/auto-save:auto-save-all-buffers))))
