#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
loop.py —— limn thin agent loop（路 2：Claude 當介面、DeepSeek 做髒活）。

設計（對照 meta/README.md / meta/loop/README.md）：
  - 我（Claude）寫一份 brief（任務 + 驗收標準），呼叫本檔。
  - 本檔用 DeepSeek 的 function-calling 跑一個 agent 迴圈：DeepSeek 自由探索
    /workspace（limn repo 的 clone）、讀檔、grep、改檔、跑 build/測試，直到
    它呼叫 finish。**探索全自主，但死鎖在這個 repo 內。**
  - 檔案操作直接在 host workspace 上做（workspace 是沙箱的 bind-mount，改 host
    等於改容器內 /workspace）→ 快、無 shell escaping。
  - run_command + 驗證走 `docker exec` 進沙箱（拿 Linux/nix 工具鏈）。
  - 全程 transcript 落 jsonl；最後跑標準驗證、寫 status.json。
  - 我只讀 status.json，不讀 DeepSeek 的 chain-of-thought。

只用 Python 標準函式庫（urllib/json/subprocess…），host 上任何 python3 可跑。
"""
import argparse, json, os, re, subprocess, sys, time, urllib.request, urllib.error
from pathlib import Path

MAX_TOOL_OUTPUT = 6000        # 工具結果截斷，避免灌爆 DeepSeek context
DEFAULT_CMD_TIMEOUT = 900     # run_command / 驗證的逾時（秒）

# ─────────────────────────── DeepSeek key ────────────────────────────
def read_deepseek_key():
    p = Path.home() / ".authinfo"
    if not p.exists():
        sys.exit("錯誤：找不到 ~/.authinfo")
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        if "deepseek.api" in line.lower():
            toks = line.split()
            for i, t in enumerate(toks):
                if t == "password" and i + 1 < len(toks):
                    return toks[i + 1]
    sys.exit("錯誤：~/.authinfo 找不到 deepseek.api 的 password 欄位")

# ─────────────────────────── 工具實作 ────────────────────────────────
class Tools:
    def __init__(self, workspace_host: Path, container: str, cmd_timeout: int):
        self.ws = workspace_host.resolve()
        self.container = container
        self.cmd_timeout = cmd_timeout

    def _safe(self, rel: str) -> Path:
        """把路徑釘在 workspace 內，擋住 ../ 逃逸。
        接受 DeepSeek 常給的 /workspace/... 或前導 / —— 一律當成相對 workspace
        （絕對路徑會被強制收進沙箱，安全）。"""
        rel = (rel or ".").strip()
        if rel == "/workspace":
            rel = "."
        elif rel.startswith("/workspace/"):
            rel = rel[len("/workspace/"):]
        rel = rel.lstrip("/")
        target = (self.ws / rel).resolve()
        if self.ws != target and self.ws not in target.parents:
            raise ValueError(f"路徑逃出 workspace：{rel}")
        return target

    def list_dir(self, path="."):
        d = self._safe(path)
        if not d.exists():
            return f"(不存在：{path})"
        if d.is_file():
            return f"{path} 是檔案，不是目錄"
        out = []
        for entry in sorted(d.iterdir()):
            tag = "/" if entry.is_dir() else ""
            out.append(entry.name + tag)
        return "\n".join(out) or "(空目錄)"

    def read_file(self, path, start=None, end=None):
        f = self._safe(path)
        if not f.exists() or not f.is_file():
            return f"(不存在或非檔案：{path})"
        lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        s = (start or 1) - 1
        e = end or len(lines)
        s = max(0, s); e = min(len(lines), e)
        chunk = "\n".join(f"{i+1}\t{lines[i]}" for i in range(s, e))
        return chunk[:MAX_TOOL_OUTPUT] or "(空檔案)"

    def grep(self, pattern, path="."):
        d = self._safe(path)
        try:
            r = subprocess.run(["grep", "-rIn", "--", pattern, str(d)],
                               capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            return "(grep 逾時)"
        out = r.stdout.replace(str(self.ws) + "/", "")
        return out[:MAX_TOOL_OUTPUT] or "(無匹配)"

    def write_file(self, path, content):
        f = self._safe(path)
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(content, encoding="utf-8")
        return f"已寫入 {path}（{len(content)} bytes）"

    def str_replace(self, path, old, new):
        f = self._safe(path)
        if not f.exists():
            return f"(不存在：{path})"
        txt = f.read_text(encoding="utf-8", errors="replace")
        n = txt.count(old)
        if n == 0:
            return "錯誤：old 字串在檔案中找不到（要逐字相符，含縮排）"
        if n > 1:
            return f"錯誤：old 字串出現 {n} 次、不唯一，請給更長的上下文"
        f.write_text(txt.replace(old, new), encoding="utf-8")
        return f"已替換 {path}（1 處）"

    def run_command(self, command):
        """在沙箱 /workspace 內跑指令（Linux/nix 工具鏈）。"""
        try:
            r = subprocess.run(
                ["docker", "exec", "-w", "/workspace", self.container,
                 "bash", "-lc", command],
                capture_output=True, text=True, timeout=self.cmd_timeout)
        except subprocess.TimeoutExpired:
            return f"(指令逾時 {self.cmd_timeout}s)"
        out = (r.stdout or "") + (("\n[stderr]\n" + r.stderr) if r.stderr else "")
        head = f"[exit={r.returncode}]\n"
        if len(out) > MAX_TOOL_OUTPUT:
            out = out[:MAX_TOOL_OUTPUT // 2] + "\n...(截斷)...\n" + out[-MAX_TOOL_OUTPUT // 2:]
        return head + out

TOOL_SCHEMA = [
    {"type": "function", "function": {
        "name": "list_dir", "description": "列出 workspace 內某目錄的內容",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string", "description": "相對 workspace 的路徑，預設 ."}}}}},
    {"type": "function", "function": {
        "name": "read_file", "description": "讀檔（附行號），可指定行範圍",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"},
            "start": {"type": "integer", "description": "起始行（1-based，選填）"},
            "end": {"type": "integer", "description": "結束行（選填）"}},
            "required": ["path"]}}},
    {"type": "function", "function": {
        "name": "grep", "description": "在 workspace 內遞迴搜尋字串/正則",
        "parameters": {"type": "object", "properties": {
            "pattern": {"type": "string"},
            "path": {"type": "string", "description": "搜尋根，預設 ."}},
            "required": ["pattern"]}}},
    {"type": "function", "function": {
        "name": "str_replace", "description": "把檔案中唯一出現的 old 字串換成 new（逐字相符，含縮排）",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"}, "old": {"type": "string"}, "new": {"type": "string"}},
            "required": ["path", "old", "new"]}}},
    {"type": "function", "function": {
        "name": "write_file", "description": "建立或覆寫整個檔案",
        "parameters": {"type": "object", "properties": {
            "path": {"type": "string"}, "content": {"type": "string"}},
            "required": ["path", "content"]}}},
    {"type": "function", "function": {
        "name": "run_command", "description": "在沙箱 /workspace 內跑 shell 指令（build / 測試 / nix develop）",
        "parameters": {"type": "object", "properties": {
            "command": {"type": "string"}}, "required": ["command"]}}},
    {"type": "function", "function": {
        "name": "finish", "description": "完成任務（build + 測試通過、無新紅燈）時呼叫，附一句話總結",
        "parameters": {"type": "object", "properties": {
            "summary": {"type": "string"}}, "required": ["summary"]}}},
]

SYSTEM_PROMPT = """\
你是在 /workspace（limn 這個 PDF 閱讀器 repo 的 git clone）裡工作的編碼 agent。

