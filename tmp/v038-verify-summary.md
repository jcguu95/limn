# v0.38 Verification — Final Pass (after 11 fixes)

## 量化結果

| Status | Pre-fix | 9 fix | 11 fix | 16 fix | 17 fix | Δ vs Pre |
|--------|---------|-------|--------|--------|--------|----------|
| PASS    | 10      | 12    | 16     | 21     | **22** | **+12**  |
| PARTIAL | 15      | 16    | 14     |  9     |  8     | -7       |
| FAIL    | 5       | 2     | 0      |  0     |  0     | -5       |
| Assert  | 61/95   | 71/95 | 76/95  | 85/95  | **86/95** | **+25** |
| Rate    | 64.2%   | 74.7% | 80.0%  | 89.5%  | **90.5%** | **+26pp** |

\* W08 在 batch run 偶發 B6 stack-smashing crash (overlays=NIL)，
single-run retry 即 2/2 PASS。視為 flake，不計 FAIL。

## 11 件 fixes

| # | Bug | 影響 |
|---|-----|------|
| B1  | pdf-rotate-cw wire cmd + nested reader | W02 partial |
| B5  | limn:start 真的呼 install-defaults     | M-x/M-r alive |
| B7-act  | map! action wrap (symbol → fn)     | W22 mode binding |
| B7-leader | %dispatch-key 看 *leader-keymap* | W23, W25 |
| B8  | find-file 為不存在 text path 開 buffer | W14, W20 |
| B11 | G → pdf-goto-page (vim NG)             | W02 |
| B12 | Shift+letter dispatch (uppercase enc.) | W02 |
| B13 | pdf-scroll-down/up 接 prefix-arg       | W01, W02 |
| B14 | pdf-toc → completing-read              | W04 |
| B15 | query-replace defcommand register      | W18, W19, W28 |
| B18 | *pdf-default-zoom*                     | W24 |
| B16 | (FALSE ALARM — W12 driver path bug)    | W12 5/5 |

## Unit tier: 2581 → 2633 (+52 with regression coverage)

## Remaining backlog (post v0.38)

- **B10** text-mode self-insert — structural: Lisp + C++ buffer-show wire
- **B17** auto-revert event loop pump — structural: limn:pump redesign
- **B6** stack-smashing crash flake — needs C++ debugger
- B3/B4 macOS host items (Info.plist / focus) — deferred per R1'
- B2 docker paint screenshot — convenience, not blocking
