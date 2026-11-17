#!/usr/bin/env bash
# =============================================================================
#  📈 Daily Stock Analysis – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/DailyStock-Analysis-Proxmox
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  daily_stock_analysis (https://github.com/ZhuLinsen/daily_stock_analysis):
#  KI-gestützte Aktien-Analyse für A-Shares, HK, US, JP, KR, TW und ETFs mit
#  Web-Workbench (React/Vite), FastAPI-Backend, SQLite, LLM-Anbindung
#  (OpenAI-kompatibel / Gemini / DeepSeek / Ollama lokal) und Push-Diensten.
#
#  Der Installer baut das React-Frontend auf dem Proxmox-Host (node:20-Container)
#  und pusht das fertige static/ in den CT – im Container läuft KEIN Node.js.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DailyStock-Analysis-Proxmox/main/install/daily-stock-analysis.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 220 --memory 4096 --port 8000
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.0"
APP_NAME="daily-stock-analysis"
UPSTREAM_REPO="https://github.com/ZhuLinsen/daily_stock_analysis.git"
APP_COMMIT=""             # leer = HEAD des Default-Branches (main)
CT_ID=""                  # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="dsa"
CT_STORAGE="local-lvm"
CT_ROOTFS=8               # GB – Code + venv + wheels + static/ + reports wachsen
CT_CORES=2
CT_MEMORY=2048            # MB – Full-Analysen brauchen 1 GB+ (Docker-Empfehlung)
CT_SWAP=1024              # MB – pandas/numpy/LiteLLM sind hungrig
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""             # nur bei statischer IP nötig
CT_PASSWORD=""            # leer = automatisch generieren
CT_SSHKEY=""              # Pfad ODER URL zu einer Public-Key-Datei (optional)
PORT=8000                 # Web-UI/API-Port im Container (App-Default)
APP_USER="dsa"            # Systembenutzer im Container (nie root!)
APP_UID=1000
APP_GID=1000
TZ_NAME=""                # leer = Zeitzone des Proxmox-Hosts übernehmen
GIT_REF=""                # leer = Default-Branch (main); sonst Tag/Branch/SHA
FORCE_RECREATE=false
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DailyStock-Analysis-Proxmox/main/install/daily-stock-analysis.sh)"'
NODE_IMAGE="node:20-slim"   # Frontend-Build (upstream Docker-Multi-Stage nutzt node:20)
# Wurzel des Installations-Repos (für die I18n-Patches) – wird in main() gesetzt.
REPO_ROOT=""

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerer TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Service), falls schon ein
# Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + daily-stock-analysis-Service):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/daily-stock-analysis-setup.log 2>/dev/null
            echo "--- journalctl -u daily-stock-analysis ---"
            journalctl -u daily-stock-analysis --no-pager 2>/dev/null | tail -n 25
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Spalten: VMID(1) NAME(2) STATUS(3) MEM(4) BOOTDISK(5) [LOCK(6)] [PID]
    # Der NAME ist bei jedem Format Spalte 2 (bei gesperrtem CTr rutscht die
    # PID/der Lock nach hinten – $NF wäre dann die PID, nicht der Name).
    if pct list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    # NAME ist Spalte 2 (siehe ct_exists-Kommentar) – NICHT $NF!
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" 'NR>1 && $2==h {print $1; exit}'
}

