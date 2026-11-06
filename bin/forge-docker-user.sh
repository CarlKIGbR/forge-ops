#!/usr/bin/env bash
# forge-docker-user.sh - DOCKER-USER-Regeln fuer den Forge-Edge (Caddy auf 192.168.10.4:443/8443).
#
#   sudo forge-docker-user.sh               Rollback-Timer (300 s) scharfschalten + pruefen, DANN Regeln setzen (idempotent)
#   sudo forge-docker-user.sh --confirm     Timer stoppen, Regeln bleiben; merkt sich "bestaetigt" fuer den Boot
#   sudo forge-docker-user.sh --remove      Regeln entfernen, Timer stoppen, "bestaetigt" loeschen
#   sudo forge-docker-user.sh --install-unit   Script nach /usr/local/sbin, systemd-Units installieren + enable (kein Start)
#   sudo forge-docker-user.sh --restore     (von der Unit beim Boot) bestaetigte Regeln ohne Timer wiederherstellen;
#                                           ohne "bestaetigt" Exit 1 -> forge-edge.service startet nicht
#   forge-docker-user.sh --dry-run [--remove|--install-unit|--confirm]   nur die Kommandos ausgeben, nichts aendern
#   Zusatz --hub (apply/--confirm/--remove/--restore/--dry-run): eigener Regelsatz fuer den forge-nodehub (N1, FORGE_NODE.md 5.1): TCP/8094 auf
#                                           192.168.10.4 nur aus 192.168.10.0/29 und 192.168.30.0/29 (NICHT aus dem VPN 10.200.0.0/29), sonst DROP.
#                                           Eigener Tag (forge-nodehub), eigener Rollback-Timer-Prefix, eigene "bestaetigt"-Marke; die Edge-Regeln bleiben unberuehrt.
#                                           Ein normales --restore (Boot) stellt die Hub-Regeln mit wieder her, wenn sie bestaetigt wurden - aber nur, wenn die Boot-Kopie
#                                           ($SBIN_COPY, von forge-docker-user.service ausgefuehrt) dieses Script ist: --hub und --hub --confirm brechen sonst ab (sudo $SELF --install-unit).
#
# Erlaubt 10.200.0.0/29, 192.168.10.0/29, 192.168.30.0/29 auf 192.168.10.4:443 und :8443, alles andere
# auf diese Ziele wird verworfen. Andere Ports, ufw und andere Chains bleiben unberuehrt.
# Docker DNATet vor DOCKER-USER, daher wird das Original-Ziel per conntrack (--ctorigdst/--ctorigdstport,
# nur Richtung ORIGINAL, damit Antwortpakete nicht getroffen werden) abgeglichen.
# Sicherheit: Der Rollback-Timer wird VOR der ersten Regel-Aenderung angelegt und geprueft; scheitert das, aendert
# das Script nichts (Exit 1). Scheitert danach eine Regel-Aenderung, werden die Regeln sofort zurueckgenommen.
set -euo pipefail

EDGE_IP="${EDGE_IP:-192.168.10.4}"
NETS=(10.200.0.0/29 192.168.10.0/29 192.168.30.0/29)
PORTS=(443 8443)
CHAIN=DOCKER-USER
TAG=forge-edge
UNIT_PREFIX=forge-docker-user-rollback
ROLLBACK_SECONDS=300
IPT="${IPTABLES:-iptables}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
STATE_DIR="${FORGE_FW_STATE_DIR:-/var/lib/forge-edge}"
CONFIRMED="$STATE_DIR/rules-confirmed"
UNIT_SRC="${FORGE_EDGE_UNIT_SRC:-/srv/forge/work/forge-edge/systemd}"
UNIT_DST="${FORGE_FW_UNIT_DST:-/etc/systemd/system}"
SBIN_COPY="${FORGE_FW_SBIN:-/usr/local/sbin}/forge-docker-user.sh"
UNITS=(forge-docker-user.service forge-edge.service)
HUB_IP="${HUB_IP:-192.168.10.4}"
HUB_PORT=8094
HUB_NETS=(192.168.10.0/29 192.168.30.0/29)
HUB_TAG=forge-nodehub
HUB_UNIT_PREFIX=forge-docker-user-hub-rollback
HUB_CONFIRMED="$STATE_DIR/hub-rules-confirmed"

