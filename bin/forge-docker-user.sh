#!/usr/bin/env bash
# forge-docker-user.sh - DOCKER-USER-Regeln fuer den Forge-Edge (Caddy auf 192.168.10.4:443/8443).
#
#   sudo forge-docker-user.sh             Regeln setzen (idempotent) + Rollback-Timer 300 s
#   sudo forge-docker-user.sh --confirm   Timer stoppen, Regeln bleiben
#   sudo forge-docker-user.sh --remove    Regeln entfernen (und Timer stoppen)
#   forge-docker-user.sh --dry-run [--remove]   nur die Kommandos ausgeben, nichts aendern
#
# Erlaubt 10.200.0.0/29, 192.168.10.0/29, 192.168.30.0/29 auf 192.168.10.4:443 und :8443, alles andere
# auf diese Ziele wird verworfen. Andere Ports, ufw und andere Chains bleiben unberuehrt.
# Docker DNATet vor DOCKER-USER, daher wird das Original-Ziel per conntrack (--ctorigdst/--ctorigdstport,
# nur Richtung ORIGINAL, damit Antwortpakete nicht getroffen werden) abgeglichen.
set -euo pipefail

EDGE_IP="${EDGE_IP:-192.168.10.4}"
NETS=(10.200.0.0/29 192.168.10.0/29 192.168.30.0/29)
PORTS=(443 8443)
CHAIN=DOCKER-USER
TAG=forge-edge
UNIT=forge-docker-user-rollback
ROLLBACK_SECONDS=300
IPT="${IPTABLES:-iptables}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

mode=apply
dry=0
for a in "$@"; do
    case "$a" in
        --confirm) mode=confirm ;;
        --remove) mode=remove ;;
        --dry-run) dry=1 ;;
        -h|--help) sed -n '2,12p' "$SELF"; exit 0 ;;
        *) echo "unbekannte Option: $a" >&2; exit 2 ;;
    esac
done

# Regel-Spezifikationen (ohne Aktion/Chain), in der Reihenfolge, in der sie in der Chain stehen sollen
specs=()
for p in "${PORTS[@]}"; do
    for n in "${NETS[@]}"; do
        specs+=("-p tcp -s $n -m conntrack --ctorigdst $EDGE_IP --ctorigdstport $p --ctdir ORIGINAL -m comment --comment $TAG -j ACCEPT")
    done
done
for p in "${PORTS[@]}"; do
    specs+=("-p tcp -m conntrack --ctorigdst $EDGE_IP --ctorigdstport $p --ctdir ORIGINAL -m comment --comment $TAG -j DROP")
done

run() {
    if [ "$dry" = 1 ]; then echo "$*"; else "$@"; fi
}

timer_cmd() {
    echo "systemd-run --unit=$UNIT --on-active=${ROLLBACK_SECONDS}s $SELF --remove"
}

stop_timer() {
    if [ "$dry" = 1 ]; then echo "systemctl stop $UNIT.timer"; return 0; fi
    systemctl stop "$UNIT.timer" 2>/dev/null || true
}

remove_rules() {
    local s
    for s in "${specs[@]}"; do
        if [ "$dry" = 1 ]; then
            echo "$IPT -D $CHAIN $s"
        else
            # shellcheck disable=SC2086  # s ist bewusst wortgetrennt
            while $IPT -C "$CHAIN" $s 2>/dev/null; do $IPT -D "$CHAIN" $s; done
        fi
    done
}

need_root() {
    if [ "$dry" = 0 ] && [ "$(id -u)" -ne 0 ]; then
        echo "als root ausfuehren (sudo $0 ${*})" >&2
        exit 1
    fi
}

case "$mode" in
    apply)
        need_root "$@"
        if [ "$dry" = 0 ]; then
            $IPT -n -L "$CHAIN" >/dev/null 2>&1 || { echo "Chain $CHAIN fehlt (laeuft Docker?)" >&2; exit 1; }
            command -v systemd-run >/dev/null || { echo "systemd-run fehlt - ohne Rollback-Timer keine Regeln" >&2; exit 1; }
            stop_timer
        else
            echo "# 1. vorhandene $TAG-Regeln werden zuerst entfernt (idempotent, iptables -C/-D je Regel)"
            echo "# 2. Regeln einfuegen (Allow je Netz und Port, danach Drop):"
        fi
        [ "$dry" = 1 ] || remove_rules
        i=1
        for s in "${specs[@]}"; do
            # shellcheck disable=SC2086
            run $IPT -I "$CHAIN" "$i" $s
            i=$((i + 1))
        done
        [ "$dry" = 1 ] && echo "# 3. Rollback-Timer (${ROLLBACK_SECONDS} s):"
        if [ "$dry" = 1 ]; then
            timer_cmd
        else
            systemd-run --unit="$UNIT" --on-active="${ROLLBACK_SECONDS}s" "$SELF" --remove >/dev/null
            echo "Regeln aktiv. Rollback in ${ROLLBACK_SECONDS} s, ausser: sudo $SELF --confirm"
        fi
        ;;
    confirm)
        need_root "$@"
        stop_timer
        [ "$dry" = 1 ] || echo "bestaetigt: Rollback-Timer gestoppt, Regeln bleiben (bis Reboot)"
        ;;
    remove)
        need_root "$@"
        [ "$dry" = 1 ] && echo "# Regeln entfernen:"
        remove_rules
        stop_timer
        [ "$dry" = 1 ] || echo "Regeln entfernt"
        ;;
esac