find_free_hostname() {
    # Hostname muss pro CT eindeutig sein – bei Kollision mit bestehendem CT
    # automatisch dsa2, dsa3, … wählen.
    local base="$CT_HOSTNAME" name="$CT_HOSTNAME" n=2
    while ct_exists "$name"; do
        name="${base}${n}"
        n=$((n + 1))
    done
    echo "$name"
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – apt/pip/git brauchen Namensauflösung.
    # Live-Fall (2026-11-10, GitHub-Backup): DNS war FLAKY – ein einzelner
    # getent-Erfolg reichte, Stunden später war wieder alles tot. Deshalb:
    # 3 Erfolge in Folge verlangen; eine einzige Störung → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts github.com >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht).
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts github.com >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).
  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1
  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.
  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --tz)            TZ_NAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --git-ref)       GIT_REF="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)         FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true; i=$((i+1)) ;;
            --update)        UPDATE=true; i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true; i=$((i+1)) ;;
            --status)        STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)         set -x; i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (–help zeigt alle Optionen)" ;;
        esac
    done
    # Port hart validieren – er landet direkt in der systemd-Unit im Container.
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
        die "Ungültiger Port: '$PORT' (1–65535 erwartet, z. B. --port 8000)"
    fi
    if [[ -n "$GIT_REF" && ! "$GIT_REF" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        die "Ungültiger git-ref: '$GIT_REF' (erlaubt: Buchstaben, Zahlen, . _ / -)"
    fi
}

print_help() {
    cat <<'EOF'
📈 Daily Stock Analysis – Proxmox-Installer (KI-Aktienanalyse, self-hosted)

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DailyStock-Analysis-Proxmox/main/install/daily-stock-analysis.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 220):
  --id ID          Container-ID (Default: nächste freie ab 200)
  --hostname NAME  Container-Hostname (Default: dsa, bei Kollision dsa2, dsa3 …)
  --storage NAME   Storage für rootfs (Default: local-lvm)
  --rootfs GB      Disk-Größe (Default: 8)
  --cores N        vCPUs (Default: 2)
  --memory MB      RAM (Default: 2048; Full-Analysen brauchen 1 GB+)
  --swap MB        Swap (Default: 1024; pandas/numpy/LiteLLM sind hungrig)
  --bridge BR      Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR        Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
  --gateway GW     Gateway für statische IP
  --password PW    Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD    Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT      Web-UI/API-Port im Container (Default: 8000)
  --tz ZONE        Zeitzone im Container (Default: wie Proxmox-Host, z. B. Europe/Berlin)
  --git-ref REF    Bestimmten Branch/Tag/SHA von upstream installieren
                   (Default: main / HEAD)
  --force          Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y       Rückfragen überspringen
  --update         App im bestehenden Container auf den neuesten Stand ziehen
  --uninstall      Container stoppen und löschen
  --status         Status anzeigen
  --debug          Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug

Hinweise:
  - Nach der Installation einen LLM-API-Key in der Weboberfläche unter
    "设置" → Modell-Anbieter eintragen (OpenAI-kompatibel, Gemini, DeepSeek,
    oder Ollama unter "本地模型"). Ohne Key läuft die UI, Analysen benötigen
    aber ein Modell.
  - Die Weboberfläche ist (upstream) auf Chinesisch.
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (PORT, TZ, APP_USER, …) kommen als Umgebungsvariablen via
# `pct exec -- env …` in den Container. Das vermeidet Escaping-Gruben komplett.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# Daily Stock Analysis – In-Container-Setup (idempotent, safe für Update/Re-Run)
# Variablen via env: PORT, TZ_NAME, APP_USER, APP_UID, APP_GID, APP_NAME,
#                    APP_DIR, GIT_REF
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo "✘ $1" >&2; }
die(){ err "$1"; exit 1; }
ok_echo(){ echo "✔ $1"; }
warn_echo(){ echo "⚠ $1"; }

: "${PORT:?PORT fehlt (env)}"
: "${APP_NAME:?APP_NAME fehlt (env)}"
: "${APP_USER:?APP_USER fehlt (env)}"
: "${APP_UID:?APP_UID fehlt (env)}"
: "${APP_GID:?APP_GID fehlt (env)}"
: "${APP_DIR:?APP_DIR fehlt (env)}"
CONFIG_DIR="/var/lib/${APP_NAME}"
LOG_DIR="/var/log/${APP_NAME}"
VENV="${APP_DIR}/.venv"
SERVICE_NAME="daily-stock-analysis"

echo ">>> Pakete installieren (Python, Node.js, Build-Toolchain, wkhtmltopdf, CJK-Fonts) ..."
# wkhtmltopdf + fonts-noto-cjk: Markdown → PNG-Reports (upstream Docker nutzt beides)
apt-get update -qq
apt-get install -y -qq \
    ca-certificates curl git tzdata gnupg \
    python3.11 python3.11-venv python3-pip python3-dev \
    build-essential pkg-config libffi-dev libssl-dev \
    wkhtmltopdf xvfb libjpeg62-turbo libxrender1 libxext6 \
    fonts-noto-cjk fontconfig sqlite3 >/dev/null

# Node.js >= 20 für den React/Vite-Build (Debian 12 bringt nur 18).
# nodesource-Repo ist die官方-sources.list-Variante (kein curl|bash).
if ! node --version >/dev/null 2>&1 || [ "$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)" -lt 20 ]; then
    echo ">>> Node.js >= 20 einrichten (nodesource) ..."
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
    apt-get install -y -qq nodejs >/dev/null
fi
node --version
npm --version

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
# dhclient-Hook: verhindert, dass Lease-Renewals /etc/resolv.conf überschreiben.
# (chattr +i funktioniert in unprivilegierten LXCs nicht – fehlendes Capability.)
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# DSA: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
if ! getent hosts github.com >/dev/null 2>&1; then
    die "DNS im Container defekt – Download von GitHub nicht möglich.
  Debug: cat /etc/resolv.conf && getent hosts github.com"
fi

echo ">>> Benutzer ${APP_USER} (${APP_UID}:${APP_GID}) und Verzeichnisse ..."
if ! getent group "${APP_GID}" >/dev/null 2>&1; then
    groupadd -g "${APP_GID}" "${APP_USER}"
