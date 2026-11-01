#!/usr/bin/env python3
"""Mutations-Stichprobe fuer S2c (Hand-Mutanten, kein Werkzeug): jeder Mutant wird auf eine KOPIE des Baums angewendet; die benannte Suite MUSS fehlschlagen (Exit != 0). Ueberlebende = Testluecke.
Aufruf: python3 tests/mutation_spotcheck.py [Filter]   (Dauer ~10 min; nutzt nur /tmp)"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

OPS = Path(__file__).resolve().parents[1]
RUN, EVID, WR = "tests/test_run_kind.sh", "tests/test_evidence_order.sh", "tests/test_write_result.sh"
# (name, Datei, alt, neu, Suite)
MUTANTS = [
    ("watcher: Archivieren NACH dem Report (W-3)", "bin/forge-postbote.sh", '''  mv -f "$EIN/$name" "$ERL/${ts}_$name"
  write_report "$AUS/$reportname" "$head" "$body"
  printf '%s %s %s rc=%s dauer=%ss session=%s\\n' "$(utcl)" "$name" "${model:--}"''', '''  write_report "$AUS/$reportname" "$head" "$body"
  mv -f "$EIN/$name" "$ERL/${ts}_$name"
  printf '%s %s %s rc=%s dauer=%ss session=%s\\n' "$(utcl)" "$name" "${model:--}"''', EVID),
    ("watcher: RUN mit .fortsetzung nicht abgelehnt", "bin/forge-postbote.sh", 'if [ -n "$fort" ] || [ -n "$rexec" ]', 'if [ -n "$rexec" ]', RUN),
    ("watcher: RUN mit .aufwand- nicht abgelehnt", "bin/forge-postbote.sh", '|| [ -n "$aufwand" ] || [ -n "$rmodel" ]; then ok=0', '|| [ -n "$rmodel" ]; then ok=0', RUN),
    ("watcher: RUN mit .modell- nicht abgelehnt", "bin/forge-postbote.sh", '|| [ -n "$aufwand" ] || [ -n "$rmodel" ]; then ok=0', '|| [ -n "$aufwand" ]; then ok=0', RUN),
    ("watcher: RUN erbt das Executor-Environment (MCP-Token)", "bin/forge-postbote.sh", '''exec timeout "${FORGE_RUN_MAX_SECONDS:-3900}" env -i "${renv[@]}" "$bin"''', '''forge_exec_env claude x forge x; exec timeout "${FORGE_RUN_MAX_SECONDS:-3900}" env "${renv[@]}" "$bin"''', RUN),
    ("watcher: RUN schreibt Session", "bin/forge-postbote.sh", '''    if [ -n "$newsid" ]; then''', '''    if [ "$art" = RUN ]; then newsid=fake; fi; if [ -n "$newsid" ]; then''', RUN),
    ("run-job: Job-Allowlist ohne Pruefung", "bin/forge-run-job", '''    if job is None:
        reject(65,''', '''    if job is None and False:
        reject(65,''', RUN),
    ("run-job: Argument-Regex fuer head entfernt", "bin/forge-run-job", 'SHA40 = re.compile(r"[0-9a-f]{40}")', 'SHA40 = re.compile(r".*")', RUN),
    ("run-job: Branch-Regel '..' erlaubt", "bin/forge-run-job", '''not BRANCH.fullmatch(v) or ".." in v or "//" in v''', '''not BRANCH.fullmatch(v) or "//" in v''', RUN),
    ("run-job: Typpruefung der Top-Level-Felder entfernt", "bin/forge-run-job", '''        if k in spec and (not isinstance(spec[k], want)''', '''        if False and k in spec and (not isinstance(spec[k], want)''', RUN),
    ("run-job: unbekannte Top-Level-Schluessel erlaubt", "bin/forge-run-job", '''    if unknown:
        reject(65, "unbekannte''', '''    if unknown and False:
        reject(65, "unbekannte''', RUN),
    ("run-job: lock_token bei Job ohne Lock erlaubt", "bin/forge-run-job", '''    elif "lock_token" in spec:''', '''    elif "lock_token" in spec and False:''', RUN),
    ("run-job: bestehendes Ergebnis wird nicht geschuetzt", "bin/forge-run-job", '''    for name in ("result.json", "report.md"):
        if os.path.lexists''', '''    for name in ():
        if os.path.lexists''', RUN),
    ("run-job: Job laeuft mit komplettem Environment", "bin/forge-run-job", '''    env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": os.path.join(scratch, "home"),''', '''    env = {**os.environ, "PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": os.path.join(scratch, "home"),''', RUN),
    ("run-job: SIGTERM raeumt Prozessgruppe nicht auf", "bin/forge-run-job", '''def on_term(signum, frame):
    kill_current()''', '''def on_term(signum, frame):
    pass''', RUN),
    ("run-job: Exit-Code des Jobs verschluckt", "bin/forge-run-job", '''        sys.exit(rc)
    finally:''', '''        sys.exit(0)
    finally:''', RUN),
    ("run-job: ok ohne Urteil des Jobs gilt als gruen", "bin/forge-run-job", '''        ok = rc == 0 and verdict is True''', '''        ok = rc == 0 and verdict is not False''', RUN),
    ("run-job: --exclusive entfaellt", "bin/forge-run-job", '''"--nonce", spec["nonce"], "--exclusive",''', '''"--nonce", spec["nonce"],''', RUN),
    ("ci-gate: Spitzenpruefung entfernt", "bin/jobs/ci-gate", '''    if tip0 != head:''', '''    if False:''', RUN),
    ("ci-gate: fehlendes Gate zaehlt als pass", "bin/jobs/ci-gate", '''r = {"name": g, "status": "not_configured", "exit": None, "seconds": 0.0}''', '''r = {"name": g, "status": "pass", "exit": 0, "seconds": 0.0}''', RUN),
    ("ci-gate: Baumaenderung nicht erkannt", "bin/jobs/ci-gate", '''            if dirty:''', '''            if False:''', RUN),
    ("ci-gate: Gate-Zeitlimit ignoriert", "bin/jobs/ci-gate", '''            except subprocess.TimeoutExpired:
                status = "timeout"''', '''            except subprocess.TimeoutExpired:
                status = "pass"''', RUN),
    ("ci-gate: Head aus dem Checkout nicht gebunden (head_worktree fehlt)", "bin/jobs/ci-gate", '''    open(os.path.join(out, "head_worktree"), "w").write(checkout)''', '''    pass''', RUN),
    ("write-result: Head-Vergleich entfernt", "bin/forge-write-result", '''        if hfield in obj and obj[hfield] != head:''', '''        if False:''', WR),
    ("write-result: build ohne --worktree erlaubt", "bin/forge-write-result", '''    if hfield and o["worktree"] is None and schema in HEAD_REQUIRED:''', '''    if False:''', WR),
    ("write-result: build ohne --report erlaubt", "bin/forge-write-result", '''    if o["report"] is None and schema in HEAD_REQUIRED:''', '''    if False:''', WR),
    ("write-result: ungetrackte Aenderungen unbeachtet -> getrackte auch", "bin/forge-write-result", '''    if r.stdout.strip():
        fail(3, "der Worktree hat nicht''', '''    if False:
        fail(3, "der Worktree hat nicht''', WR),
    ("write-result: getippte falsche Report-Kopfzeile erlaubt", "bin/forge-write-result", '''            if m.group(1) != head:''', '''            if False:''', WR),
    ("write-result: --exclusive ersetzt trotzdem", "bin/forge-write-result", '''            os.link(tmp, final)                                  # scheitert, wenn final existiert (kein Ersetzen)
            os.unlink(tmp)''', '''            os.rename(tmp, final)''', WR),
    ("write-result: fsmonitor nicht abgeschaltet", "bin/forge-write-result", '''["git", "-c", "core.fsmonitor=false", "-C", worktree, *args]''', '''["git", "-C", worktree, *args]''', WR),
    ("write-result: losgeloester HEAD fuer build erlaubt", "bin/forge-write-result", '''    if want_branch and not branch:''', '''    if False:''', WR),
]


def main() -> int:
    flt = sys.argv[1] if len(sys.argv) > 1 else ""
    survivors, killed, napplied = [], 0, 0
    for name, rel, old, new, suite in MUTANTS:
        if flt and flt not in name:
            continue
        with tempfile.TemporaryDirectory(prefix="mut.") as td:
            tree = Path(td) / "ops"
            shutil.copytree(OPS, tree, ignore=shutil.ignore_patterns(".git", "__pycache__"))
            f = tree / rel
            src = f.read_text()
            if old not in src:
                print(f"NOT-APPLIED  {name}")
                survivors.append((name, "pattern not found"))
                continue
            f.write_text(src.replace(old, new, 1))
            napplied += 1
            p = subprocess.run(["bash", str(tree / suite)], capture_output=True, text=True, timeout=900)
            if p.returncode != 0:
                killed += 1
                print(f"killed       {name}")
            else:
                survivors.append((name, "survived"))
                print(f"SURVIVED     {name}")
    print(f"--- applied={napplied} killed={killed} survivors={[s for s in survivors]}")
    return 0 if not survivors else 1


if __name__ == "__main__":
    sys.exit(main())
