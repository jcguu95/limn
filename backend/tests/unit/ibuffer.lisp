;;;; Unit tests for limn-ibuffer (ibuffer-mode).
;;;;
;;;; Pure-Lisp; vtable progv-bound to mocks so no wire round-trips.

(in-package #:limn/unit-test)

;;; ── mock vtable + clean registry helpers ───────────────────────────────

(defstruct ibuffer-mock
  written            ; latest content passed to *ibuffer-write-fn*
  written-bid        ; latest bid passed to *ibuffer-write-fn*
  cursor             ; (bid . offset) of latest cursor move
  switched           ; latest buffer-id passed to *ibuffer-switch-fn*
  (saves '())        ; list of buffer-ids passed to *ibuffer-save-fn*
  (kills '()))       ; list of buffer-ids passed to *ibuffer-kill-fn*

(defmacro with-ibuffer-mock ((var) &body body)
  "Bind a fresh ibuffer-mock to VAR and progv the ibuffer vtable to
   route through it.  Resets limn/buffer + *ibuffer-state* around BODY.
   Declarations at the start of BODY are honoured."
  (let ((pkg (gensym "PKG")))
    `(let* ((,var (make-ibuffer-mock))
            (,pkg (find-package '#:limn/ibuffer)))
       (handler-case (limn/buffer:clear-all) (error () nil))
       (when ,pkg
         (let ((sst (find-symbol "*IBUFFER-STATE*" ,pkg)))
           (when (and sst (boundp sst)) (setf (symbol-value sst) nil))))
       (let* ((pairs
                (and ,pkg
                     (list
                      (cons (find-symbol "*IBUFFER-WRITE-FN*" ,pkg)
                            (lambda (bid content)
                              (setf (ibuffer-mock-written-bid ,var) bid
                                    (ibuffer-mock-written ,var)     content)))
                      (cons (find-symbol "*IBUFFER-SWITCH-FN*" ,pkg)
                            (lambda (bid)
                              (setf (ibuffer-mock-switched ,var) bid)))
                      (cons (find-symbol "*IBUFFER-SAVE-FN*" ,pkg)
                            (lambda (bid)
                              (push bid (ibuffer-mock-saves ,var))))
                      (cons (find-symbol "*IBUFFER-KILL-FN*" ,pkg)
                            (lambda (bid)
                              (push bid (ibuffer-mock-kills ,var))
                              ;; Mirror production: drop from registry too.
                              (handler-case (limn/buffer:unregister bid)
                                (error () nil))))
                      (cons (find-symbol "*IBUFFER-CURSOR-FN*" ,pkg)
                            (lambda (bid offset)
                              (setf (ibuffer-mock-cursor ,var)
                                    (cons bid offset)))))))
              (live (remove-if (lambda (p) (null (car p))) pairs)))
         (progv (mapcar #'car live) (mapcar #'cdr live)
           (unwind-protect
                (let () ,@body)
             (handler-case (limn/buffer:clear-all) (error () nil))))))))

(defun %seed-buffers ()
  "Register a small fixed set of buffers used by most tests."
  (limn/buffer:register "b1" "/tmp/zeta.txt"  "text")
  (limn/buffer:register "b2" "/tmp/alpha.pdf" "mupdf")
  (limn/buffer:register "b3" "/tmp/mid.txt"   "text"))

;;; ── pure-API tests ─────────────────────────────────────────────────────

(deftest ibuffer-collect-rows-empty
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (assert-equal nil (limn/ibuffer:collect-rows))))

(deftest ibuffer-collect-rows-three
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (let ((rows (limn/ibuffer:collect-rows)))
      (assert-equal 3 (length rows))
      (let ((ids (mapcar #'limn/ibuffer:ibuffer-row-id rows)))
        (assert-true (member "b1" ids :test #'string=))
        (assert-true (member "b2" ids :test #'string=))
        (assert-true (member "b3" ids :test #'string=))))))

(deftest ibuffer-sort-by-id
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (let* ((rows   (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :id))
           (ids    (mapcar #'limn/ibuffer:ibuffer-row-id rows)))
      (assert-equal '("b1" "b2" "b3") ids))))

(deftest ibuffer-sort-by-path
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (let* ((rows  (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :path))
           (paths (mapcar #'limn/ibuffer:ibuffer-row-path rows)))
      (assert-equal '("/tmp/alpha.pdf" "/tmp/mid.txt" "/tmp/zeta.txt") paths))))

(deftest ibuffer-sort-by-engine
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (let* ((rows    (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :engine))
           (engines (mapcar #'limn/ibuffer:ibuffer-row-engine rows)))
      ;; mupdf < text alphabetically.
      (assert-equal '("mupdf" "text" "text") engines))))

(deftest ibuffer-filter-substring
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (let* ((all (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :id))
           (kept (limn/ibuffer:filter-rows all "alpha")))
      (assert-equal 1 (length kept))
      (assert-equal "b2" (limn/ibuffer:ibuffer-row-id (first kept))))))

(deftest ibuffer-filter-empty-passes-all
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (let* ((all (limn/ibuffer:collect-rows))
           (k1  (limn/ibuffer:filter-rows all ""))
           (k2  (limn/ibuffer:filter-rows all nil)))
      (assert-equal 3 (length k1))
      (assert-equal 3 (length k2)))))

(deftest ibuffer-format-mark-shapes
  (assert-equal "  " (limn/ibuffer:format-mark '()))
  (assert-equal "D " (limn/ibuffer:format-mark (list #\D)))
  (assert-equal "DS" (limn/ibuffer:format-mark (list #\D #\S))))

(deftest ibuffer-format-no-buffers
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (let* ((s (limn/ibuffer:make-ibuffer-state)))
      (let ((out (limn/ibuffer:format-ibuffer-results s)))
        (assert-true (search "No buffers." out)
                     "empty state renders the No buffers sentinel")
        (assert-true (search "ENGINE" out)
                     "header still rendered")))))

(deftest ibuffer-format-three-rows
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (let* ((rows (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :id))
           (s    (limn/ibuffer:make-ibuffer-state :rows rows))
           (out  (limn/ibuffer:format-ibuffer-results s)))
      (assert-true (search "b1" out))
      (assert-true (search "b2" out))
      (assert-true (search "b3" out))
      (assert-true (search "/tmp/zeta.txt" out))
      (assert-true (search "mupdf" out)))))

(deftest ibuffer-mark-set-and-clear
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (let ((s (limn/ibuffer:make-ibuffer-state)))
      (limn/ibuffer:mark-set s "b1" #\D)
      (assert-equal '(#\D) (limn/ibuffer:marks-of s "b1"))
      ;; Idempotent.
      (limn/ibuffer:mark-set s "b1" #\D)
      (assert-equal '(#\D) (limn/ibuffer:marks-of s "b1"))
      ;; Add S on top.
      (limn/ibuffer:mark-set s "b1" #\S)
      (assert-equal '(#\D #\S) (limn/ibuffer:marks-of s "b1"))
      ;; Clear D only.
      (limn/ibuffer:mark-clear s "b1" #\D)
      (assert-equal '(#\S) (limn/ibuffer:marks-of s "b1"))
      ;; Clear everything on b1.
      (limn/ibuffer:mark-clear s "b1")
      (assert-equal nil (limn/ibuffer:marks-of s "b1")))))

(deftest ibuffer-next-prev-wraps
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (let* ((rows (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :id))
           (s    (limn/ibuffer:make-ibuffer-state :rows rows :current 0)))
      (limn/ibuffer:next-row s)
      (assert-equal 1 (limn/ibuffer:ibuffer-state-current s))
      (limn/ibuffer:next-row s)
      (limn/ibuffer:next-row s)
      (assert-equal 0 (limn/ibuffer:ibuffer-state-current s)
                    "wraps to 0 after passing end")
      (limn/ibuffer:prev-row s)
      (assert-equal 2 (limn/ibuffer:ibuffer-state-current s)
                    "wraps to last when going backwards from 0"))))

(deftest ibuffer-next-row-on-empty-is-noop
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (let ((s (limn/ibuffer:make-ibuffer-state)))
      (limn/ibuffer:next-row s)
      (assert-equal nil (limn/ibuffer:ibuffer-state-current s)))))

;;; ── full-flow tests (state + render via mock vtable) ───────────────────

(deftest ibuffer-enter-writes-table-and-switches
  (with-ibuffer-mock (m)
    (%seed-buffers)
    (limn/ibuffer::%enter-ibuffer)
    (assert-true (search "b1" (or (ibuffer-mock-written m) ""))
                 "render content mentions b1")
    (assert-true (ibuffer-mock-switched m)
                 "switch-fn called to bring *Buffer List* to front")))

(deftest ibuffer-mark-d-then-execute-kills
  (with-ibuffer-mock (m)
    (%seed-buffers)
    (limn/ibuffer::%enter-ibuffer)
    ;; b1 is at index 0 after sort-by id.
    (limn/ibuffer::%mark-and-advance #\D)         ; marks b1
    (limn/ibuffer::%execute-marks)
    (assert-true (member "b1" (ibuffer-mock-kills m) :test #'string=)
                 "b1 killed")
    (assert-equal nil (limn/buffer:lookup "b1")
                  "b1 dropped from limn/buffer")
    ;; Surviving rows should reflect the deletion.
    (let ((rows (limn/ibuffer:ibuffer-state-rows
                 limn/ibuffer:*ibuffer-state*)))
      (assert-equal 2 (length rows)))))

(deftest ibuffer-mark-s-then-execute-saves
  (with-ibuffer-mock (m)
    (%seed-buffers)
    (limn/ibuffer::%enter-ibuffer)
    (limn/ibuffer::%mark-and-advance #\S)         ; marks b1
    (limn/ibuffer::%execute-marks)
    (assert-true (member "b1" (ibuffer-mock-saves m) :test #'string=)
                 "save-fn called on b1")
    (assert-true (limn/buffer:lookup "b1")
                 "b1 still registered (save does not unregister)")))

(deftest ibuffer-visit-switches-to-row
  (with-ibuffer-mock (m)
    (%seed-buffers)
    (limn/ibuffer::%enter-ibuffer)
    ;; entry sets switched := *Buffer List* id; clear and re-verify.
    (setf (ibuffer-mock-switched m) nil)
    (limn/ibuffer::%visit)
    (assert-equal "b1" (ibuffer-mock-switched m)
                  "visit on row 0 switches to b1")))

(deftest ibuffer-revert-picks-up-new-buffer
  (with-ibuffer-mock (m)
    (%seed-buffers)
    (limn/ibuffer::%enter-ibuffer)
    (limn/buffer:register "b4" "/tmp/new.txt" "text")
    (limn/ibuffer::%revert)
    (let ((out (or (ibuffer-mock-written m) "")))
      (assert-true (search "b4" out)
                   "revert renders the newly-registered buffer"))))

(deftest ibuffer-sort-by-changes-order
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (limn/ibuffer::%enter-ibuffer)
    (limn/ibuffer::%sort-by "path")
    (let* ((rows  (limn/ibuffer:ibuffer-state-rows
                   limn/ibuffer:*ibuffer-state*))
           (paths (mapcar #'limn/ibuffer:ibuffer-row-path rows)))
      (assert-equal '("/tmp/alpha.pdf" "/tmp/mid.txt" "/tmp/zeta.txt") paths))))

(deftest ibuffer-set-filter-restricts-rows
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (limn/ibuffer::%enter-ibuffer)
    (limn/ibuffer::%set-filter "alpha")
    (let ((rows (limn/ibuffer:ibuffer-state-rows
                 limn/ibuffer:*ibuffer-state*)))
      (assert-equal 1 (length rows))
      (assert-equal "b2" (limn/ibuffer:ibuffer-row-id (first rows))))))

(deftest ibuffer-unmark-all-clears-marks
  (with-ibuffer-mock (m)
    (declare (ignore m))
    (%seed-buffers)
    (limn/ibuffer::%enter-ibuffer)
    (limn/ibuffer::%mark-and-advance #\D)
    (limn/ibuffer::%mark-and-advance #\S)
    (limn/ibuffer::%unmark-all)
    (let ((tbl (limn/ibuffer:ibuffer-state-marks
                limn/ibuffer:*ibuffer-state*)))
      (assert-equal 0 (hash-table-count tbl)))))
