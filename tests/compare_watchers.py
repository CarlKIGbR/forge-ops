#!/usr/bin/env python3
"""Alt-gegen-neu-Vergleich des Watchers (S2c rework 1): fuehrt die Nicht-RUN-Faelle (5 ARTen x 6 Faelle) mit dem Watcher einer Basis-Revision (Standard bd6a8af = master) UND mit dem Watcher dieses Checkouts in
getrennten Wegwerf-Bereichen mit denselben Stub-CLIs aus und vergleicht Reports, Archiv-/Log-Namen, Log-Inhalte, state/-Dateien und postbote.log. Normalisiert werden NUR Zeitstempel/Dauer (und die in diesem Slice
zusaetzliche RUN-Hilfszeile im ABGELEHNT-Report); jede andere Abweichung ist ein Fehler.
Aufruf: python3 tests/compare_watchers.py [basis-revision]   (Exit 0 = identisch)"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

OPS = Path(__file__).resolve().parents[1]
BASE_REV = sys.argv[1] if len(sys.argv) > 1 else "bd6a8af"
ARTS = ("BRIEF", "WEISUNG", "NACHFORDERUNG", "GO", "PING")
CASES = [  # (suffix, kuerzel, session-datei vorab (executor) | None)
    ("", "forge-c1", None),
    (".exec-codex.aufwand-high.modell-gpt-6-luna.n-0a1b2c3d", "forge-c2", None),
    (".fortsetzung.exec-claude", "forge-c3", "claude"),
    (".fortsetzung.exec-codex", "forge-c4", "codex"),
    (".fortsetzung", "forge-c5", None),                       # Fortsetzung ohne Session => Exit 2 in 0 s
    (".aufwand-low.exec-claude", "forge-c6", None),           # falsche Reihenfolge => ABGELEHNT
]
CLAUDE = """#!/usr/bin/env bash
cat >/dev/null
printf '{"type":"result","subtype":"success","session_id":"sid-claude","result":"PONG-CLAUDE ARGV: %s","total_cost_usd":0.01}\\n' "$*"
"""
CODEX = """#!/usr/bin/env bash
cat >/dev/null
printf '{"type":"thread.started","thread_id":"tid-codex"}\\n{"type":"item.completed","item":{"type":"agent_message","text":"PONG-CODEX ARGV: %s"}}\\n{"type":"turn.completed","usage":{"input_tokens":1}}\\n' "$*"
"""


def run_case(script_dir: Path, art: str, suffix: str, k: str, sess: str | None) -> dict:
    with tempfile.TemporaryDirectory(prefix="cmpw.") as td:
        base = Path(td)
        post = base / "post"
        for d in ("eingang", "ausgang", "erledigt", "log", "state", "control"):
            (post / d).mkdir(parents=True)
        (base / "home").mkdir()
        for n, body in (("claude", CLAUDE), ("codex", CODEX)):
            (base / n).write_text(body)
            (base / n).chmod(0o755)
        if sess:
            (post / "state" / f"{k}.session").write_text("sess-123\n")
            (post / "state" / f"{k}.exec").write_text(sess + "\n")
        name = f"{art}_{k}{suffix}.md"
        (post / "eingang" / name).write_text("Bitte antworten.\n")
        os.utime(post / "eingang" / name, (1, 1))
        env = {**os.environ, "FORGE_BASE": str(base), "FORGE_MIN_AGE": "0", "HOME": str(base / "home"), "CLAUDE_BIN": str(base / "claude"), "CODEX_BIN": str(base / "codex")}
        subprocess.run(["bash", str(script_dir / "forge-postbote.sh"), "--once"], env=env, check=True, timeout=120, capture_output=True)
        norm = lambda t: re.sub(r"\d{8}T\d{6}Z", "TS", re.sub(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", "UTC", re.sub(r"Dauer: \d+s", "Dauer: Ns", re.sub(r"dauer=\d+s", "dauer=Ns", t))))  # noqa: E731
        out = {"files": {d: sorted(norm(p.name) for p in (post / d).iterdir() if not p.name.startswith(".")) for d in ("eingang", "ausgang", "erledigt", "log", "state")}}
        out["reports"] = [norm(p.read_text()) for p in sorted((post / "ausgang").glob("REPORT_*.md"))]
        out["logs"] = [norm(p.read_text()) for p in sorted((post / "log").glob("*.json")) + sorted((post / "log").glob("*.stderr"))]
        out["state"] = {p.name: p.read_text() for p in sorted((post / "state").iterdir()) if p.name not in ("heartbeat", ".lock") and not p.name.startswith(".")}
        out["postbote_log"] = norm((post / "log" / "postbote.log").read_text()) if (post / "log" / "postbote.log").exists() else ""
        return out


def strip_added_help(rep: str) -> str:
    return "\n".join(ln for ln in rep.splitlines() if not ln.startswith("RUN-Auftraege: nur `RUN_<K>"))


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="oldw.") as td:
        old = Path(td)
        for f in ("forge-postbote.sh", "forge-exec-env.sh"):
            data = subprocess.run(["git", "-C", str(OPS), "show", f"{BASE_REV}:bin/{f}"], check=True, capture_output=True).stdout
            (old / f).write_bytes(data)
        bad, n = 0, 0
        for art in ARTS:
            for suffix, k, sess in CASES:
                a, b = run_case(old, art, suffix, k, sess), run_case(OPS / "bin", art, suffix, k, sess)
                b["reports"] = [strip_added_help(r) for r in b["reports"]]
                a["reports"] = [strip_added_help(r) for r in a["reports"]]
                n += 1
                if a != b:
                    bad += 1
                    print(f"DIFF  {art}_{k}{suffix}")
                    for key in a:
                        if a[key] != b[key]:
                            print(f"   {key}:\n   old={a[key]!r:.600}\n   new={b[key]!r:.600}")
        print(f"cases={n} identical={n - bad} different={bad} (base {BASE_REV}; normalised: timestamps/durations, the added RUN help line of rejection reports)")
        return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
