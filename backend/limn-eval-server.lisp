;;;; limn-eval-server — Unix-domain socket eval server，供 limn-client 連線。
;;;;
;;;; 提供一個 socket listener，讓外部（終端機/script/其他程式）可以連到正在跑的
;;;; limn SBCL backend，注入 Lisp form 並取回 eval 結果。
;;;;
;;;; 使用方式：
;;;;   (limn/eval-server:start-server)    → 在 /tmp/limn-eval.sock 起 server
;;;;   (limn/eval-server:stop-server)     → 關閉 server
;;;;   (limn/eval-server:server-running-p) → 查詢狀態
;;;;
;;;; Socket 路徑：預設 /tmp/limn-eval.sock，可透過 LIMN_EVAL_SOCK 環境變數自訂。
;;;; 這是跨平台（Linux/macOS）的 /tmp 路徑，不依賴 Linux 特有機制。
;;;;
;;;; 協議（簡單一行一 form）：
;;;;   Client → Server: 送一個 Lisp form 字串（單行），以換行結尾
;;;;   Server → Client: 先送 eval 期間 *standard-output* 的輸出（逐行原樣），
;;;;                    最後一行是 eval 結果（prin1 格式）或 "ERROR:<訊息>"
;;;;   Server 隨後關閉連線（one-shot，如 emacsclient --eval）
;;;;
;;;; Thread-safety：先走簡單做法 (a) —— listener thread 直接 eval，不做
;;;; safe-point queue。這是 dev 工具，競爭風險可接受。

