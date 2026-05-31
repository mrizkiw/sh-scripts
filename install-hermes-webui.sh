#!/usr/bin/env bash
#
# install_hermes_stack.sh
# ============================================================
# Install Hermes Agent + Hermes WebUI dari nol di Linux (Ubuntu/Debian/Fedora).
# + OPSIONAL: restore data migrasi dari tarball.
#
# AMAN dijalankan di VPS fresh. Idempotent (boleh diulang).
#
# CARA PAKAI:
#   # Install fresh (tanpa restore):
#   bash install_hermes_stack.sh
#
#   # Install + restore dari backup:
#   bash install_hermes_stack.sh ~/hermes_migrate_XXXXXX.tar.gz
#
#   # Expose WebUI ke internet (buka port di firewall juga!):
#   HOST=0.0.0.0 bash install_hermes_stack.sh
#
#   # Ganti port:
#   PORT=9090 bash install_hermes_stack.sh
#
#   # Install saja, jangan jalankan WebUI:
#   NO_START=1 bash install_hermes_stack.sh
#
# ENV OPTIONS:
#   HOST        Bind address WebUI (default: 0.0.0.0)
#   PORT        Port WebUI (default: 8787)
#   NO_START    1 = install saja, jangan auto-start (default: 0)
#   WEBUI_REPO  Git repo WebUI (default: nesquena/hermes-webui)
#   WEBUI_DIR   Direktori install WebUI (default: ~/hermes-webui)
# ============================================================
set -euo pipefail

# ---- konfigurasi (override via env) ----
WEBUI_REPO="${WEBUI_REPO:-https://github.com/nesquena/hermes-webui.git}"
WEBUI_DIR="${WEBUI_DIR:-$HOME/hermes-webui}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8787}"
NO_START="${NO_START:-0}"
TARBALL="${1:-}"