fi
if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd -u "${APP_UID}" -g "${APP_GID}" -M -d "${CONFIG_DIR}" -s /usr/sbin/nologin "${APP_USER}"
fi
install -d -o "${APP_USER}" -g "${APP_USER}" -m 0750 "${CONFIG_DIR}"
install -d -o "${APP_USER}" -g "${APP_USER}" -m 0750 "${LOG_DIR}"
install -d -o root -g root -m 0755 "${APP_DIR}"

echo ">>> Klonen/Updaten des Upstream-Repos (${GIT_REF:-main}) ..."
CHECKOUT_DIR="${APP_DIR}/app"
if [ ! -d "${CHECKOUT_DIR}/.git" ]; then
    rm -rf "${CHECKOUT_DIR}"
    git clone --depth 1 --branch "${GIT_REF:-main}" https://github.com/ZhuLinsen/daily_stock_analysis.git "${CHECKOUT_DIR}"
else
    git -C "${CHECKOUT_DIR}" fetch --depth 1 origin "${GIT_REF:-main}" 2>/dev/null || \
        git -C "${CHECKOUT_DIR}" fetch origin
    git -C "${CHECKOUT_DIR}" checkout "${GIT_REF:-main}"
    git -C "${CHECKOUT_DIR}" reset --hard FETCH_HEAD 2>/dev/null || \
        git -C "${CHECKOUT_DIR}" reset --hard "origin/${GIT_REF:-main}"
    # -e data/logs/reports: Die Laufzeitdaten des App-Users dürfen ein Update
    # nicht löschen. -e static: das gebaute Frontend (npm run build) liegt dort
    # und wird nach dem Update neu gebaut – bei einem clean würde npm ci+build
    # es zwar neu erzeugen, aber ein Abbruch dazwischen ließe die App ohne UI.
    git -C "${CHECKOUT_DIR}" clean -fd -e data -e logs -e reports -e static
fi

echo ">>> I18n-Patches einspielen (Setup-Status mehrsprachig, en auf Wunsch) ..."
# Der Upstream liefert die Setup-Status-Karten (LLM 主渠道, 自选股, …) nur auf
# Chinesisch. Die Patches (vom Host in /root gepusht) bringen:
#  1. Backend: Übersetzungstabelle + language-Parameter + Accept-Language-Auswertung
#  2. Frontend: apiClient schickt Accept-Language aus localStorage['dsa.uiLanguage']
# Beide Patches sind idempotent (Marker-basiert) – Update/Re-Run unbedenklich.
python3 /root/patch-i18n.py \
    "${CHECKOUT_DIR}/src/services/system_config_service.py" \
    "${CHECKOUT_DIR}/api/v1/endpoints/system_config.py" \
    || die "I18n-Backend-Patch fehlgeschlagen – siehe Ausgabe oben."
python3 /root/patch-i18n-frontend.py \
    "${CHECKOUT_DIR}/apps/dsa-web/src/api/index.ts" \
    || die "I18n-Frontend-Patch fehlgeschlagen – siehe Ausgabe oben."
python3 /root/patch-i18n-error-ts.py \
    "${CHECKOUT_DIR}/apps/dsa-web/src/api/error.ts" \
    || die "I18n-Error-TS-Patch fehlgeschlagen – siehe Ausgabe oben."
ok_echo "I18n-Patches eingespielt"

echo ">>> Baue React/Vite-Frontend (npm ci + npm run build, im Container) ..."
# Upstream-Build identisch zum Dockerfile: apps/dsa-web → npm ci + npm run build,
# vite.config.ts (outDir ../../static) landet das Ergebnis unter ${CHECKOUT_DIR}/static.
# Der FastAPI-Server (api/app.py create_app(static_dir=…/static)) liefert es aus.
cd "${CHECKOUT_DIR}/apps/dsa-web"
npm ci --no-audit --no-fund || die "npm ci fehlgeschlagen – siehe Ausgabe oben."
npm run build || die "npm run build fehlgeschlagen – siehe Ausgabe oben."
if [ ! -f "${CHECKOUT_DIR}/static/index.html" ]; then
    die "Build lief durch, aber ${CHECKOUT_DIR}/static/index.html fehlt – vite-outDir prüfen."
fi
# static muss für den Service-User lesbar sein.
chown -R "${APP_USER}:${APP_USER}" "${CHECKOUT_DIR}/static"
ok_echo "Frontend gebaut: ${CHECKOUT_DIR}/static/index.html"