(defpackage #:limn/eval-server
  (:use #:cl #:sb-bsd-sockets #:sb-thread)
  (:export #:start-server #:stop-server #:server-running-p
           #:*socket-path* #:default-socket-path
           ;; client 端 helper，供測試與 CLI script 用
           #:send-form))

(in-package #:limn/eval-server)

;;; ── socket path ──────────────────────────────────────────────────

(defun default-socket-path ()
  "預設 socket 路徑。先查環境變數 LIMN_EVAL_SOCK，否則用 /tmp/limn-eval.sock。
   這是跨平台（Linux/macOS）安全的路徑。"
  (or (sb-ext:posix-getenv "LIMN_EVAL_SOCK")
      "/tmp/limn-eval.sock"))

(defvar *socket-path* nil
  "當前 eval-server 實際使用的 socket 路徑。start-server 後即有值。")

;;; ── server state ─────────────────────────────────────────────────

(defvar *listener-socket* nil)
(defvar *listener-thread* nil)
(defvar *server-lock* (sb-thread:make-mutex :name "eval-server"))

(defun server-running-p ()
  "查詢 eval-server 是否正在 listen。"
  (sb-thread:with-mutex (*server-lock*)
    (%server-running-p)))

(defun %server-running-p ()
  "內部用：不加鎖的 running-p 檢查。呼叫者需自行確保互斥。"
  (and *listener-socket* *listener-thread*
       (sb-thread:thread-alive-p *listener-thread*)))

;;; ── connection handler ───────────────────────────────────────────

(defun %handle-connection (client-socket)
  "處理單一 client 連線：讀一個 form → eval → 回傳結果與 stdout。
   所有 stdout 輸出先寫回 client，最後一行為 eval 結果（prin1）或錯誤訊息。"
  (let ((stream (socket-make-stream client-socket
                                     :element-type 'character
                                     :input t :output t
                                     :buffering :line
                                     :external-format :utf-8))
        ;;  擷取 eval 期間寫到 *standard-output* 的內容
        (*standard-output* (make-string-output-stream)))
    (unwind-protect
         (handler-case
             (let* ((form-line (read-line stream nil :eof))
                    (form-str  (if (eq form-line :eof) "" form-line)))
               ;; 去除前後空白；若為空字串，視為 NIL
               (let ((trimmed (string-trim " " form-str)))
                 (if (zerop (length trimmed))
                     (progn
                       (format stream "NIL~%")
                       (force-output stream))
                     (let* ((form    (read-from-string trimmed))
                            (results (multiple-value-list (eval form))))
                       ;; 先輸出 stdout（確保與後續結果分行）
                       (let ((out (get-output-stream-string *standard-output*)))
                         (unless (zerop (length out))
                           (write-string out stream)
                           ;; 若 stdout 結尾不是換行，補一個換行以分隔結果
                           (unless (char= (char out (1- (length out))) #\Newline)
                             (write-char #\Newline stream))))
                       ;; 再輸出 eval 結果（多值以 "; " 分隔，prin1 格式）
                       (format stream "~{~s~^; ~}~%" results)
                       (force-output stream)))))
           (error (c)
             ;; stdout 先輸出，再輸出錯誤
             (let ((out (get-output-stream-string *standard-output*)))
               (unless (zerop (length out))
                 (write-string out stream)
                 (unless (char= (char out (1- (length out))) #\Newline)
                   (write-char #\Newline stream))))
             (format stream "ERROR:~a~%" c)
             (force-output stream)))
      (ignore-errors (close stream))
      (ignore-errors (socket-close client-socket)))))

;;; ── listener thread ──────────────────────────────────────────────

(defun %listener-loop (listen-sock)
  "Accept 迴圈：阻塞等待新連線，每條連線在當前 thread 直接 eval（簡單做法(a)）。
   當 listen-sock 被 stop-server 關閉時，socket-accept 會拋出 socket-error，
   捕捉後跳出迴圈。"
  (loop
    (handler-case
        (let ((client (socket-accept listen-sock)))
          (%handle-connection client))
      ;;  listener socket 被關閉 → 正常退出
      (sb-bsd-sockets:socket-error (c)
        (declare (ignore c))
        (return))
      (error (c)
        ;;  其他意外錯誤：印到 *error-output* 並繼續
        (format *error-output* ";; eval-server listener error: ~a~%" c)
        (sleep 0.1)))))

;;; ── public API ───────────────────────────────────────────────────

(defun start-server (&key (path (default-socket-path)) force)
  "啟動 eval-server，在 PATH 建立 unix domain socket 並開始 listen。
   若 PATH 已存在且 FORCE 為真，先刪除舊 socket 再重新 bind。
   若已在執行中：FORCE 為真時先 stop 再 start；否則直接回傳現有 *socket-path*。
   回傳實際使用的 socket 路徑。"
  (sb-thread:with-mutex (*server-lock*)
    (when (%server-running-p)
      (if force
          (%stop-server)
          (return-from start-server *socket-path*)))
    ;; 清理舊 socket 檔案（bind 前必須刪除已存在的檔案）
    (when (probe-file path)
      (delete-file path))
    ;; bind + listen
    (let ((sock (make-instance 'local-socket :type :stream)))
      (socket-bind sock path)
      (socket-listen sock 5)
      (setf *listener-socket* sock
            *socket-path* path)
      (setf *listener-thread*
            (sb-thread:make-thread
             (lambda () (%listener-loop sock))
             :name "limn-eval-server"))
      path)))

(defun stop-server ()
  "關閉 eval-server：關閉 listener socket → 等待 listener thread 結束 →
   清理 socket 檔案。"
  (sb-thread:with-mutex (*server-lock*)
    (%stop-server)))

(defun %stop-server ()
  "內部用：不加鎖的 stop。呼叫者需自行確保互斥。"
  (when *listener-socket*
    (ignore-errors (socket-close *listener-socket*))
    (setf *listener-socket* nil))
  (when *listener-thread*
    (when (sb-thread:thread-alive-p *listener-thread*)
      (handler-case
          (sb-thread:join-thread *listener-thread* :timeout 1)
        (error ())))
    (setf *listener-thread* nil))
  (when (and *socket-path* (probe-file *socket-path*))
    (ignore-errors (delete-file *socket-path*)))
  (setf *socket-path* nil)
  t)

;;; ── client helper（給測試與 CLI script 用）─────────────────────

(defun send-form (socket-path form-string &key (retry 10) (delay 0.05))
  "連到 SOCKET-PATH，送 FORM-STRING，讀回所有回應行並以字串回傳。
   這是一個同步、one-shot 的 client 端 helper。
   RETRY 次重試連線（server 可能還在啟動中），每次間隔 DELAY 秒。
   回傳值為伺服器回應的全部文字（含換行）。"
  (loop repeat retry
        for sock = (handler-case
                       (let ((s (make-instance 'local-socket :type :stream)))
                         (socket-connect s socket-path)
                         s)
                     (error () nil))
        when sock
        return
        (unwind-protect
             (let ((stream (socket-make-stream sock
                                                :element-type 'character
                                                :input t :output t
                                                :buffering :line
                                                :external-format :utf-8)))
               (unwind-protect
                    (progn
                      (write-line form-string stream)
                      (force-output stream)
                      ;; 讀回所有回應行
                      (with-output-to-string (out)
                        (loop for line = (read-line stream nil :eof)
                              until (eq line :eof)
                              do (write-line line out))))
                 (ignore-errors (close stream))))
          (ignore-errors (socket-close sock)))
        ;; 尚未成功連線：等一等再重試
        do (sleep delay)
        finally (error "limn/eval-server: could not connect to ~a after ~a attempts"
                       socket-path retry)))