# ---- helper ----
RED='\033[1;31m'; GRN='\033[1;32m'; CYN='\033[1;36m'; YLW='\033[1;33m'; NC='\033[0m'
log(){ printf "${CYN}[hermes-stack]${NC} %s\n" "$*"; }
ok(){  printf "${GRN}[hermes-stack] ✓${NC} %s\n" "$*"; }
warn(){ printf "${YLW}[hermes-stack] ⚠${NC} %s\n" "$*"; }
die(){ printf "${RED}[hermes-stack] FATAL:${NC} %s\n" "$*" >&2; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Hermes Agent + WebUI — Installer & Restorer   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ---- 1. dependensi sistem ----
log "cek & install dependensi sistem..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq
  apt-get install -y -qq python3 python3-venv python3-pip git curl ca-certificates sqlite3 2>/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y python3 python3-pip git curl ca-certificates sqlite
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 python3-pip git curl ca-certificates sqlite
else
  warn "package manager tidak dikenal — pastikan python3/venv/git/curl sudah ada."
fi
command -v python3 >/dev/null 2>&1 || die "python3 tidak ada setelah install."
ok "dependensi sistem siap (python3=$(python3 --version 2>&1 | awk '{print $2}'))"

# ---- 2. install Hermes Agent ----
if command -v hermes >/dev/null 2>&1; then
  ok "Hermes sudah terpasang: $(hermes --version 2>/dev/null | head -1)"
else
  log "install Hermes Agent (installer resmi NousResearch)..."
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash

  # pastikan PATH include lokasi binary hermes
  for p in "$HOME/.local/bin" "/usr/local/bin" "$HOME/.hermes/bin"; do
    [[ -d "$p" ]] && export PATH="$p:$PATH"
  done

  # reload shell profile
  if [[ -f "$HOME/.bashrc" ]]; then
    source "$HOME/.bashrc" 2>/dev/null || true
  fi

  command -v hermes >/dev/null 2>&1 || die "hermes tidak ditemukan di PATH. Buka ulang shell lalu jalankan lagi."
  ok "Hermes terpasang: $(hermes --version 2>/dev/null | head -1)"
fi

# ---- 3. restore dari tarball (opsional) ----
if [[ -n "$TARBALL" ]]; then
  if [[ ! -f "$TARBALL" ]]; then
    die "tarball tidak ditemukan: $TARBALL"
  fi

  log "restore data migrasi dari: $TARBALL"

  # cek tidak ada proses hermes aktif
  if pgrep -af "hermes|server.py|gateway" 2>/dev/null | grep -v "$0" | grep -v "install_hermes" >/dev/null 2>&1; then
    warn "ada proses hermes/webui aktif. Stop dulu sebelum restore."
    die "jalankan: hermes gateway stop ; pkill -f server.py ; lalu ulangi."
  fi

  HERMES_DIR="$HOME/.hermes"
  STAMP="$(date +%Y%m%d_%H%M%S)"

  # backup yang lama kalau ada
  if [[ -d "$HERMES_DIR" ]]; then
    log "backup ~/.hermes lama → ~/.hermes.bak.${STAMP}"
    mv "$HERMES_DIR" "${HERMES_DIR}.bak.${STAMP}"
  fi

  # extract
  log "extract tarball..."
  tar -C "$HOME" -xf "$TARBALL"

  # verifikasi
  log "verifikasi file penting..."
  ALL_OK=true
  for f in config.yaml .env state.db; do
    if [[ -e "$HERMES_DIR/$f" ]]; then
      ok "$f"
    else
      warn "HILANG: $f"
      ALL_OK=false
    fi
  done

  # cek profile
  for profile_dir in "$HERMES_DIR"/profiles/*/; do
    if [[ -d "$profile_dir" ]]; then
      pname=$(basename "$profile_dir")
      ok "profile: $pname"
    fi
  done

  # cek webui data
  [[ -d "$HERMES_DIR/webui/sessions" ]] && ok "webui sessions"
  [[ -d "$HERMES_DIR/webui/attachments" ]] && ok "webui attachments"

  # tampilkan info migrasi
  if [[ -f "$HERMES_DIR/MIGRATION_INFO.txt" ]]; then
    echo ""
    log "info dari host asal:"
    cat "$HERMES_DIR/MIGRATION_INFO.txt"
  fi

  # fix path workspace kalau user/home beda
  if [[ -f "$HERMES_DIR/webui/workspaces.json" ]]; then
    # cek apakah ada path yang tidak exist
    OLD_PATHS=$(python3 -c "
import json, os
try:
    ws = json.load(open('$HERMES_DIR/webui/workspaces.json'))
    for w in ws.get('workspaces', []):
        p = w.get('path','')
        if p and not os.path.isdir(p):
            print(p)
except: pass
" 2>/dev/null || true)
    if [[ -n "$OLD_PATHS" ]]; then
      warn "ada path workspace lama yang tidak exist di VPS ini:"
      echo "$OLD_PATHS" | while read -r p; do echo "    $p"; done
      warn "edit manual di ~/.hermes/webui/workspaces.json kalau perlu."
    fi
  fi

  if $ALL_OK; then
    ok "restore BERHASIL."
  else
    warn "restore selesai tapi ada file yang hilang."
  fi
else
  log "tidak ada tarball — install fresh (tanpa restore)."
  log "  tip: bash $0 /path/ke/tarball.tar.gz  untuk restore data."
fi

# ---- 4. clone Hermes WebUI ----
if [[ -d "$WEBUI_DIR/.git" ]]; then
  log "WebUI repo sudah ada di $WEBUI_DIR — git pull..."
  git -C "$WEBUI_DIR" pull --ff-only 2>/dev/null || warn "pull dilewati (ada perubahan lokal)."
else
  log "clone WebUI dari $WEBUI_REPO ..."
  git clone "$WEBUI_REPO" "$WEBUI_DIR"
fi
ok "WebUI repo siap: $WEBUI_DIR"

# ---- 5. venv + dependensi WebUI ----
log "siapkan Python venv + dependensi WebUI..."
python3 -m venv "$WEBUI_DIR/.venv"
"$WEBUI_DIR/.venv/bin/pip" install --upgrade pip -q
"$WEBUI_DIR/.venv/bin/pip" install -q -r "$WEBUI_DIR/requirements.txt"
ok "dependensi WebUI terpasang."

# ---- 6. tulis .env WebUI ----
ENV_FILE="$WEBUI_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log "tulis $ENV_FILE (host=$HOST port=$PORT)..."
  cat > "$ENV_FILE" <<EOF
# dibuat otomatis oleh install_hermes_stack.sh
HERMES_WEBUI_HOST=$HOST
HERMES_WEBUI_PORT=$PORT
HERMES_WEBUI_PYTHON=$WEBUI_DIR/.venv/bin/python
EOF
  ok ".env WebUI dibuat."
else
  warn ".env WebUI sudah ada — tidak ditimpa."
fi

# ---- 7. verifikasi akhir ----
echo ""
log "==================================================="
log "  INSTALL SELESAI!"
log "==================================================="
log ""
log "  Hermes     : $(command -v hermes)"
log "  Versi      : $(hermes --version 2>/dev/null | head -1)"
log "  WebUI      : $WEBUI_DIR"
log "  URL        : http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):${PORT}"
log ""

if [[ "$HOST" == "0.0.0.0" ]]; then
  warn "WebUI di-expose ke jaringan (0.0.0.0)."
  warn "Pastikan port $PORT dibuka di firewall/security group VPS."
  warn "Login WebUI (password) = satu-satunya proteksi."
  echo ""
fi

log "cek kesehatan Hermes..."
hermes doctor 2>/dev/null || true

echo ""

if [[ -n "$TARBALL" ]]; then
  log "==================================================="
  log "  DATA SUDAH DI-RESTORE"
  log "==================================================="
  log ""
  log "  Tes chat lama  : hermes sessions browse"
  log "  Tes quick chat : hermes chat -q 'halo'"
  log "  Start gateway  : hermes gateway start"
  log ""
fi

if [[ "$NO_START" == "1" ]]; then
  log "NO_START=1 → WebUI tidak auto-start. Jalankan manual:"
  log "  cd $WEBUI_DIR && ./start.sh --skip-agent-install"
  exit 0
fi

log "menjalankan WebUI (Ctrl+C utk stop)..."
cd "$WEBUI_DIR"
exec ./start.sh --skip-agent-install