echo ">>> Python-vCPU-venv anlegen und Pakete installieren ..."
python3.11 -m venv "${VENV}"
"${VENV}/bin/pip" install --upgrade pip -q
# requirements.txt enthält u. a. ein pinned GitHub-Wheel (fxmacrodata) – braucht git+ssl.
"${VENV}/bin/pip" install -q -r "${CHECKOUT_DIR}/requirements.txt" || \
    die "pip install fehlgeschlagen – siehe Ausgabe oben.
  Tipp: In den CT wechseln (pct enter) und einzeln nachinstallieren:
  cd ${CHECKOUT_DIR} && ${VENV}/bin/pip install -r requirements.txt"

# efinance schreibt seinen Such-Cache (search-cache.json) INSIDE seines Pakets –
# der Container läuft als nicht-root, der Ordner muss also dem App-User gehören.
EF_DATA_DIR="$("${VENV}/bin/python" -c 'import efinance, pathlib; print(pathlib.Path(efinance.__file__).parent / "data")' 2>/dev/null || true)"
if [ -n "$EF_DATA_DIR" ]; then
    mkdir -p "$EF_DATA_DIR"
    chown -R "${APP_USER}:${APP_USER}" "$EF_DATA_DIR" || warn_echo "efinance-Cache chown fehlgeschlagen (evtl. unkritisch)"
fi

echo ">>> Verzeichnisse für Daten/Logs/Reports anlegen (Besitzer ${APP_USER}) ..."
for d in "${APP_DIR}/data" "${APP_DIR}/logs" "${APP_DIR}/reports" "${CHECKOUT_DIR}/data" "${CHECKOUT_DIR}/logs" "${CHECKOUT_DIR}/reports"; do
    install -d -o "${APP_USER}" -g "${APP_USER}" -m 0750 "$d"
done

echo ">>> .env anlegen (falls nicht vorhanden) ..."
if [ ! -f "${APP_DIR}/.env" ]; then
    cp "${CHECKOUT_DIR}/.env.example" "${APP_DIR}/.env"
    # Platzhalter/Defaults für den Betrieb als systemd-Service.
    # Achtung: nur Zeilen ERSETZEN, die in der Vorlage existieren – ein
    # sed auf eine nicht vorhandene Variable legt sonst eine Zeile an, die
    # die Vorlage gar nicht kennt (und die Doku-Imports verwirrt).
    sed -i 's/^STOCK_LIST=.*/STOCK_LIST=/' "${APP_DIR}/.env"
    sed -i 's/^SCHEDULE_ENABLED=.*/SCHEDULE_ENABLED=false/' "${APP_DIR}/.env"
    sed -i "s|^WEBUI_HOST=.*|WEBUI_HOST=0.0.0.0|" "${APP_DIR}/.env"
    sed -i "s|^WEBUI_PORT=.*|WEBUI_PORT=${PORT}|" "${APP_DIR}/.env"
    sed -i 's/^WEBUI_AUTO_BUILD=.*/WEBUI_AUTO_BUILD=false/' "${APP_DIR}/.env"
    # WEBUI_ENABLED=true in der Vorlage: Die Zeile heißt im .env.example
    # "WEBUI_ENABLED=false" – wir drehen sie auf true, damit der Service
    # (main.py --serve-only) den Webserver startet.
    sed -i 's/^WEBUI_ENABLED=.*/WEBUI_ENABLED=true/' "${APP_DIR}/.env"
    # Leere LLM-Kanäle aus der .env entfernen: Die Vorlage bringt mehrere
    # auskommentierte Beispiel-Kanäle (LLM_OPENROUTER_API_KEY=sk-or-xxx …).
    # Aktiviert man einen, aber lässt den Key leer, meckert das Backend beim
    # Speichern ("missing_api_key" pro leerem Kanal). Wir entfernen daher alle
    # Zeilen "LLM_*_API_KEY=" ohne Wert – die UI startet mit sauberen Kanälen
    # und der User trägt genau einen Key ein.
    sed -i '/^LLM_[A-Z0-9_]*_API_KEY=$/d' "${APP_DIR}/.env"
    # .env.local (falls vorhanden) ist die persistente Runtime-Config der App
    # (wird von der WebUI beim Speichern neu geschrieben) – nicht anfassen.
    chown "${APP_USER}:${APP_USER}" "${APP_DIR}/.env"
    ok_echo ".env aus Vorlage erstellt (STOCK_LIST leer, Auto-Build aus, leere LLM-Keys entfernt)"
else
    ok_echo ".env bereits vorhanden – bleibt unverändert"
fi

