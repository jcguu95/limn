;;;; eval-server 的純 Lisp 單元測試。
;;;;
;;;; 測試 eval-server 的完整流程：起 server → client 連線送 form → 驗證回應，
;;;; 全部 headless、不依賴外部工具（只用 sb-bsd-sockets）。
;;;;
;;;; 測試項目：
;;;;   1. 基本 eval： (+ 1 2) → "3"
;;;;   2. 查 limn 狀態： (limn/buffer:count-buffers) → "0"
;;;;   3. eval 會 error 的 form → 回應以 "ERROR:" 開頭
;;;;   4. server 生命週期：start → running-p → stop → not running-p

(in-package #:limn/unit-test)

;;; ── helpers ──────────────────────────────────────────────────────

(defvar *test-socket* "/tmp/limn-eval-test.sock"
  "測試用的獨立 socket 路徑，不跟正式 server 搶。")

(defun %start-test-server ()
  "啟動測試用的 eval-server，等待 socket 就緒後回傳路徑。"
  (let ((path (limn/eval-server:start-server :path *test-socket* :force t)))
    ;; 等待 socket 檔案出現（start-server 內已 bind，但做 double-check）
    (loop repeat 20
          until (probe-file path)
          do (sleep 0.05)
          finally (unless (probe-file path)
                    (error "測試 server socket 未出現: ~a" path)))
    path))

(defun %stop-test-server ()
  "關閉測試 server 並清理 socket 檔案。"
  (limn/eval-server:stop-server)
  (when (probe-file *test-socket*)
    (delete-file *test-socket*)))

(defun %eval-send (form-string)
  "送 form 到測試 server，回傳回應字串（去除尾端換行方便比對）。"
  (string-right-trim '(#\Newline #\Return)
                     (limn/eval-server:send-form *test-socket* form-string)))

(defun %response-ok? (response)
  "回應是否為成功（不含 ERROR: 前綴）。"
  (not (search "ERROR:" response)))

(defun %last-line (response)
  "取回應的最後一行（以換行分隔）。"
  (let ((pos (position #\Newline response :from-end t)))
    (if pos
        (string-trim '(#\Newline #\Return) (subseq response (1+ pos)))
        (string-trim '(#\Newline #\Return) response))))

;;; ── 測試：server 生命週期 ─────────────────────────────────────────

(deftest eval-server-lifecycle
  "server 可以正常啟動、查詢執行中、停止。"
  ;; 確保沒有殘留
  (when (probe-file *test-socket*)
    (delete-file *test-socket*))
  (assert-false (limn/eval-server:server-running-p)
                "啟動前 server-running-p 為 false")
  (%start-test-server)
  (unwind-protect
       (progn
         (assert-true (limn/eval-server:server-running-p)
                      "啟動後 server-running-p 為 true")
         (assert-true (probe-file *test-socket*)
                      "socket 檔案存在"))
    (%stop-test-server))
  (assert-false (limn/eval-server:server-running-p)
                "停止後 server-running-p 為 false")
  (assert-false (probe-file *test-socket*)
                "停止後 socket 檔案已清除"))

;;; ── 測試：基本 eval ──────────────────────────────────────────────

(deftest eval-server-basic-eval
  "eval (+ 1 2) → 回應最後一行為 \"3\"。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (let ((resp (%eval-send "(+ 1 2)")))
         (assert-true (%response-ok? resp)
                      "eval (+ 1 2) 成功（非 ERROR）")
         (assert-equal "3" (%last-line resp)
                       "eval (+ 1 2) 結果為 3"))
    (%stop-test-server)))

(deftest eval-server-nested-arithmetic
  "eval 較複雜的算式。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (let ((resp (%eval-send "(* (+ 1 2) 4)")))
         (assert-true (%response-ok? resp)
                      "eval (* (+ 1 2) 4) 成功")
         (assert-equal "12" (%last-line resp)
                       "eval (* (+ 1 2) 4) 結果為 12"))
    (%stop-test-server)))

(deftest eval-server-string-result
  "eval 回傳字串的 form。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (let ((resp (%eval-send "\"hello\"")))
         (assert-true (%response-ok? resp)
                      "eval \"hello\" 成功")
         (assert-equal "\"hello\"" (%last-line resp)
                       "eval \"hello\" 結果為 \"hello\""))
    (%stop-test-server)))

(deftest eval-server-nil-result
  "eval 回傳 NIL 的 form。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (let ((resp (%eval-send "(list)")))
         (assert-true (%response-ok? resp)
                      "eval (list) 成功")
         (assert-equal "NIL" (%last-line resp)
                       "eval (list) 結果為 NIL"))
    (%stop-test-server)))

(deftest eval-server-multiple-values
  "eval 多值的 form： (values 1 2 3) → \"1; 2; 3\"。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (let ((resp (%eval-send "(values 1 2 3)")))
         (assert-true (%response-ok? resp)
                      "eval (values 1 2 3) 成功")
         (assert-equal "1; 2; 3" (%last-line resp)
                       "eval (values 1 2 3) 結果為 \"1; 2; 3\""))
    (%stop-test-server)))

;;; ── 測試：查 limn 狀態 ───────────────────────────────────────────

