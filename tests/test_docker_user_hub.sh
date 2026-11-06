#!/usr/bin/env bash
# N1 (FORGE_NODE.md 5.1): DOCKER-USER-Regelsatz fuer den forge-nodehub (TCP/8094) in forge-docker-user.sh --hub. Stub-iptables/systemd-run/systemctl, kein Root, keine echten Regeln.
# Aufruf: tests/test_docker_user_hub.sh   (Exit 0 = alles gruen)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$HERE/../bin/forge-docker-user.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; LOG="$T/calls.log"; STATE="$T/state"; mkdir -p "$BIN" "$STATE"
cat > "$BIN/stub" <<EOF
#!/bin/sh
n=\$(basename "\$0")
case "\$n" in
  iptables)
    case "\$*" in
      *" -C "*|"-C "*) echo "iptables \$*" >> "$LOG"; exit "\${STUB_C_EXIT:-1}" ;;
      "-S"*) echo "iptables \$*" >> "$LOG"; [ "\${STUB_S_LISTS:-0}" = 1 ] && echo "-A DOCKER-USER -p tcp -m comment --comment forge-nodehub -j DROP"; exit 0 ;;
      "-n -L"*) echo "iptables \$*" >> "$LOG"; exit 0 ;;
      *) echo "MUT iptables \$*" >> "$LOG"; [ "\${STUB_IPT_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
    esac ;;
  systemd-run) echo "ARM systemd-run \$*" >> "$LOG"; [ "\${STUB_TIMER_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  systemctl)
    echo "systemctl \$*" >> "$LOG"
    [ "\$1" = is-active ] && { echo active; exit 0; }
    exit 0 ;;
esac
EOF
chmod +x "$BIN/stub"; for n in iptables systemd-run systemctl; do ln -s stub "$BIN/$n"; done
# Boot-Kopie (forge-docker-user.service fuehrt /usr/local/sbin/forge-docker-user.sh --restore aus): im Test ein Temp-Verzeichnis, nie das echte /usr/local/sbin
SBIN="$T/sbin"; UDST="$T/units"; USRC="$T/unitsrc"; mkdir -p "$SBIN" "$UDST" "$USRC"
printf '[Service]\nExecStart=/usr/local/sbin/forge-docker-user.sh --restore\n' > "$USRC/forge-docker-user.service"; printf '[Service]\nExecStart=/bin/true\n' > "$USRC/forge-edge.service"
export PATH="$BIN:$PATH" FORGE_FW_TEST=1 FORGE_FW_STATE_DIR="$STATE" FORGE_FW_SBIN="$SBIN" FORGE_FW_UNIT_DST="$UDST" FORGE_EDGE_UNIT_SRC="$USRC"
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
reset() { : > "$LOG"; rm -f "$STATE"/*; }
install_boot_copy() { "$FW" --install-unit >/dev/null 2>&1; }
muts() { grep -c "^MUT iptables $1" "$LOG"; }

# --- Regelsatz (Dry-Run) ---
out=$("$FW" --dry-run --hub)
n_ins=$(printf '%s\n' "$out" | grep -c '^iptables -I DOCKER-USER')
check "dry-run --hub: genau 3 Regeln (2 Accept + 1 Drop)"          test "$n_ins" = 3
check "dry-run --hub: Accept nur aus 192.168.10.0/29 und 192.168.30.0/29" bash -c "[ \$(printf '%s\n' \"\$1\" | grep -c -- '-s 192.168.10.0/29 .*-j ACCEPT') = 1 ] && [ \$(printf '%s\n' \"\$1\" | grep -c -- '-s 192.168.30.0/29 .*-j ACCEPT') = 1 ] && [ \$(printf '%s\n' \"\$1\" | grep -c -- '-j ACCEPT') = 2 ]" _ "$out"
check "dry-run --hub: VPN 10.200.0.0/29 kommt nicht vor"          bash -c "! printf '%s\n' \"\$1\" | grep -q '10.200.0.0'" _ "$out"
check "dry-run --hub: nur Ziel 192.168.10.4:8094 (ctorigdst), kein 443/8443" bash -c "printf '%s\n' \"\$1\" | grep '^iptables -I' | grep -vq -- '--ctorigdst 192.168.10.4 --ctorigdstport 8094 ' && exit 1; ! printf '%s\n' \"\$1\" | grep -qE 'ctorigdstport (443|8443)'" _ "$out"
check "dry-run --hub: Drop steht nach den Accepts"                 bash -c "printf '%s\n' \"\$1\" | grep '^iptables -I' | tail -1 | grep -q -- '-j DROP'" _ "$out"
check "dry-run --hub: eigener Tag forge-nodehub, kein forge-edge" bash -c "printf '%s\n' \"\$1\" | grep '^iptables' | grep -q -- '--comment forge-nodehub' && ! printf '%s\n' \"\$1\" | grep '^iptables' | grep -q 'forge-edge'" _ "$out"
check "dry-run --hub: Rollback-Timer eigener Prefix + '--remove --hub'" bash -c "printf '%s\n' \"\$1\" | grep -q 'systemd-run --unit=forge-docker-user-hub-rollback-.*--remove --hub\$'" _ "$out"
check "dry-run --hub: kein ufw/-F/-X/Port 22/80"                  bash -c "! printf '%s\n' \"\$1\" | grep -qE 'ufw|iptables -F|iptables -X|--dport (22|80)\b'" _ "$out"

# --- Edge-Regelsatz unveraendert ---
eo=$("$FW" --dry-run)
check "dry-run (Edge) unveraendert: 8 Regeln, kein 8094"          bash -c "[ \$(printf '%s\n' \"\$1\" | grep -c '^iptables -I DOCKER-USER') = 8 ] && ! printf '%s\n' \"\$1\" | grep -q 8094" _ "$eo"
check "dry-run (Edge): Timer-Prefix/-Aufruf unveraendert"          bash -c "printf '%s\n' \"\$1\" | grep -q 'systemd-run --unit=forge-docker-user-rollback-<zeit>-<pid> --on-active=300s .*forge-docker-user.sh --remove\$'" _ "$eo"
check "--hub --install-unit wird abgelehnt (Exit 2)"               bash -c '"$1" --hub --install-unit >/dev/null 2>&1; [ $? = 2 ]' _ "$FW"

# --- Owner-Ablauf 13.B (N5-prep): --dry-run --hub zeigt nur an, aendert nichts, startet keinen Timer ---
reset
"$FW" --dry-run --hub >/dev/null 2>&1; r1=$?; "$FW" --dry-run --confirm --hub >/dev/null 2>&1; r2=$?; "$FW" --dry-run --remove --hub >/dev/null 2>&1; r3=$?; "$FW" --dry-run --restore --hub >/dev/null 2>&1; r4=$?
check "dry-run --hub (apply/confirm/remove/restore): Exit 0, keine Mutation, kein Timer, keine Marke" bash -c "[ $r1$r2$r3$r4 = 0000 ] && ! grep -qE '^(MUT|ARM) ' '$LOG' && [ -z \"\$(ls '$STATE')\" ]"
check "Standard-Rollback-Timer des Hub-Satzes sind 5 Minuten (300 s)" bash -c "'$FW' --dry-run --hub | grep -q -- '--on-active=300s'"
reset
"$FW" --dry-run --hub >/dev/null 2>&1; "$FW" --hub >/dev/null 2>&1
check "Ablauf 13.B: ein Hub-Apply setzt keine Bestaetigungsmarke (erst --confirm --hub)" test ! -e "$STATE/hub-rules-confirmed"

# --- Boot-Kopie (Verify M-1): --hub setzt/bestaetigt nur, wenn die Root-Kopie dieses Script ist; sonst fehlen die 8094-Regeln nach dem Reboot ---
reset; rm -f "$SBIN"/*
"$FW" --hub >/dev/null 2>&1; rc=$?
check "apply --hub ohne Boot-Kopie: Exit 1, kein Timer, keine Regel"        bash -c "[ $rc = 1 ] && ! grep -qE '^(MUT|ARM) ' '$LOG'"
out=$("$FW" --hub 2>&1 >/dev/null); check "apply --hub ohne Boot-Kopie: Meldung nennt --install-unit" bash -c "printf '%s' \"\$1\" | grep -q -- '--install-unit'" _ "$out"
printf '#!/bin/sh\necho alt\n' > "$SBIN/forge-docker-user.sh"; chmod +x "$SBIN/forge-docker-user.sh"; reset
"$FW" --hub >/dev/null 2>&1; rc=$?
check "apply --hub mit veralteter Boot-Kopie: Exit 1, keine Regel"          bash -c "[ $rc = 1 ] && ! grep -qE '^(MUT|ARM) ' '$LOG'"
STUB_S_LISTS=1 "$FW" --confirm --hub >/dev/null 2>&1; rc=$?
check "confirm --hub mit veralteter Boot-Kopie: Exit 1, keine Marke"        bash -c "[ $rc = 1 ] && [ ! -e '$STATE/hub-rules-confirmed' ]"
check "dry-run --hub mit veralteter Boot-Kopie: WARNUNG, Exit 0, keine Mutation" bash -c "o=\$('$FW' --dry-run --hub); [ \$? = 0 ] && printf '%s' \"\$o\" | grep -q WARNUNG && ! grep -qE '^(MUT|ARM) ' '$LOG'"
if git -C "$HERE/.." cat-file -e 77df871:bin/forge-docker-user.sh 2>/dev/null; then       # die echte Altlast: das Script von master vor dem --hub-Satz als Boot-Kopie
    git -C "$HERE/.." show 77df871:bin/forge-docker-user.sh > "$SBIN/forge-docker-user.sh"; chmod +x "$SBIN/forge-docker-user.sh"; reset; touch "$STATE/rules-confirmed" "$STATE/hub-rules-confirmed"
    "$SBIN/forge-docker-user.sh" --restore >/dev/null 2>&1
    check "Altlast (master-Script als Boot-Kopie): --restore stellt 0 Hub-Regeln her (so war der Reboot-Befund)" bash -c "[ \$(grep -c '^MUT iptables -I.*forge-nodehub' '$LOG') = 0 ]"
    "$FW" --hub >/dev/null 2>&1; rc=$?
    check "... und --hub verweigert genau dann"                              test "$rc" = 1
fi
reset; "$FW" --install-unit >/dev/null 2>&1; rc=$?
check "--install-unit: Exit 0, Boot-Kopie identisch, Unit installiert"       bash -c "[ $rc = 0 ] && cmp -s '$FW' '$SBIN/forge-docker-user.sh' && [ -f '$UDST/forge-docker-user.service' ]"
check "Boot-Unit fuehrt genau die Root-Kopie mit --restore aus"             grep -q "^ExecStart=/usr/local/sbin/forge-docker-user.sh --restore\$" "$UDST/forge-docker-user.service"
REALUNIT=/srv/forge/work/forge-edge/systemd/forge-docker-user.service
[ -f "$REALUNIT" ] && check "echte forge-edge-Unit: ExecStart = /usr/local/sbin/forge-docker-user.sh --restore" grep -q "^ExecStart=/usr/local/sbin/forge-docker-user.sh --restore\$" "$REALUNIT"
check "dry-run --hub mit aktueller Boot-Kopie: 'ok'"                         bash -c "'$FW' --dry-run --hub | grep -q 'Boot-Kopie .* identisch .*ok'"
# Reboot-Simulation: Ablauf der Anleitung (install-unit, --hub, --confirm --hub), dann 'Boot' = die INSTALLIERTE Kopie mit --restore, Regeln vorher weg
reset; "$FW" --hub >/dev/null 2>&1; STUB_S_LISTS=1 "$FW" --confirm --hub >/dev/null 2>&1; touch "$STATE/rules-confirmed"; : > "$LOG"
"$SBIN/forge-docker-user.sh" --restore >/dev/null 2>&1; rc=$?
check "Boot (installierte Kopie, --restore): 3 Hub-Regeln auf 192.168.10.4:8094 + 8 Edge, kein Timer, Exit 0" bash -c "[ $rc = 0 ] && [ \$(grep -c '^MUT iptables -I.*ctorigdstport 8094 .*forge-nodehub' '$LOG') = 3 ] && [ \$(grep -c '^MUT iptables -I.*forge-edge' '$LOG') = 8 ] && ! grep -q '^ARM ' '$LOG'"
check "Boot: Reihenfolge Hub-Accepts vor Hub-Drop (kein Fenster mit offenem Port)" bash -c "grep '^MUT iptables -I.*forge-nodehub' '$LOG' | tail -1 | grep -q -- '-j DROP'"
check "Boot-Nachweis fuer die Anleitung: installierte Kopie --dry-run --restore zeigt 3 forge-nodehub-Zeilen" bash -c "[ \$('$SBIN/forge-docker-user.sh' --dry-run --restore | grep -c '^iptables -I.*forge-nodehub') = 3 ]"
reset; touch "$STATE/rules-confirmed" "$STATE/hub-rules-confirmed"
out=$(STUB_IPT_FAIL=1 "$SBIN/forge-docker-user.sh" --restore 2>&1 >/dev/null)
check "Hub-Restore scheitert: Meldung sagt 'OFFEN' (nicht 'gesperrt')"       bash -c "printf '%s' \"\$1\" | grep -q 'OFFEN' && ! printf '%s' \"\$1\" | grep -q 'bleibt gesperrt'" _ "$out"

# --- Apply: Rollback zuerst, nur Hub-Regeln ---
reset
"$FW" --hub >/dev/null 2>&1; rc=$?
check "apply --hub: Exit 0"                                         test "$rc" = 0
a=$(grep -n '^ARM systemd-run' "$LOG" | head -1 | cut -d: -f1); v=$(grep -n '^systemctl is-active forge-docker-user-hub-rollback-' "$LOG" | head -1 | cut -d: -f1); m=$(grep -n '^MUT iptables' "$LOG" | head -1 | cut -d: -f1)
check "apply --hub: Timer scharf -> verifiziert -> erst dann Regeln" bash -c "[ -n '$a' ] && [ -n '$v' ] && [ -n '$m' ] && [ '$a' -lt '$v' ] && [ '$v' -lt '$m' ]"
check "apply --hub: 3 Einfuege-Aufrufe, alle forge-nodehub"        bash -c "[ \$(grep -c '^MUT iptables -I' '$LOG') = 3 ] && ! grep '^MUT' '$LOG' | grep -q forge-edge"
check "apply --hub: Timer ruft '--remove --hub'"                    grep -q 'ARM systemd-run .*--on-active=300s .*--remove --hub$' "$LOG"
reset
STUB_TIMER_FAIL=1 "$FW" --hub >/dev/null 2>&1; rc=$?
check "apply --hub: Timer scheitert -> Exit 1, keine Regel geaendert" bash -c "[ $rc != 0 ] && ! grep -q '^MUT' '$LOG'"
reset
STUB_IPT_FAIL=1 "$FW" --hub >/dev/null 2>&1; rc=$?
check "apply --hub: Regelfehler -> Rollback, Exit 1"               test "$rc" != 0

# --- Confirm / Remove beruehren nur den Hub-Satz ---
reset
"$FW" --hub >/dev/null 2>&1; : > "$LOG"
STUB_S_LISTS=1 "$FW" --confirm --hub >/dev/null 2>&1; rc=$?
check "confirm --hub: Exit 0 und Hub-Marke gesetzt"                bash -c "[ $rc = 0 ] && [ -e '$STATE/hub-rules-confirmed' ]"
check "confirm --hub: Edge-Marke nicht angelegt"                    test ! -e "$STATE/rules-confirmed"
check "confirm --hub: stoppt nur Hub-Timer"                          bash -c "grep -q \"systemctl stop forge-docker-user-hub-rollback-\" '$LOG' && ! grep 'systemctl stop' '$LOG' | grep -q 'forge-docker-user-rollback-'"
reset
STUB_S_LISTS=0 "$FW" --confirm --hub >/dev/null 2>&1; rc=$?
check "confirm --hub ohne aktive Regeln: Exit 1, keine Marke"      bash -c "[ $rc != 0 ] && [ ! -e '$STATE/hub-rules-confirmed' ]"
reset; touch "$STATE/hub-rules-confirmed" "$STATE/rules-confirmed"
"$FW" --remove --hub >/dev/null 2>&1; rc=$?
check "remove --hub: nur forge-nodehub-Regeln geprueft/entfernt"   bash -c "! grep 'iptables' '$LOG' | grep -q 'forge-edge'"
check "remove --hub: Hub-Marke weg, Edge-Marke bleibt"             bash -c "[ ! -e '$STATE/hub-rules-confirmed' ] && [ -e '$STATE/rules-confirmed' ]"

# --- Restore (Boot) ---
reset; touch "$STATE/rules-confirmed"
"$FW" --restore >/dev/null 2>&1; rc=$?
check "restore ohne Hub-Marke: wie bisher (8 Regeln, kein Hub, Exit 0)" bash -c "[ $rc = 0 ] && [ \$(grep -c '^MUT iptables -I' '$LOG') = 8 ] && ! grep -q nodehub '$LOG'"
reset; touch "$STATE/rules-confirmed" "$STATE/hub-rules-confirmed"
"$FW" --restore >/dev/null 2>&1; rc=$?
check "restore mit Hub-Marke: 3 Hub- + 8 Edge-Regeln, kein Timer"  bash -c "[ $rc = 0 ] && [ \$(grep -c '^MUT iptables -I.*forge-nodehub' '$LOG') = 3 ] && [ \$(grep -c '^MUT iptables -I.*forge-edge' '$LOG') = 8 ] && ! grep -q '^ARM ' '$LOG'"
reset; touch "$STATE/hub-rules-confirmed"
"$FW" --restore >/dev/null 2>&1; rc=$?
check "restore nur Hub bestaetigt: Hub-Regeln da, Edge bleibt gesperrt (Exit 1)" bash -c "[ $rc != 0 ] && [ \$(grep -c '^MUT iptables -I.*forge-nodehub' '$LOG') = 3 ] && [ \$(grep -c '^MUT iptables -I.*forge-edge' '$LOG') = 0 ]"
reset
"$FW" --restore --hub >/dev/null 2>&1; rc=$?
check "restore --hub ohne Marke: Exit 1, keine Mutation"           bash -c "[ $rc != 0 ] && ! grep -q '^MUT' '$LOG'"

echo "---- $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" = 0 ]