echo ">>> Timezone setzen (TZ=${TZ_NAME:-Etc/UTC}) ..."
if [ -n "${TZ_NAME:-}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ_NAME}" /etc/localtime
    echo "${TZ_NAME}" > /etc/timezone
    chown "${APP_USER}:${APP_USER}" /etc/localtime 2>/dev/null || true
fi

echo ">>> systemd-Unit schreiben (User ${APP_USER}, Restart=always) ..."
# Unquotiertes Heredoc: ${PORT}/${VENV}/${APP_USER} müssen expandieren.
cat > /etc/systemd/system/${SERVICE_NAME}.service <<UNITEOF
[Unit]
Description=Daily Stock Analysis (DSA) – KI-Aktienanalyse Web/API
Documentation=https://github.com/HatchetMan111/DailyStock-Analysis-Proxmox
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${CHECKOUT_DIR}
EnvironmentFile=${APP_DIR}/.env
# Web/API-Server + Runtime-Scheduler (geplante Analysen).
# WEBUI_AUTO_BUILD=false: Das Frontend wird vom Installer (npm im Container)
# gebaut und liegt in ${CHECKOUT_DIR}/static – kein Auto-Build beim Boot.
ExecStart=${VENV}/bin/python main.py --serve-only --host 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGINT
LimitNOFILE=8192

StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
UNITEOF

echo ">>> Unit aktivieren und starten ..."
systemctl daemon-reload
systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
# enable + RESTART (nicht --now): startet garantiert mit dem neuen Code,
# egal ob der Service vorher lief oder nicht.
systemctl restart ${SERVICE_NAME}

echo ">>> Warten, bis die Weboberfläche auf Port ${PORT} antwortet ..."
CODE=""
for _ in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)
    if [ "$CODE" = "200" ]; then
        break
    fi
    sleep 1
done
if [ "$CODE" != "200" ]; then
    err "Web-UI antwortet nicht (letzter HTTP-Code: ${CODE:-000})"
    journalctl -u ${SERVICE_NAME} --no-pager 2>/dev/null | tail -n 30 || true
    die "Daily Stock Analysis läuft nicht wie erwartet – Logs oben."
fi
ok_echo "Web-UI antwortet (HTTP 200 auf /health)"

echo ">>> Setup abgeschlossen."
INNEREOF
}