(deftest eval-server-query-limn-state
  "eval 查詢 limn 內部狀態的 form，驗證回傳合理值。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (progn
         ;; 查 buffer 數量（單元測試中無 buffer，應為 0）
         (let ((resp (%eval-send "(limn/buffer:count-buffers)")))
           (assert-true (%response-ok? resp)
                        "eval (limn/buffer:count-buffers) 成功")
           (assert-equal "0" (%last-line resp)
                         "buffer 數量為 0"))
         ;; 查 limn package 存在
         (let ((resp (%eval-send "(find-package :limn)")))
           (assert-true (%response-ok? resp)
                        "eval (find-package :limn) 成功")
           (assert-true (search "LIMN" (%last-line resp))
                        "find-package :limn 回傳 LIMN package")))
    (%stop-test-server)))

;;; ── 測試：error 處理 ─────────────────────────────────────────────

(deftest eval-server-signals-error
  "eval 一個會丟 error 的 form → 回應以 ERROR: 開頭。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (let ((resp (%eval-send "(error \"test error from eval-server\")")))
         (assert-false (%response-ok? resp)
                       "eval (error ...) 回傳 ERROR 狀態")
         (assert-true (search "ERROR:" resp)
                      "回應包含 ERROR: 前綴")
         (assert-true (search "test error from eval-server" resp)
                      "錯誤訊息包含原始 error 文字"))
    (%stop-test-server)))

(deftest eval-server-parse-error
  "eval 一個語法錯誤的 form（括號不平衡）→ 回應以 ERROR: 開頭。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (let ((resp (%eval-send "(+ 1 2")))
         (assert-false (%response-ok? resp)
                       "語法錯誤的 form 回傳 ERROR 狀態")
         (assert-true (search "ERROR:" resp)
                      "語法錯誤回應包含 ERROR: 前綴"))
    (%stop-test-server)))

(deftest eval-server-empty-form
  "送空字串 → server 應回傳 NIL 而非崩潰。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (let ((resp (%eval-send "")))
         (assert-true (%response-ok? resp)
                      "空 form 回傳成功")
         (assert-equal "NIL" (%last-line resp)
                       "空 form 結果為 NIL"))
    (%stop-test-server)))

;;; ── 測試：stdout 擷取 ────────────────────────────────────────────

(deftest eval-server-captures-stdout
  "eval 期間寫到 *standard-output* 的內容會被擷取並回傳。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (let* ((form "(progn (princ \"hello stdout\") 42)")
              (resp (%eval-send form)))
         (assert-true (%response-ok? resp)
                      "eval (princ ...) 成功")
         (assert-true (search "hello stdout" resp)
                      "回應包含 stdout 輸出 \"hello stdout\"")
         (assert-equal "42" (%last-line resp)
                       "最後一行為 eval 結果 42"))
    (%stop-test-server)))

;;; ── 測試：concurrent connections ─────────────────────────────────

(deftest eval-server-multiple-connections
  "多次連線應各自正確處理，不互相干擾。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (progn
         (assert-equal "3" (%last-line (%eval-send "(+ 1 2)"))
                       "第一次連線 (+ 1 2) → 3")
         (assert-equal "42" (%last-line (%eval-send "(* 6 7)"))
                       "第二次連線 (* 6 7) → 42")
         (assert-equal "99" (%last-line (%eval-send "(+ 50 49)"))
                       "第三次連線 (+ 50 49) → 99"))
    (%stop-test-server)))

;;; ── 測試：真正 exec CLI script ───────────────────────────────────

(defun %run-cli (form)
  "透過 sb-ext:run-program 執行 scripts/limn-client --eval FORM，
   回傳 stdout 字串（含換行）。"
  (let* ((repo-root (merge-pathnames "../../../"
                                     (or *load-pathname*
                                         *default-pathname-defaults*)))
         ;; merge-pathnames 會繼承 repo-root 的 .lisp type，需手動清除
         (cli-path (make-pathname :defaults (merge-pathnames "scripts/limn-client" repo-root)
                                  :type nil))
         (proc (sb-ext:run-program "/usr/bin/env"
                                   (list "bash" (namestring cli-path)
                                         "--socket" *test-socket*
                                         "--eval" form)
                                   :output :stream
                                   :error :output
                                   :wait t
                                   :search t))
         (out (make-string-output-stream)))
    (loop for line = (read-line (sb-ext:process-output proc) nil :eof)
          until (eq line :eof)
          do (write-line line out))
    (get-output-stream-string out)))

(defun %cli-last-line (output)
  "取 CLI output 的最後一行（不含空白行）。"
  (let* ((stripped (string-right-trim '(#\Newline #\Return #\Space) output))
         (pos (position #\Newline stripped :from-end t)))
    (if pos
        (string-trim " " (subseq stripped (1+ pos)))
        stripped)))

(deftest eval-server-cli-exec
  "真正 exec scripts/limn-client，驗證 CLI 路徑可用。"
  (when (probe-file *test-socket*) (delete-file *test-socket*))
  (%start-test-server)
  (unwind-protect
       (progn
         ;; basic eval
         (let ((out (%run-cli "(+ 1 2)")))
           (assert-true (> (length out) 0)
                        "CLI exec (+ 1 2) 有輸出")
           (assert-equal "3" (%cli-last-line out)
                         "CLI exec (+ 1 2) 最後一行為 3"))
         ;; error form
         (let ((out (%run-cli "(error \"cli-test-err\")")))
           (assert-true (search "ERROR:" out)
                        "CLI exec error form 回應包含 ERROR:")
           (assert-true (search "cli-test-err" out)
                        "CLI exec error form 回應包含原始錯誤訊息"))
         ;; limn state query
         (let ((out (%run-cli "(limn/buffer:count-buffers)")))
           (assert-equal "0" (%cli-last-line out)
                         "CLI exec buffer-count 為 0")))
    (%stop-test-server)))