【必讀】先讀 /workspace/CLAUDE.md 與任務相關的 /workspace/docs/*-design.md。遵守其中
所有規則，特別是：
- 使用者可見文字（文檔、給使用者看的註解、commit 訊息）一律繁體中文；程式識別符／
  路徑／函式／變數名維持英文。
- 不要 git commit / push / tag。只改檔，整合由人做。
- 新 interactive 指令的預設綁定走 Doom SPC leader 樹（見 CLAUDE.md §7）。

【你的工具】list_dir / read_file / grep 探索；str_replace / write_file 改檔；
run_command 跑 build 與測試。自由探索這個 repo，需要看什麼就去看。

【驗證】改完用 run_command 跑：
  ulimit -n 8192 && nix develop /limn#docker --command sbcl --script backend/tests/unit/run-unit.lisp
容器內 unit baseline 是「2949 passed / 10 failed」，那 10 個是既有/平台限定、不是你的鍋。
你的目標是：**完成 brief 的要求，且不引入這 10 個以外的任何新紅燈**。

【完成】當你確信 brief 達成、測試沒有新紅燈，呼叫 finish 並附一句話總結。
不要做到一半就停下來空轉 —— 要嘛繼續用工具推進，要嘛 finish。
"""

# ─────────────────────────── DeepSeek API ────────────────────────────
def call_deepseek(base_url, key, model, messages):
    body = json.dumps({
        "model": model, "messages": messages, "tools": TOOL_SCHEMA,
        "tool_choice": "auto", "temperature": 0.2,
    }).encode("utf-8")
    req = urllib.request.Request(
        base_url.rstrip("/") + "/chat/completions", data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read().decode("utf-8"))["choices"][0]["message"]

# ─────────────────────────── 驗證 + status ───────────────────────────
def parse_unit_output(text):
    # 只認「grand total」那行：「N passed, M failed (T total)」——有 (total) 後綴。
    # （per-block 的「└─ N passed, M failed」沒有 (total)，不能誤抓。）
    totals = re.findall(r"(\d+)\s+passed,\s+(\d+)\s+failed\s*\(\d+\s+total\)", text)
    if totals:
        passed, failed = int(totals[-1][0]), int(totals[-1][1])
    else:
        passed = failed = None
    names = re.findall(r"^\s*\[([A-Z0-9][A-Z0-9\-]+)\]", text, re.MULTILINE)
    return passed, failed, names

def run_verify(tools: Tools):
    cmd = ("ulimit -n 8192 && nix develop /limn#docker --command "
           "sbcl --script backend/tests/unit/run-unit.lisp 2>&1 | tail -60")
    out = tools.run_command(cmd)
    passed, failed, names = parse_unit_output(out)
    return {"passed": passed, "failed": failed, "failure_names": names, "raw_tail": out[-2500:]}

def git_diff_stat(ws: Path):
    try:
        stat = subprocess.run(["git", "-C", str(ws), "diff", "--stat"],
                              capture_output=True, text=True, timeout=60).stdout
        # 用 porcelain 抓「所有」變動：modified / 新增(未追蹤) / 刪除 ——
        # `git diff` 看不到未追蹤的新檔，而 DeepSeek 的產出常是新檔。
        porc = subprocess.run(["git", "-C", str(ws), "status", "--porcelain"],
                              capture_output=True, text=True, timeout=60).stdout
        names = [ln[3:].strip() for ln in porc.splitlines() if ln.strip()]
        return stat[-3000:], names
    except Exception as e:
        return f"(git status 失敗：{e})", []

# ─────────────────────────────── main ────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--brief", required=True, help="任務 brief 檔（markdown）")
    ap.add_argument("--workspace", required=True, help="host 上的 clone 路徑（= 沙箱 /workspace）")
    ap.add_argument("--container", default=os.environ.get("SANDBOX_NAME", "limn-loop-sandbox"))
    ap.add_argument("--run-dir", required=True, help="放 transcript / status / messages 的目錄")
    ap.add_argument("--model", default="deepseek-chat")
    ap.add_argument("--base-url", default="https://api.deepseek.com/v1")
    ap.add_argument("--max-iters", type=int, default=60)
    ap.add_argument("--max-nudges", type=int, default=3)
    ap.add_argument("--cmd-timeout", type=int, default=DEFAULT_CMD_TIMEOUT)
    ap.add_argument("--no-verify", action="store_true",
                    help="跳過收尾的 unit 驗證（read-only / orientation 任務用）")
    ap.add_argument("--continue", dest="cont", action="store_true",
                    help="從 run-dir 既有 messages.json 續跑")
    args = ap.parse_args()

    ws = Path(args.workspace).resolve()
    run_dir = Path(args.run_dir); run_dir.mkdir(parents=True, exist_ok=True)
    key = read_deepseek_key()
    tools = Tools(ws, args.container, args.cmd_timeout)
    baseline = set()
    bfile = Path(__file__).parent / "baseline-failures.txt"
    if bfile.exists():
        for ln in bfile.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                baseline.add(ln)

    transcript = (run_dir / "transcript.jsonl").open("a", encoding="utf-8")
    def log(ev): transcript.write(json.dumps(ev, ensure_ascii=False) + "\n"); transcript.flush()

    msgs_path = run_dir / "messages.json"
    brief = Path(args.brief).read_text(encoding="utf-8")
    if args.cont and msgs_path.exists():
        messages = json.loads(msgs_path.read_text(encoding="utf-8"))
        messages.append({"role": "user", "content": "繼續未完成的任務；完成時呼叫 finish。"})
        log({"ev": "resume"})
    else:
        messages = [{"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": "任務 brief：\n\n" + brief}]
        log({"ev": "start", "brief": args.brief})

    DISPATCH = {"list_dir": tools.list_dir, "read_file": tools.read_file,
                "grep": tools.grep, "str_replace": tools.str_replace,
                "write_file": tools.write_file, "run_command": tools.run_command}

    finished_reason, summary, nudges = "max_iters", "", 0
    for it in range(args.max_iters):
        try:
            msg = call_deepseek(args.base_url, key, args.model, messages)
        except urllib.error.HTTPError as e:
            finished_reason = "error"; summary = f"DeepSeek HTTP {e.code}: {e.read().decode('utf-8','replace')[:500]}"
            log({"ev": "api_error", "detail": summary}); break
        except Exception as e:
            finished_reason = "error"; summary = f"DeepSeek 呼叫失敗：{e}"
            log({"ev": "api_error", "detail": summary}); break

        messages.append(msg)
        tool_calls = msg.get("tool_calls") or []
        if msg.get("content"):
            log({"ev": "assistant", "it": it, "text": msg["content"][:1500]})

        if not tool_calls:
            nudges += 1
            log({"ev": "no_tool", "it": it, "nudges": nudges})
            if nudges > args.max_nudges:
                finished_reason = "stalled"; summary = msg.get("content", "")[:500]; break
            messages.append({"role": "user",
                "content": "請用工具繼續推進；完成且測試無新紅燈時呼叫 finish。"})
            msgs_path.write_text(json.dumps(messages, ensure_ascii=False), encoding="utf-8")
            continue
        nudges = 0

        done = False
        for tc in tool_calls:
            name = tc["function"]["name"]
            try:
                a = json.loads(tc["function"].get("arguments") or "{}")
            except Exception:
                a = {}
            if name == "finish":
                finished_reason = "finish"; summary = a.get("summary", ""); done = True
                messages.append({"role": "tool", "tool_call_id": tc["id"],
                                 "content": "（已收到 finish）"})
                log({"ev": "finish", "it": it, "summary": summary}); break
            fn = DISPATCH.get(name)
            if fn is None:
                result = f"未知工具：{name}"
            else:
                try:
                    result = fn(**a)
                except Exception as e:
                    # 工具出錯不該炸掉整個 loop —— 回報給 DeepSeek 讓它自己修正。
                    result = f"工具 {name} 執行錯誤：{e}"
            log({"ev": "tool", "it": it, "name": name,
                 "args": {k: (v[:200] if isinstance(v, str) else v) for k, v in a.items()},
                 "result_head": result[:400]})
            messages.append({"role": "tool", "tool_call_id": tc["id"], "content": result})
        msgs_path.write_text(json.dumps(messages, ensure_ascii=False), encoding="utf-8")
        if done: break

    # ── 收尾：標準驗證 + status.json ──
    if args.no_verify:
        verify = {"passed": None, "failed": None, "failure_names": [], "raw_tail": "(skipped: --no-verify)"}
        new_failures = []
        log({"ev": "verify_skipped"})
    else:
        log({"ev": "verify_start"})
        verify = run_verify(tools)
        new_failures = sorted(set(verify["failure_names"]) - baseline) if verify["failure_names"] else []
    diff_stat, changed = git_diff_stat(ws)
    status = {
        "brief": args.brief,
        "finished_reason": finished_reason,
        "iterations": it + 1,
        "deepseek_summary": summary,
        "verify": {
            "unit_passed": verify["passed"], "unit_failed": verify["failed"],
            "baseline_failed": len(baseline),
            "new_failures": new_failures,           # ← 最關鍵訊號：DeepSeek 引入的新紅燈
            "clean": (verify["failed"] is not None and not new_failures),
            "raw_tail": verify["raw_tail"],
        },
        "git_diff_stat": diff_stat,
        "files_changed": changed,
        "stalled": finished_reason in ("stalled", "max_iters"),
        "transcript": str(run_dir / "transcript.jsonl"),
    }
    (run_dir / "status.json").write_text(json.dumps(status, ensure_ascii=False, indent=2), encoding="utf-8")
    log({"ev": "done", "finished_reason": finished_reason})

    # 給 Claude 看的精簡摘要（一眼判斷成敗）
    print("──────── loop 結束 ────────")
    print(f"finished_reason : {finished_reason}")
    print(f"iterations      : {it + 1}")
    print(f"unit            : {verify['passed']} passed / {verify['failed']} failed "
          f"(baseline {len(baseline)})")
    print(f"new_failures    : {new_failures or '無 ✅'}")
    print(f"files_changed   : {len(changed)} 個")
    print(f"summary         : {summary[:300]}")
    print(f"status.json     : {run_dir / 'status.json'}")

if __name__ == "__main__":
    main()