# ── I18n-Patches bereitstellen ─────────────────────────────────────────────
# Die Patches liegen im Installer-Repo unter install/patches/. Beim Einzeiler
# (wget) ist das Repo nicht da – dann werden sie per wget von der Raw-URL
# nachgeladen (identisch zu den Repo-Dateien). Idempotent.
write_i18n_patches() {
    local src_p1="$REPO_ROOT/install/patches/patch-i18n.py"
    local src_p2="$REPO_ROOT/install/patches/patch-i18n-frontend.py"
    local src_p3="$REPO_ROOT/install/patches/patch-i18n-error-ts.py"
    if [[ -f "$src_p1" && -f "$src_p2" && -f "$src_p3" ]]; then
        cp "$src_p1" "$TMP_DIR/patch-i18n.py"
        cp "$src_p2" "$TMP_DIR/patch-i18n-frontend.py"
        cp "$src_p3" "$TMP_DIR/patch-i18n-error-ts.py"
        return 0
    fi
    # Fallback für den wget-Einzeiler: Patches von der Raw-URL laden.
    local base="https://raw.githubusercontent.com/HatchetMan111/DailyStock-Analysis-Proxmox/main/install/patches"
    wget -qO "$TMP_DIR/patch-i18n.py" "$base/patch-i18n.py" || die "I18n-Patch (Backend) konnte nicht geladen werden: $base/patch-i18n.py"
    wget -qO "$TMP_DIR/patch-i18n-frontend.py" "$base/patch-i18n-frontend.py" || die "I18n-Patch (Frontend) konnte nicht geladen werden: $base/patch-i18n-frontend.py"
    wget -qO "$TMP_DIR/patch-i18n-error-ts.py" "$base/patch-i18n-error-ts.py" || die "I18n-Patch (error.ts) konnte nicht geladen werden: $base/patch-i18n-error-ts.py"
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere Daily Stock Analysis im Container $ct_id"
    # DNS-Setup macht das Inner-Script selbst (inkl. dhclient-Hook-Fallback).
    local tz_name
    if [[ -z "$TZ_NAME" ]]; then
        if [[ -r /etc/timezone ]]; then
            TZ_NAME=$(head -n1 /etc/timezone | tr -d '[:space:]' || true)
        fi
        if [[ -z "$TZ_NAME" ]] && command -v timedatectl >/dev/null 2>&1; then
            TZ_NAME=$(timedatectl show -p Timezone --value 2>/dev/null | head -n1 || true)
        fi
        tz_name="${TZ_NAME:-Etc/UTC}"
    else
        tz_name="$TZ_NAME"
    fi
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # I18n-Patches (Setup-Status mehrsprachig) mit in den Container schieben.
    write_i18n_patches
    pct push "$ct_id" "$TMP_DIR/patch-i18n.py" /root/patch-i18n.py
    pct push "$ct_id" "$TMP_DIR/patch-i18n-frontend.py" /root/patch-i18n-frontend.py
    pct push "$ct_id" "$TMP_DIR/patch-i18n-error-ts.py" /root/patch-i18n-error-ts.py
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden (sonst meldet der Host Erfolg, der CT nicht).
    pct exec "$ct_id" -- env PORT="$PORT" TZ_NAME="$tz_name" \
        APP_NAME="$APP_NAME" APP_USER="$APP_USER" APP_UID="$APP_UID" APP_GID="$APP_GID" \
        APP_DIR="/opt/${APP_NAME}" GIT_REF="${GIT_REF:-main}" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/daily-stock-analysis-setup.log'
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code="" state=""

    header "✅ Verifikation"

    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    if [[ "$state" != *"running"* ]]; then
        die "Container $ct_id läuft nicht (Status: ${state})."
    fi
    ok "Container läuft (${state})"

    # Service-Status
    local svc
    svc=$(pct exec "$ct_id" -- systemctl is-active daily-stock-analysis 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$svc" != "active" ]]; then
        err "Service daily-stock-analysis ist nicht aktiv (Status: ${svc:-unbekannt})."
        info "Letzte Service-Logs:"
        pct exec "$ct_id" -- journalctl -u daily-stock-analysis --no-pager 2>/dev/null | tail -n 30 | sed 's/^/    /' || true
        die "Service läuft nicht – siehe Logs oben."
    fi
    ok "systemctl is-active daily-stock-analysis: active"

    # HTTP-Check gegen /health (Port aus dem Container prüfen – nicht blind 8000)
    local ip
    ip=$(get_ct_ip "$ct_id")
    info "Prüfe HTTP auf http://127.0.0.1:${PORT}/health ..."
    while [[ $tries -lt 30 ]]; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/health" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$code" == "200" ]]; then
            break
        fi
        tries=$((tries + 1))
        sleep 1
    done
    if [[ "$code" != "200" ]]; then
        err "HTTP-Check fehlgeschlagen (letzter Code: ${code:-000})"
        pct exec "$ct_id" -- journalctl -u daily-stock-analysis --no-pager 2>/dev/null | tail -n 30 | sed 's/^/    /' || true
        die "Web-UI antwortet nicht auf Port ${PORT}."
    fi
    ok "HTTP /health: 200 OK"

    # Web-UI über die Container-IP (Bind auf 0.0.0.0 muss erreichbar sein)
    info "Prüfe Web-UI von außen (http://${ip}:${PORT}/) ..."
    code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://${ip}:${PORT}/" 2>/dev/null || true)
    if [[ "$code" == "200" || "$code" == "307" || "$code" == "302" ]]; then
        ok "Web-UI erreichbar unter http://${ip}:${PORT} (HTTP ${code})"
    else
        warn "Web-UI von außen nicht erreichbar (HTTP ${code:-000}) – Firewall/Bridge prüfen."
        info "Im Container selbst antwortet sie (127.0.0.1:${PORT} = 200),"
        info "also prüfe: pct exec $ct_id -- ss -tlnp | grep ${PORT}  und ggf. Host-Firewall."
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    local ct_id="$1" ip
    ip=$(get_ct_ip "$ct_id")

    echo
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  🎉 Daily Stock Analysis ist installiert${NC}"
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo "  Container-ID:  ${ct_id}"
    echo "  Hostname:      ${CT_HOSTNAME}"
    echo "  Container-IP:  ${ip}"
    echo "  Web-UI:        http://${ip}:${PORT}"
    echo "  API-Doku:      http://${ip}:${PORT}/docs"
    echo
    echo "  Noch kein LLM-Key? Weboberfläche öffnen → Einstellungen (设置) →"
    echo "  Modell-Anbieter wählen und API-Key eintragen"
    echo "  (OpenAI-kompatibel / Gemini / DeepSeek / Ollama lokal)."
    echo
    echo "  Service:       systemctl status daily-stock-analysis   (im Container)"
    echo "  Logs:          pct exec ${ct_id} -- journalctl -u daily-stock-analysis -f"
    echo "  Setup-Log:     pct exec ${ct_id} -- tail -f /var/log/daily-stock-analysis-setup.log"
    echo "  Root-Login:    pct enter ${ct_id}"
    echo
    echo "  Update:        ${ONE_LINER} --update"
    echo "  Deinstall:     ${ONE_LINER} --uninstall"
    echo "  Status:        ${ONE_LINER} --status"
    echo
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "🚀 Daily Stock Analysis – Installation"

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Dieses Script muss als root auf dem Proxmox-Host laufen.
  Ausführen: sudo $0 $*"
    fi
    # Pflicht für den Host: pct/pvesh (Proxmox), wget (Installer-Download), git.
    # Alles andere (node, npm, python, wkhtmltopdf …) wird im CONTAINER installiert –
    # der Host bleibt unberührt (Community-Scripts-Prinzip).
    for cmd in pct pvesh wget git; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            die "Benötigtes Kommando fehlt: $cmd"
        fi
    done

    # Vorhandenen CT mit gleichem Hostname finden (idempotent / --force)
    local existing_id
    existing_id=$(find_ct_id_by_hostname)
    if [[ -n "$existing_id" ]]; then
        if [[ "$FORCE_RECREATE" == "true" ]]; then
            warn "Container $existing_id (Hostname $CT_HOSTNAME) existiert bereits – --force: wird gelöscht und neu angelegt."
            pct stop "$existing_id" 2>/dev/null || true
            pct destroy "$existing_id" --purge || die "Container $existing_id konnte nicht gelöscht werden."
        else
            warn "Container $existing_id (Hostname $CT_HOSTNAME) existiert bereits."
            warn "Nutze --update zum Aktualisieren oder --force zum Neu-Anlegen."
            die "Abbruch – nichts geändert."
        fi
    fi

    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
    fi
    if pct list 2>/dev/null | awk '{print $1}' | grep -qx "$CT_ID"; then
        die "Container-ID $CT_ID ist bereits vergeben – andere ID wählen (--id N)."
    fi
    # Hostname darf nicht mit einem anderen laufenden CT kollidieren
    if [[ -n "$(find_ct_id_by_hostname)" && "$(find_ct_id_by_hostname)" != "$CT_ID" ]]; then
        CT_HOSTNAME=$(find_free_hostname)
    fi

    CT_PASSWORD="${CT_PASSWORD:-$(openssl rand -base64 18)}"

    # SSH-Key (Datei oder URL) auflösen
    local sshkey_file=""
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http* ]]; then
            sshkey_file="$TMP_DIR/authorized_keys"
            wget -qO "$sshkey_file" "$CT_SSHKEY" || die "SSH-Key von URL konnte nicht geladen werden: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            sshkey_file="$CT_SSHKEY"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
    fi

    info "Erstelle unprivilegierten LXC-Container ${CT_ID} (${CT_HOSTNAME}) ..."
    info "  Vorlage: Debian 12 (bookworm) – wie upstream Dockerfile-Basis"
    # Template sicherstellen (einmalig, idempotent).
    # Robust gegen Versions-Suffixe: Templates heißen "debian-12-standard" ODER
    # "debian-12.12-standard_..." – wir matchen auf beides (grep -E) und
    # priorisieren das neueste per sort -V. Kein `grep -q`-短路: der Download
    # soll nur laufen, wenn WIRKLICH keins da ist.
    if ! pveam list local 2>/dev/null | grep -qE "debian-12[^ ]*standard"; then
        info "Lade Debian-12-Template (einmalig) ..."
        pveam update || true
        local tpl
        tpl=$(pveam available 2>/dev/null | grep -E "debian-12[^ ]*standard" | tail -1 | awk '{print $2}')
        if [[ -z "$tpl" ]]; then
            die "Kein Debian-12-Template in pveam available gefunden.
  Prüfe: pveam available | grep debian-12"
        fi
        pveam download local "$tpl" || die "Template-Download fehlgeschlagen: $tpl"
    fi
    local template
    template=$(pveam list local 2>/dev/null | grep -E "debian-12[^ ]*standard" | sort -V | tail -1 | awk '{print $1}')
    if [[ -z "$template" ]]; then
        die "Kein Debian-12-Template gefunden – bitte prüfen: pveam list local"
    fi
    ok "Template: $template"

    local net_config="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
    if [[ "$CT_IP" != "dhcp" && -n "$CT_GATEWAY" ]]; then
        net_config="${net_config},gw=${CT_GATEWAY}"
    fi
    local ssh_keys=""
    if [[ -n "$sshkey_file" ]]; then
        ssh_keys="--ssh-public-keys $sshkey_file"
    fi

    pct create "$CT_ID" "$template" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net_config" \
        --nameserver "1.1.1.1 8.8.8.8" \
        --onboot 1 \
        --features nesting=1 \
        --unprivileged 1 \
        --password "$CT_PASSWORD" \
        $ssh_keys \
        --description "Daily Stock Analysis (KI-Aktienanalyse) – verwaltet durch daily-stock-analysis.sh" \
        || die "pct create fehlgeschlagen – siehe Ausgabe oben."

    ok "Container ${CT_ID} erstellt (unprivilegiert, nesting=1, onboot=1)"

    # Starten und auf Netz warten
    pct start "$CT_ID" || die "pct start fehlgeschlagen."
    wait_for_ct_network "$CT_ID" || die "Kein Netzwerk im Container – Abbruch."
    verify_ct_dns "$CT_ID" || die "DNS im Container defekt – Abbruch."

    # ALLES im Container: run_inner_setup klont das Repo, baut das Frontend
    # (node+npm werden im CT installiert) und richtet den Service ein –
    # der Host braucht nur pct/wget/git.
    run_inner_setup "$CT_ID"
    # Commit-Metadaten für die Summary aus dem Container lesen (|| true-Wrapper
    # gegen pct-exec-Fehlchläge unter pipefail).
    APP_COMMIT=$(pct exec "$CT_ID" -- git -C /opt/daily-stock-analysis/app rev-parse --short HEAD 2>/dev/null | tail -n 1 || true)
    APP_COMMIT="${APP_COMMIT:-unbekannt}"
    ok "App installiert (Commit ${APP_COMMIT})"

    # Service neu starten, damit er das gebaute static/ garantiert sieht
    pct exec "$CT_ID" -- systemctl restart daily-stock-analysis || die "Service-Neustart fehlgeschlagen."

    verify_installation "$CT_ID"
    print_summary "$CT_ID"
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update – Daily Stock Analysis"

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Dieses Script muss als root auf dem Proxmox-Host laufen.
  Ausführen: sudo $0 $*"
    fi

    local ct_id="$CT_ID"
    if [[ -z "$ct_id" ]]; then
        ct_id=$(find_ct_id_by_hostname)
    fi
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.
  Mit --id N lässt sich die ID explizit angeben."
    fi
    ensure_ct_running "$ct_id" || die "Container $ct_id konnte nicht gestartet werden."

    # Inner-Script erneut laufen lassen: aktualisiert Code + Frontend IM CT
    # (git fetch + npm ci/build), macht pip install, startet den Service neu.
    run_inner_setup "$ct_id"
    pct exec "$ct_id" -- systemctl restart daily-stock-analysis || die "Service-Neustart fehlgeschlagen."

    verify_installation "$ct_id"
    print_summary "$ct_id"
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstall – Daily Stock Analysis"

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Dieses Script muss als root auf dem Proxmox-Host laufen.
  Ausführen: sudo $0 $*"
    fi

    local ct_id="$CT_ID"
    if [[ -z "$ct_id" ]]; then
        ct_id=$(find_ct_id_by_hostname)
    fi
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
    fi

    warn "Container ${ct_id} (${CT_HOSTNAME}) wird SOFORT gelöscht (inkl. aller Daten)."
    if [[ "$ASSUME_YES" != "true" ]]; then
        read -r -p "Wirklich deinstallieren? [j/N] " answer
        if [[ ! "$answer" =~ ^[jJ] ]]; then
            info "Abgebrochen – nichts geändert."
            exit 0
        fi
    fi

    pct stop "$ct_id" 2>/dev/null || true
    pct destroy "$ct_id" --purge || die "Container $ct_id konnte nicht gelöscht werden."
    ok "Container $ct_id gelöscht."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status – Daily Stock Analysis"

    local ct_id="$CT_ID"
    if [[ -z "$ct_id" ]]; then
        ct_id=$(find_ct_id_by_hostname)
    fi
    if [[ -z "$ct_id" ]]; then
        info "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        exit 0
    fi
    if ! pct status "$ct_id" &>/dev/null; then
        err "Container $ct_id existiert nicht."
        exit 1
    fi

    local state ip
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}')
    if [[ "$state" == "running" ]]; then
        ip=$(get_ct_ip "$ct_id")
        echo "  Container:   ${ct_id} (${CT_HOSTNAME}) – ${state}"
        echo "  IP:          ${ip}"
        echo "  Web-UI:      http://${ip}:${PORT}"
        local svc
        svc=$(pct exec "$ct_id" -- systemctl is-active daily-stock-analysis 2>/dev/null | tr -d '[:space:]' || true)
        echo "  Service:     ${svc:-unbekannt}"
    else
        echo "  Container:   ${ct_id} (${CT_HOSTNAME}) – ${state}"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    # REPO_ROOT = Wurzel des Installations-Repos (für die I18n-Patches).
    # Robust gegen Symlinks: dirname des Scripts, normalisiert.
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    export REPO_ROOT

    parse_args "$@"
    # TMP_DIR erst hier setzen: cleanup() (EXIT-Trap) läuft auch bei
    # parse_args-Fehlern – vorher darf nichts in /tmp liegen, sonst räumt
    # cleanup() ein nicht existierendes Verzeichnis weg (harmlos, aber laut).
    # Und: mkdir -p "$src_dir" in do_install/do_update braucht es.
    TMP_DIR="$(mktemp -d)"
    export TMP_DIR

    if [[ "$UPDATE" == "true" ]]; then
        do_update
    elif [[ "$UNINSTALL" == "true" ]]; then
        do_uninstall
    elif [[ "$STATUS_CHECK" == "true" ]]; then
        do_status
    else
        do_install
    fi
}

main "$@"