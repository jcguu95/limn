# v0.38 Verification Pass — 9 fix 後重跑全 30 workflow

Run timestamp: 2026-05-26T~07:30 (post B5 fix)
git: $(git rev-parse --short=12 HEAD)

## Category Transitions

|        | Before (pre-fix) | After (9 fixes) | Δ |
|--------|----|----|----|
| PASS   | 10 | 12 | +2 |
| PARTIAL| 15 | 16 | +1 |
| FAIL   |  5 |  2 | -3 |

## Assertion Totals
- Pre-fix:  61 / 95 pass (64.2%)
- Post-fix: 71 / 95 pass (74.7%)
- Δ: +10 assertions on same 95-assertion total

## Notable transitions (W## category jumps)

| W## | Before | After | Driver |
|-----|--------|-------|--------|
| W04 | FAIL 0/3 | PARTIAL 1/3 | B14 (pdf-toc → completing-read) |
| W09 | FAIL 0/4 | PARTIAL 1/4 | B6 less flaky this run |
| W10 | PARTIAL 1/4 | PASS 4/4 | B6 stable + general fixes |
| W24 | FAIL 0/1 | PASS 1/1 | B18 (*pdf-default-zoom*) |

## Remaining hard FAILs (2 → both B7-blocked)
- W23 — defun + leader binding 不 dispatch
- W25 — which-key prefix 不 dispatch

## Remaining PARTIAL drivers (16) — root cause distribution
- **B7** map! :mode/:leader dispatch: W22 (v不fire), and contributing to W23/W25
- **B10** text-mode self-insert: W14-W19 全部 1/2 (file open OK, typing 沒進去)
- **B16** sidecar 沒寫 disk: W08/W11/W12 silent
- **B17** auto-revert: W30 file-notify 不 fire
- **B6** stack smashing flake: W09 multi-step annotation 死
- 小 issue: W01 SPC 沒綁、W02 vim key gap、W04 TOC interaction、W20 W28
