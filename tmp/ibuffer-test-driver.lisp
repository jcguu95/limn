;;;; ibuffer-test-driver.lisp — interactive sanity walk for ibuffer mode.
;;;;
;;;; Loaded via `nix develop --command sbcl --load <this>`.  Auto-evals
;;;; a series of forms; each step shows the form, the expected result,
;;;; the actual result, and either auto-passes (when an auto-check
;;;; predicate matches) or asks the user [RET]/n/s/q.  Prints a final
;;;; report ready to copy-paste.

(in-package #:cl-user)

;; Pre-required modules limn touches (sb-posix:getenv for init-file
;; lookup; sb-bsd-sockets for limn-client's defpackage :use).
(require :asdf)
(require :sb-posix)
(require :sb-bsd-sockets)

(defparameter *repo*
  "/Users/jin/data/local/projects/sioyek-core/.claude/worktrees/mystifying-dijkstra-2400c3/")

(push (concatenate 'string *repo* "backend/") asdf:*central-registry*)

;;; ── load system (quiet on success, loud on failure) ────────────────────

(format t "~&━━━ 載入 limn system… ━━━~%")
(finish-output)

(let ((buf (make-string-output-stream)))
  (handler-case
      (let ((*standard-output* buf)
            (*trace-output*    buf))
        (asdf:load-system :limn))
    (error (e)
      (format t "✗ ASDF load 失敗:~%~a~%~%──── captured output ────~%~a~%"
              e (get-output-stream-string buf))
      (sb-ext:exit :code 1))))

(format t "✓ limn 載入完成。~%~%")
(finish-output)

;;; ── harness ────────────────────────────────────────────────────────────

(defvar *results* '())
(defvar *step-counter* 0)

(defun read-line-trim ()
  (let ((line (read-line *standard-input* nil "")))
    (string-trim '(#\Space #\Tab #\Newline #\Return) (or line ""))))

(defun pretty (form)
  (with-output-to-string (s)
    (let ((*print-pretty* t)
          (*print-right-margin* 65))
      (prin1 form s))))

(defun render-block (label text)
  (format t " ~a:~%" label)
  (with-input-from-string (s (if (stringp text) text (pretty text)))
    (loop for line = (read-line s nil)
          while line do (format t "   ~a~%" line))))

(defun render-actual (actual)
  ;; Multiline strings (e.g. format-ibuffer-results) deserve a
  ;; readable display, not an escaped \n soup.
  (cond
    ((and (stringp actual) (find #\Newline actual))
     (format t " 實際 (multiline string):~%")
     (with-input-from-string (s actual)
       (loop for line = (read-line s nil)
             while line do (format t "   | ~a~%" line))))
    (t
     (render-block "實際" (pretty actual)))))

(defun banner (title)
  (incf *step-counter*)
  (format t "~&~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
  (format t " Step ~a: ~a~%" *step-counter* title)
  (format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%"))

(defun run-form-step (title form expected-str)
  (banner title)
  (render-block "Form" (pretty form))
  (render-block "預期" expected-str)
  (format t "─────────────────────────────────────────────────────────~%")
  (let ((actual (handler-case (eval form)
                  (error (e)
                    (list :error (princ-to-string e))))))
    (render-actual actual)
    (format t "─────────────────────────────────────────────────────────~%")
    (format t " 看一下「預期」跟「實際」一致嗎？~%")
    (format t " [RET]=PASS   n=FAIL   s=SKIP   q=QUIT~%")
    (format t " > ")
    (finish-output)
    (let ((line (read-line-trim)))
      (cond
        ((or (string= line "q") (string= line "Q"))
         (push (list *step-counter* title :quit actual) *results*)
         (throw 'quit nil))
        ((or (string= line "n") (string= line "N"))
         (push (list *step-counter* title :fail actual) *results*)
         (format t " → 標 FAIL~%"))
        ((or (string= line "s") (string= line "S"))
         (push (list *step-counter* title :skip actual) *results*)
         (format t " → SKIP~%"))
        (t
         (push (list *step-counter* title :pass actual) *results*)
         (format t " → PASS~%"))))))

(defmacro defauto (title form expected-str &key check)
  ;; CHECK kept in the macro signature for backward compatibility with
  ;; the step list below — but it's now ignored: every step goes through
  ;; user confirmation so you actually see each result with your own eyes.
  (declare (ignore check))
  `(run-form-step ,title ',form ,expected-str))

;;; ── helper: mock-vtable injection for the end-to-end step ──────────────

(defun %install-mock-vtable ()
  "Swap the ibuffer vtable dynamic vars for no-op mocks so the
   %enter-ibuffer / %execute-marks flow doesn't try to dial the
   wire from an offline REPL."
  (let ((pkg (find-package '#:limn/ibuffer)))
    (set (find-symbol "*IBUFFER-WRITE-FN*" pkg)
         (lambda (b c) (declare (ignore b c))))
    (set (find-symbol "*IBUFFER-SWITCH-FN*" pkg)
         (lambda (b) (declare (ignore b))))
    (set (find-symbol "*IBUFFER-SAVE-FN*" pkg)
         (lambda (b) (declare (ignore b))))
    (set (find-symbol "*IBUFFER-KILL-FN*" pkg)
         (lambda (b)
           (handler-case (limn/buffer:unregister b) (error () nil))))
    (set (find-symbol "*IBUFFER-CURSOR-FN*" pkg)
         (lambda (b o) (declare (ignore b o))))
    (set (find-symbol "*IBUFFER-ACTIVE-BUFFER-FN*" pkg)
         (lambda () "b-prev"))))

;;; ── steps ──────────────────────────────────────────────────────────────

(format t "
我會把每一步的 form 直接 eval 給你看「預期」+「實際」。
每一步都會停下來問你 [RET]/n/s/q：
  RET = 看起來對，PASS、繼續下一步
  n   = 不對，標 FAIL
  s   = 跳過這一步
  q   = 提早結束、印報告

共 15 步。走完印一個 REPORT 區塊，整段複製給我就好。
")
(finish-output)

(catch 'quit

  (defauto "註冊 b1/b2/b3 三個假 buffer (fixture)"
    (progn
      (limn/buffer:clear-all)
      (limn/buffer:register "b1" "/tmp/zeta.txt"  "text")
      (limn/buffer:register "b2" "/tmp/alpha.pdf" "mupdf")
      (limn/buffer:register "b3" "/tmp/mid.txt"   "text")
      (sort (copy-list (limn/buffer:list-all)) #'string<))
    "(\"b1\" \"b2\" \"b3\")"
    :check (lambda (a) (equal a '("b1" "b2" "b3"))))

  (defauto "collect-rows + sort :id → ids"
    (mapcar #'limn/ibuffer:ibuffer-row-id
            (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :id))
    "(\"b1\" \"b2\" \"b3\")"
    :check (lambda (a) (equal a '("b1" "b2" "b3"))))

  (defauto "sort :path → 應依字母順 alpha < mid < zeta"
    (mapcar #'limn/ibuffer:ibuffer-row-path
            (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :path))
    "(\"/tmp/alpha.pdf\" \"/tmp/mid.txt\" \"/tmp/zeta.txt\")"
    :check (lambda (a)
             (equal a '("/tmp/alpha.pdf" "/tmp/mid.txt" "/tmp/zeta.txt"))))

  (defauto "sort :engine → mupdf < text"
    (mapcar #'limn/ibuffer:ibuffer-row-engine
            (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :engine))
    "(\"mupdf\" \"text\" \"text\")"
    :check (lambda (a) (equal a '("mupdf" "text" "text"))))

  (defauto "filter \"alpha\" 只該命中 b2"
    (mapcar #'limn/ibuffer:ibuffer-row-id
            (limn/ibuffer:filter-rows
             (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :id)
             "alpha"))
    "(\"b2\")"
    :check (lambda (a) (equal a '("b2"))))

  (defauto "filter \"\" / nil 都不該篩"
    (list (length (limn/ibuffer:filter-rows (limn/ibuffer:collect-rows) ""))
          (length (limn/ibuffer:filter-rows (limn/ibuffer:collect-rows) nil)))
    "(3 3)"
    :check (lambda (a) (equal a '(3 3))))

  (defauto "format-mark 三種寬度"
    (list (limn/ibuffer:format-mark '())
          (limn/ibuffer:format-mark (list #\D))
          (limn/ibuffer:format-mark (list #\D #\S)))
    "(\"  \" \"D \" \"DS\")"
    :check (lambda (a) (equal a '("  " "D " "DS"))))

  ;; 視覺確認的一步：故意不給 check，強制讓你看排版。
  (defauto "render 整張表 (人眼看欄位齊不齊)"
    (let* ((rows (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :id))
           (s    (limn/ibuffer:make-ibuffer-state :rows rows)))
      (limn/ibuffer:format-ibuffer-results s))
    "header 一行 + 3 個 buffer 各一行；ID 欄、ENGINE 欄、PATH 欄對齊；沒有破字。"
    :check nil)

  (defauto "mark-set 雙標、去重"
    (let ((s (limn/ibuffer:make-ibuffer-state)))
      (limn/ibuffer:mark-set s "b1" #\D)
      (limn/ibuffer:mark-set s "b1" #\D)   ; dup -> ignored
      (limn/ibuffer:mark-set s "b1" #\S)
      (limn/ibuffer:marks-of s "b1"))
    "(#\\D #\\S)"
    :check (lambda (a) (equal a '(#\D #\S))))

  (defauto "next-row wrap：0 → 1 → 2 → 0"
    (let* ((rows (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :id))
           (s    (limn/ibuffer:make-ibuffer-state :rows rows :current 0)))
      (limn/ibuffer:next-row s)
      (limn/ibuffer:next-row s)
      (limn/ibuffer:next-row s)
      (limn/ibuffer:ibuffer-state-current s))
    "0"
    :check (lambda (a) (eql a 0)))

  (defauto "prev-row wrap：0 → 2"
    (let* ((rows (limn/ibuffer:sort-rows (limn/ibuffer:collect-rows) :id))
           (s    (limn/ibuffer:make-ibuffer-state :rows rows :current 0)))
      (limn/ibuffer:prev-row s)
      (limn/ibuffer:ibuffer-state-current s))
    "2"
    :check (lambda (a) (eql a 2)))

  (defauto "ibuffer-mode 在 mode registry 中、且為 major / IBuffer"
    (let ((m (limn/mode:find-mode (find-symbol "IBUFFER-MODE" :cl-user))))
      (list (and m (limn/mode:mode-type m))
            (and m (limn/mode:mode-modeline-name m))))
    "(:MAJOR \"IBuffer\")"
    :check (lambda (a) (equal a '(:MAJOR "IBuffer"))))

  (defauto "keymap 綁的 15 個 keys (排序後)"
    (let* ((m  (limn/mode:find-mode (find-symbol "IBUFFER-MODE" :cl-user)))
           (km (limn/mode:mode-keymap m)))
      (sort (mapcar #'car (limn/keys:describe-bindings km)) #'string<))
    "(\"/\" \"<down>\" \"<up>\" \"RET\" \"S\" \"U\" \"d\" \"f\" \"g\" \"n\" \"p\" \"q\" \"s\" \"u\" \"x\")"
    :check (lambda (a)
             (equal a '("/" "<down>" "<up>" "RET" "S" "U" "d" "f" "g"
                        "n" "p" "q" "s" "u" "x"))))

  (defauto "13 個 IBUFFER-* commands 都註冊到位"
    (length
     (remove-if-not
      (lambda (c) (search "IBUFFER" (symbol-name (limn/cmd:command-name c))))
      (limn/cmd:list-commands)))
    "13"
    :check (lambda (a) (eql a 13)))

  (defauto "全流程小測：%enter + 標 b1 D + %execute → b1 真的從 registry 消失"
    (progn
      ;; 換成 mock vtable，免動 wire。
      (%install-mock-vtable)
      ;; 確保 fixture 完整 (前面的步驟可能已動過 registry)。
      (limn/buffer:clear-all)
      (limn/buffer:register "b1" "/tmp/zeta.txt"  "text")
      (limn/buffer:register "b2" "/tmp/alpha.pdf" "mupdf")
      (limn/buffer:register "b3" "/tmp/mid.txt"   "text")
      (funcall (find-symbol "%ENTER-IBUFFER"     :limn/ibuffer))
      (funcall (find-symbol "%MARK-AND-ADVANCE"  :limn/ibuffer) #\D)
      (funcall (find-symbol "%EXECUTE-MARKS"     :limn/ibuffer))
      (sort (copy-list (limn/buffer:list-all)) #'string<))
    "(\"b2\" \"b3\")   ← b1 被 D + x 真的關掉了"
    :check (lambda (a) (equal a '("b2" "b3")))))

;;; ── final report ───────────────────────────────────────────────────────

(format t "~&~%~%━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
(format t " ▼▼▼ REPORT — 整段複製貼回給 Claude ▼▼▼~%")
(format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%~%")

(let ((sorted (sort (copy-list *results*) #'< :key #'first)))
  (dolist (r sorted)
    (let ((tag (case (third r)
                 (:pass "PASS")
                 (:fail "FAIL")
                 (:skip "SKIP")
                 (:quit "QUIT")
                 (otherwise "????"))))
      (format t "[~a] step ~2,'0d  ~a~%" tag (first r) (second r))
      (when (eq (third r) :fail)
        (let ((s (with-output-to-string (out)
                   (let ((*print-pretty* nil) (*print-length* 30))
                     (prin1 (fourth r) out)))))
          (format t "       actual: ~a~%" s))))))

(let ((pass (count :pass *results* :key #'third))
      (fail (count :fail *results* :key #'third))
      (skip (count :skip *results* :key #'third))
      (quit (count :quit *results* :key #'third)))
  (format t "~%── ~d PASS / ~d FAIL / ~d SKIP / ~d QUIT  (共 ~d steps) ──~%~%"
          pass fail skip quit *step-counter*)
  (format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
  (format t " ▲▲▲ END OF REPORT ▲▲▲~%")
  (format t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━~%")
  (sb-ext:exit :code (if (zerop fail) 0 1)))
