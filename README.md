# 📈 Daily Stock Analysis – Proxmox-Installer

KI-gestützte Aktien-Analyse (A-Shares, HK, US, JP, KR, TW, ETFs) als
self-hosted LXC-Container auf Proxmox VE – im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

App-Quelle: [ZhuLinsen/daily_stock_analysis](https://github.com/ZhuLinsen/daily_stock_analysis)
· FastAPI-Backend · React/Vite-Frontend · SQLite · LLM-Anbindung
(OpenAI-kompatibel, Gemini, DeepSeek, Ollama lokal) · Push-Dienste
(企业微信/飞书/Telegram/Discord/Slack/E-Mail).

---

## 🚀 Einzeiler-Installation

Auf dem Proxmox-Host als root:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DailyStock-Analysis-Proxmox/main/install/daily-stock-analysis.sh)"
```

Der Installer:

1. erstellt selbstständig einen **unprivilegierten LXC-Container** (Debian 12,
   nächste freie ID ab 200, Standard: 2 vCPU / 2 GB RAM / 8 GB Disk, `onboot:1`,
   `nesting=1`)
2. klont das App-Repo von GitHub ( upstream `ZhuLinsen/daily_stock_analysis`)
3. baut das React/Vite-Frontend **auf dem Proxmox-Host** (node:20-Container,
   Fallback: Host-Node) und pusht das fertige `static/` in den Container –
   im Container läuft kein Node.js
4. installiert Python 3.11 + alle Abhängigkeiten in ein venv im Container
5. richtet eine systemd-Unit ein (`daily-stock-analysis.service`,
   `Restart=always`, `After=network-online.target`)
6. prüft am Ende selbst: Service aktiv + Web-UI antwortet (HTTP 200 auf
   `/health`) + Summary mit Container-IP und URL

Danach ist die Weboberfläche erreichbar unter:

```
http://<CONTAINER-IP>:8000
```

### Optionen

Alles hinter dem schließenden Anführungszeichen anhängen:

```bash
... " --id 220 --memory 4096 --cores 4 --port 8000
```

| Option | Default | Bedeutung |
|---|---|---|
| `--id ID` | nächste freie ab 200 | Container-ID |
| `--hostname NAME` | `dsa` (bei Kollision `dsa2`, `dsa3` …) | Container-Hostname |
| `--storage NAME` | `local-lvm` | Storage für rootfs |
| `--rootfs GB` | 8 | Disk-Größe |
| `--cores N` | 2 | vCPUs |
| `--memory MB` | 2048 | RAM (Full-Analysen brauchen 1 GB+) |
| `--swap MB` | 1024 | Swap (pandas/numpy/LiteLLM sind hungrig) |
| `--bridge BR` | `vmbr0` | Netzwerk-Bridge |
| `--ip CIDR` | `dhcp` | statische IP, z. B. `192.168.1.50/24` (+ `--gateway`) |
| `--gateway GW` | – | Gateway für statische IP |
| `--password PW` | generiert | Root-Passwort im CT |
| `--sshkey PFAD` | – | Public-Key-Datei oder URL |
| `--port PORT` | 8000 | Web-UI/API-Port im Container |
| `--tz ZONE` | Host-Zeitzone | z. B. `Europe/Berlin` |
| `--git-ref REF` | `main` | Branch/Tag/SHA von upstream |
| `--force` | – | Vorhandenen CT mit gleichem Hostname löschen + neu anlegen |
| `--yes` / `-y` | – | Rückfragen überspringen |

### Modi

| Modus | Bedeutung |
|---|---|
| *(Default)* | Neu-Installation |
| `--update` | App im bestehenden CT auf neuesten Stand ziehen (Code + Frontend + pip) |
| `--uninstall` | Container stoppen + löschen |
| `--status` | Status anzeigen (CT-Status, IP, Web-UI, Service) |
| `--debug` | Vollständiger `bash -x`-Trace (bei Fehlern) |

### Nach der Installation

Die Weboberfläche ist (upstream) **auf Chinesisch**. Einen LLM-API-Key
trägst du später in der UI ein:

> **设置 → Modell-Anbieter → API-Key** (OpenAI-kompatibel / Gemini /
> DeepSeek / Ollama unter „本地模型")

Ohne Key läuft die UI, Analysen benötigen aber ein Modell.

---

## 🔄 Update / Deinstall

```bash
# Update
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DailyStock-Analysis-Proxmox/main/install/daily-stock-analysis.sh)" --update

# Deinstall (fragt nach, löscht Container inkl. Daten)
... " --uninstall

# Status
... " --status
```

---

## 🛠️ Debugging

Bei Fehlern gibt der Installer die **komplette Fehlerkette** aus
(Exit-Code, Zeile, Befehl, letzte Logzeilen, Container-Logs). Für einen
vollständigen Trace:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DailyStock-Analysis-Proxmox/main/install/daily-stock-analysis.sh)" --debug
```

Das komplette Log liegt unter `/tmp/daily-stock-analysis-installer-*.log`.

---

## 🧪 Entwicklung / Tests

```bash
bash -n install/daily-stock-analysis.sh     # Syntax
shellcheck -x -S error install/daily-stock-analysis.sh
bash test/mock-harness.sh                   # Mock-Harness (16/16)
```

Der Mock-Harness testet die Host-Seite des Installers (pct/git/docker-Mocks)
ohne echten Proxmox-Host.

---

## 📁 Struktur

```
DailyStock-Analysis-Proxmox/
├── install/
│   └── daily-stock-analysis.sh      # Einzeiler-Installer
├── systemd/
│   └── daily-stock-analysis.service # Referenz-Unit (Doku)
├── test/
│   └── mock-harness.sh              # Mock-Tests
└── README.md
```

## 📜 Lizenz

Der Installer-Code in diesem Repo: MIT (wie der Nutzer-Konventionen).
Die App selbst: siehe [upstream-Lizenz](https://github.com/ZhuLinsen/daily_stock_analysis).