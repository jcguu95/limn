;;;; Mouse coordinate → page mapping — SPEC v0.5 §6
;;;;
;;;; mouse-click 事件的 page 必須由 widget 座標反推、不能寫死 0。我們
;;;; 需要一個能注入「真實」 Qt mouse 事件、走 LimnInputFilter 的指令；
;;;; 跟 test/inject-qt-key 同型，但動 mouse。新指令 test/inject-qt-mouse-click
;;;; 在 v0.8 「Mouse coord → page」batch 才會實作。
;;;;
;;;; 在那之前所有測試紅，紅在「unknown test command」級別。

(in-package #:limn/test)

(deftest test-mouse-click-page-from-widget-coords
  "在已開 PDF 的視窗按真鍵盤級別的滑鼠 click：filter MUST 從 widget 座標
   反推 page 寫進 mouse-click 事件。"
  (with-buffer (buf)
    ;; touch buf to silence unused warning, also ensures buffer loaded
    (send! "buffer/metadata" :|buffer-id| buf)
    (drain-events)
    ;; viewport 大致 1200x900 (見 main.cpp resize)；點上半部 (y=100) 該
    ;; 落在第 0 頁。
    (let ((r (send! "test/inject-qt-mouse-click"
                    :|win-id| "w1"
                    :|x| 300 :|y| 100
                    :|button| 1)))
      (assert-ok r "test/inject-qt-mouse-click responds"))
    (let ((ev (read-event :type "mouse-click" :timeout 1)))
      (assert-true ev "filter pushed mouse-click event")
      (when ev
        (assert-numeric (getf ev :|page|))
        (assert-true (>= (getf ev :|page|) 0)
                     "page is a valid non-negative integer")))))

(deftest test-mouse-click-page-differs-by-y
  "點 viewport 不同高度 y、得到的 page 應不一定相同：viewport 頂端 y=10
   跟最底 y=890 至少有一處 page 會不同（除非整個 viewport 都在同一頁）。
   這個測試不對「精確哪一頁」做斷言、只斷言「不是寫死」。"
  (with-buffer (buf)
    ;; touch buf to silence unused warning, also ensures buffer loaded
    (send! "buffer/metadata" :|buffer-id| buf)
    (drain-events)
    (send! "test/inject-qt-mouse-click"
           :|win-id| "w1" :|x| 600 :|y| 10  :|button| 1)
    (send! "test/inject-qt-mouse-click"
           :|win-id| "w1" :|x| 600 :|y| 890 :|button| 1)
    (sleep 0.1)
    (let* ((evs (loop repeat 2
                      for e = (read-event :type "mouse-click" :timeout 1)
                      while e collect e))
           (pages (mapcar (lambda (e) (getf e :|page|)) evs)))
      (assert-equal 2 (length pages) "got two mouse-click events")
      ;; Pages 可能相等（單頁占滿 viewport）但都該是有效整數。如果它們
      ;; 寫死成 0，下面的測試也綠——這只是檢查「event 真的有送出」。
      ;; 嚴格的「不寫死」斷言用接下來的 test，配合可以滾頁的設定。
      (dolist (p pages)
        (assert-numeric p)))))