mode=apply
dry=0
hub=0
for a in "$@"; do
    case "$a" in
        --hub) hub=1 ;;
        --confirm) mode=confirm ;;
        --remove) mode=remove ;;
        --restore) mode=restore ;;
        --install-unit) mode=install ;;
        --dry-run) dry=1 ;;
        -h|--help) sed -n "2,26p" "$SELF"; exit 0 ;;
        *) echo "unbekannte Option: $a" >&2; exit 2 ;;
    esac
done

# Regel-Spezifikationen (ohne Aktion/Chain), in der Reihenfolge, in der sie in der Chain stehen sollen
specs=()
if [ "$hub" = 1 ]; then
    [ "$mode" != install ] || { echo "--hub und --install-unit schliessen sich aus (die Units gehoeren zum Edge-Regelsatz)" >&2; exit 2; }
    TAG=$HUB_TAG; UNIT_PREFIX=$HUB_UNIT_PREFIX; CONFIRMED=$HUB_CONFIRMED; SET_ARG=" --hub"
    for n in "${HUB_NETS[@]}"; do
        specs+=("-p tcp -s $n -m conntrack --ctorigdst $HUB_IP --ctorigdstport $HUB_PORT --ctdir ORIGINAL -m comment --comment $TAG -j ACCEPT")
    done
    specs+=("-p tcp -m conntrack --ctorigdst $HUB_IP --ctorigdstport $HUB_PORT --ctdir ORIGINAL -m comment --comment $TAG -j DROP")
else
    SET_ARG=""
    for p in "${PORTS[@]}"; do
        for n in "${NETS[@]}"; do
            specs+=("-p tcp -s $n -m conntrack --ctorigdst $EDGE_IP --ctorigdstport $p --ctdir ORIGINAL -m comment --comment $TAG -j ACCEPT")
        done
    done
    for p in "${PORTS[@]}"; do
        specs+=("-p tcp -m conntrack --ctorigdst $EDGE_IP --ctorigdstport $p --ctdir ORIGINAL -m comment --comment $TAG -j DROP")
    done
fi

run() {
    if [ "$dry" = 1 ]; then echo "$*"; else "$@"; fi
}

stop_timers() {
    if [ "$dry" = 1 ]; then echo "systemctl stop '$UNIT_PREFIX-*.timer'"; return 0; fi
    systemctl stop "$UNIT_PREFIX-*.timer" 2>/dev/null || true
}

# Rueckgabe 0 = alle $TAG-Regeln entfernt/nicht vorhanden; 1 = Loeschen scheiterte; 2 = Pruefung (-C) selbst scheiterte.
# iptables -C: Exit 0 = Regel da, Exit 1 = Regel fehlt; jeder andere Exit (z. B. 2, Fehler/Lock/Syntax) ist KEINE Abwesenheit.
remove_rules() {
    local s rc
    for s in "${specs[@]}"; do
        if [ "$dry" = 1 ]; then
            echo "$IPT -D $CHAIN $s"
            continue
        fi
        while :; do
            # shellcheck disable=SC2086  # s ist bewusst wortgetrennt
            if $IPT -C "$CHAIN" $s 2>/dev/null; then rc=0; else rc=$?; fi
            case "$rc" in
                0) # shellcheck disable=SC2086
                   $IPT -D "$CHAIN" $s || return 1 ;;
                1) break ;;
                *) return 2 ;;
            esac
        done
    done
    return 0
}

# Cleanup verifizieren: Chain auflisten (muss gelingen) und keine eigene Regel mehr finden.
rules_gone() {
    local out
    out="$($IPT -S "$CHAIN" 2>/dev/null)" || return 1
    case "$out" in *"--comment $TAG"*) return 1 ;; esac
    return 0
}

insert_rules() {
    local i=1 s
    for s in "${specs[@]}"; do
        # shellcheck disable=SC2086
        run $IPT -I "$CHAIN" "$i" $s || return 1
        i=$((i + 1))
    done
}

