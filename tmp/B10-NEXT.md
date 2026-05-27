# B10 — text-mode self-insert (v0.39 first item)

**Branch**: `claude/adoring-swanson-a2a23c`
**Worktree**: `/Users/jin/data/local/projects/sioyek-core/.claude/worktrees/adoring-swanson-a2a23c/`
**Status when compacted**: v0.38 ended at 22/30 PASS, 8 PARTIAL, 0 FAIL.
**Docker image**: `limn-e2e:latest` (3a04e63b7caa baked). Backend mounted via
`-v $(pwd)/backend:/limn/backend`, so Lisp changes pick up without rebuild.
C++ changes WILL need rebuild.

---

## What B10 is

**User-facing symptom**: open .txt/.org via `C-x C-f`, type characters → buffer
stays empty, save writes empty file. Typing has no effect.

**Root cause**: `limn/file:find-file` creates Lisp-side buffer in `*bufs*` hash,
but NEVER tells C++ to swap the focused window to this buffer. Qt focus stays
on the PDF widget or chrome bar. Keystroke events route through that focused
widget → mode-stack-lookup for "w1" returns pdf-mode (or whatever was active),
not text-mode → text-mode's self-insert binding is never consulted → keystrokes
fall on the floor.

## Concrete chain (each step verified during v0.38 trace work)

```
1. (limn/file:find-file "/tmp/x.txt")
   → creates fbuf struct in limn/file::*bufs*
   → registers (path → id) in *by-path*
   → returns "limn-file-buf-1"
   ← but C++ has NO IDEA this buffer exists
2. xdotool key h
   → Qt KeyEvent on whatever-is-focused (= PDF widget)
   → C++ push_event {key:"h", mods:[]} on wire
3. Lisp %dispatch-key
   → spec = "h"
   → mode-buffer-for-window "w1" → returns pdf-mode buffer (NOT text)
   → lookup "h" in pdf-mode-map → not bound → nothing fires
4. Buffer content stays ""
```

## The 3-layer fix

### Lisp side (`backend/limn-file.lisp`)

After successful `find-file`, send a wire cmd telling C++ "register this
buffer as text-engine + swap window w1 to it". Probably:

```lisp
(when (and (not (eq kind :pdf)) success)
  (ignore-errors
    (limn:call "buffer/open-text"
               :|buffer-id| id
               :|path| abs
               :|content| content
               :|win-id| "w1")))
```

(name TBD — see wire schema below)

### Wire schema (new cmd or extend existing)

**Option A** (cleanest): new cmd `buffer/open-text`
```
{cmd: "buffer/open-text", buffer-id: "...", path: "...",
 content: "...", win-id: "w1"}
→ ok / err
```

**Option B**: extend `bridge/engine-load` with `engine: "text"`. Currently it's
mupdf-only. Need to gate the mupdf-specific code paths.

Recommend **Option A** — less risk to existing PDF path.

### C++ side (`sioyek/pdf_viewer/limn_command.cpp`)

Add `cmd_buffer_open_text` handler that:

1. Allocate / look-up the buffer-id in `text_buffers` registry (text_buffers is
   `QMap<QString, TextBufferState>` somewhere — `grep text_buffers` shows it).
2. Store the content into the TextBufferState.
3. Set `win->buffer_id = buffer_id` for the named win-id.
4. If win is active: `sync_text_widget(buffer_id)` + `main_widget->show_text_view()`.
   This code already exists in `cmd_view_set`'s text branch (line ~565ish),
   reuse it.
5. Emit `event/buffer-opened` with `engine="text"`, `buffer-id`, `path`,
   `frame-id="f1"` — Lisp's text-mode auto-activate hook subscribes to this
   and registers the mode-buffer.

After C++ change: `scripts/build-docker.sh` to rebuild image.

## How to verify

The 8 workflows below should go PARTIAL→PASS:

| W | Test driver | What it does |
|---|------------|-----|
| W13 | tmp/w13-driver.lisp | PDF select + M-w + C-y to .org + save |
| W14 | tmp/w14-driver.lisp | C-x C-f new .org + type 10 lines + save + reopen |
| W15 | tmp/w15-driver.lisp | Open existing .org + type bullet + save |
| W16 | tmp/w16-driver.lisp | CJK content edit |
| W17 | tmp/w17-driver.lisp | Kill region in A, yank in B |
| W20 (D.2) | tmp/w20-driver.lisp | Type "hello" + save |

Run individually:
```bash
docker run --rm -v "$(pwd)/tmp:/host-tmp" -v "$(pwd)/backend:/limn/backend" \
  --entrypoint "" limn-e2e:latest bash -c '
  rm -f /tmp/.limn/init.lisp; rm -rf /root/.limn;
  nix develop /limn#docker --command /usr/local/bin/container-entry.sh \
  sbcl --no-userinit --no-sysinit --non-interactive --load /host-tmp/w14-driver.lisp
' 2>&1 | grep -E "✓|✗|result"
```

Batch all 30 after fix lands:
```bash
bash tmp/rerun-all.sh
```

After Lisp+C++ change + docker rebuild, expected final tally:
**~28/30 PASS**, with W04 (TOC deadlock — separate) and W30 (auto-revert event
loop — B17, separate) the remaining PARTIAL.

## Related dependencies / dragons

- **B9** (limn/file `*bufs*` vs wire buffer/list namespace split). B10 fix
  partially closes this — once find-file syncs to wire, the namespaces align
  for text buffers. But PDF buffers still go through a different path
  (`bridge/engine-load` registers in C++ registry directly, then emits
  buffer-opened which the Lisp side just reacts to). The two paths should
  unify but that's bigger work.

- **B6** flake (stack-smashing). Affects roughly 5-10% of runs. Not caused
  by our changes. Just retry the workflow once.

- **W04 deadlock**: pdf-toc → completing-read → blocks on minibuffer-read +
  driver's safe-call competing for bridge socket. NOT B10. Separate fix:
  main event-loop redesign (related to B17).

## Project conventions to honor

- Every fix needs regression test per [[feedback-fix-discipline]]:
  - Lisp-only → `backend/tests/unit/`
  - Wire round-trip → `backend/tests/suites/`
  - Real keystrokes → `backend/tests/e2e/` (but for B10 the existing
    `tmp/w*-driver.lisp` already covers this)
- Commit message style: see recent commits like `1947d96 v0.38 B13 fix:...`
- Build alignment: rebuild docker image after C++ change. Verify git hash in
  `limn --version` matches HEAD.
- Don't touch `flake.nix` without `deps:` prefix in commit message.

## Where to start (when uncompacted)

1. Read this file
2. `git log --oneline | head -20` — see v0.38 work
3. `cat tmp/v038-verify-summary.md` — current tally + remaining list
4. Open `backend/limn-file.lisp:147` (find-file impl, recently fixed B8)
5. Open `sioyek/pdf_viewer/limn_command.cpp` and grep `text_buffers`,
   `cmd_view_set` to understand C++ side
6. Sketch the wire schema decision (Option A vs B above), confirm with user
7. Start with the Lisp side stub (wire call after find-file)
8. Then C++ handler
9. Rebuild docker
10. Run w14-driver to verify
11. If green, rerun batch + commit