need_root() {
    if [ "$dry" = 0 ] && [ "$(id -u)" -ne 0 ] && [ "${FORGE_FW_TEST:-0}" != 1 ]; then
        echo "als root ausfuehren (sudo $SELF $*)" >&2
        exit 1
    fi
}

# Hub-Satz und Boot: die Unit forge-docker-user.service fuehrt die ROOT-Kopie $SBIN_COPY aus (--restore). Ist sie aelter als dieses Script (kein --hub), kommen die 8094-Regeln nach einem
# Reboot nicht zurueck und der Hub-Port ist aus jedem Netz erreichbar. Darum setzt/bestaetigt --hub nur, wenn die Boot-Kopie mit diesem Script identisch ist (sudo $SELF --install-unit).
boot_copy_current() { cmp -s "$SELF" "$SBIN_COPY"; }
require_boot_copy() {
    [ "$hub" = 1 ] || return 0
    boot_copy_current || { echo "Boot-Kopie $SBIN_COPY fehlt oder ist nicht identisch mit $SELF - erst: sudo $SELF --install-unit (sonst fehlen die Hub-Regeln nach einem Reboot). Keine Regel geaendert." >&2; exit 1; }
}

check_env() {
    $IPT -n -L "$CHAIN" >/dev/null 2>&1 || { echo "Chain $CHAIN fehlt (laeuft Docker?)" >&2; exit 1; }
}

# Timer scharfschalten UND pruefen; Rueckgabe 0 = aktiv. Eindeutiger Unit-Name, damit ein alter Timer
# bis zum Erfolg weiterlaeuft (kein ungeschuetztes Fenster).
arm_timer() {
    local unit
    unit="$UNIT_PREFIX-$(date +%s)-$$"
    # shellcheck disable=SC2086  # SET_ARG ist leer oder " --hub"
    systemd-run --unit="$unit" --on-active="${ROLLBACK_SECONDS}s" "$SELF" --remove$SET_ARG >/dev/null || return 1
    [ "$(systemctl is-active "$unit.timer" 2>/dev/null)" = active ] || { systemctl stop "$unit.timer" 2>/dev/null || true; return 1; }
    ARMED_UNIT="$unit.timer"
}

stop_old_timers() {
    local t
    while read -r t _; do
        [ -n "$t" ] && [ "$t" != "$ARMED_UNIT" ] && systemctl stop "$t" 2>/dev/null || true
    done < <(systemctl list-units --plain --no-legend "$UNIT_PREFIX-*.timer" 2>/dev/null || true)
}

case "$mode" in
    apply)
        need_root "$@"
        if [ "$dry" = 1 ]; then
            [ "$hub" = 0 ] || { boot_copy_current && echo "# 0. Boot-Kopie $SBIN_COPY ist identisch mit diesem Script: ok" || echo "# 0. WARNUNG: Boot-Kopie $SBIN_COPY fehlt/ist anders - der echte Aufruf bricht ab; erst sudo $SELF --install-unit"; }
            echo "# 1. Rollback-Timer (${ROLLBACK_SECONDS} s) anlegen und pruefen - vor jeder Regel-Aenderung; sonst Abbruch ohne Aenderung:"
            echo "systemd-run --unit=$UNIT_PREFIX-<zeit>-<pid> --on-active=${ROLLBACK_SECONDS}s $SELF --remove$SET_ARG"
            echo "# 2. vorhandene $TAG-Regeln werden zuerst entfernt (idempotent, iptables -C/-D je Regel)"
            echo "# 3. Regeln einfuegen (Allow je Netz und Port, danach Drop); bei einem Fehler sofort alle $TAG-Regeln entfernen:"
            insert_rules
            exit 0
        fi
        require_boot_copy
        check_env
        command -v systemd-run >/dev/null || { echo "systemd-run fehlt - ohne Rollback-Timer keine Regeln" >&2; exit 1; }
        ARMED_UNIT=""
        arm_timer || { echo "Rollback-Timer konnte nicht scharfgeschaltet werden - keine Regel geaendert" >&2; exit 1; }
        stop_old_timers
        if ! remove_rules; then
            echo "Pruefung/Entfernen vorhandener Regeln scheiterte - Abbruch, Rollback-Timer bleibt scharf" >&2
            exit 1
        fi
        if insert_rules; then
            echo "Regeln aktiv. Rollback in ${ROLLBACK_SECONDS} s, ausser: sudo $SELF --confirm$SET_ARG"
        else
            echo "Fehler beim Setzen der Regeln - Rollback sofort" >&2
            remove_rules || true
            if rules_gone; then
                systemctl stop "$ARMED_UNIT" 2>/dev/null || true
            else
                echo "Cleanup nicht verifiziert - Rollback-Timer bleibt scharf ($ARMED_UNIT), Regeln pruefen!" >&2
            fi
            exit 1
        fi
        ;;
    confirm)
        need_root "$@"
        if [ "$dry" = 1 ]; then
            [ "$hub" = 0 ] || { boot_copy_current && echo "# Boot-Kopie $SBIN_COPY ist identisch: ok" || echo "# WARNUNG: Boot-Kopie $SBIN_COPY fehlt/ist anders - der echte Aufruf bricht ab; erst sudo $SELF --install-unit"; }
            echo "systemctl stop '$UNIT_PREFIX-*.timer'"
            echo "mkdir -p $STATE_DIR && touch $CONFIRMED"
            exit 0
        fi
        require_boot_copy
        # nur bestaetigen, wenn die Regeln wirklich da sind
        [ -n "$($IPT -S "$CHAIN" 2>/dev/null | grep -- "--comment $TAG" || true)" ] || { echo "keine $TAG-Regeln aktiv - nichts zu bestaetigen" >&2; exit 1; }
        stop_timers
        mkdir -p "$STATE_DIR"
        touch "$CONFIRMED"
        echo "bestaetigt: Rollback-Timer gestoppt, Regeln bleiben und werden beim Boot wiederhergestellt"
        ;;
    remove)
        need_root "$@"
        if [ "$dry" = 1 ]; then
            echo "# Regeln entfernen:"
            remove_rules
            stop_timers
            echo "rm -f $CONFIRMED"
            exit 0
        fi
        rm -f "$CONFIRMED"
        remove_rules
        stop_timers
        echo "Regeln entfernt"
        ;;
    restore)
        need_root "$@"
        # Boot: Hub-Regeln (eigener Satz) zuerst, aber nur wenn sie je bestaetigt wurden. Ohne Marke aendert sich am Edge-Ablauf nichts.
        # Docker veroeffentlicht 8094 am Hub-Container am Host-Filter vorbei; ohne diese Regeln waere der Port aus jedem Netz erreichbar.
        if [ "$hub" = 0 ] && [ -e "$HUB_CONFIRMED" ]; then
            hubargs=(--restore --hub); [ "$dry" = 1 ] && hubargs+=(--dry-run)
            "$SELF" "${hubargs[@]}" || echo "Hub-Regeln konnten nicht wiederhergestellt werden - Port 8094 ist OFFEN (Docker veroeffentlicht am Host-Filter vorbei), sofort pruefen!" >&2
        fi
        if [ "$dry" = 1 ]; then
            echo "# nur wenn $CONFIRMED existiert:"
            remove_rules
            insert_rules
            exit 0
        fi
        [ -e "$CONFIRMED" ] || { if [ "$hub" = 1 ]; then echo "Hub-Regeln nie bestaetigt ($CONFIRMED fehlt)" >&2; else echo "Regeln nie bestaetigt ($CONFIRMED fehlt) - Edge bleibt gesperrt" >&2; fi; exit 1; }
        check_env
        if remove_rules && insert_rules; then
            echo "bestaetigte Regeln wiederhergestellt"
        else
            remove_rules || true
            exit 1
        fi
        ;;
    install)
        need_root "$@"
        run install -m 0755 "$SELF" "$SBIN_COPY"
        for u in "${UNITS[@]}"; do
            run install -m 0644 "$UNIT_SRC/$u" "$UNIT_DST/$u"
        done
        run systemctl daemon-reload
        run systemctl enable "${UNITS[@]}"
        ;;
esac
