#!/usr/bin/env bash
# ============================================================
#  9Router — Auto Installer for Ubuntu 24 VPS (Docker)
#  Repo : https://github.com/decolua/9router
#  Usage: bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/install-9router.sh)
# ============================================================
set -euo pipefail

# ── Warna ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
info() { echo -e "${CYAN}➜ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()  { echo -e "${RED}✘ $*${RESET}"; exit 1; }

# ── Banner ───────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
cat <<'EOF'
   ___  ____              __           
  / _ \/ __ \___  __ __/ /____ ____  
 / , _/ /_/ / _ \/ // / __/ -_) __/  
/_/|_|\____/\___/\_,_/\__/\__/_/     
                                      
  AI Router Installer — Docker Edition
EOF
echo -e "${RESET}"

# ── Cek root ─────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Jalankan sebagai root: sudo bash install-9router.sh"

# ── Konfigurasi via prompt ───────────────────────────────────
echo -e "${BOLD}=== Konfigurasi 9Router ===${RESET}\n"

read -rp "$(echo -e "${CYAN}Port 9Router${RESET} [default: 20128]: ")" PORT
PORT=${PORT:-20128}

read -rsp "$(echo -e "${CYAN}Password dashboard${RESET} [wajib diisi]: ")" DASHBOARD_PASS
echo
[[ -z "$DASHBOARD_PASS" ]] && die "Password tidak boleh kosong!"

# Generate secrets otomatis
JWT_SECRET=$(openssl rand -hex 32)
API_KEY_SECRET=$(openssl rand -hex 24)

DATA_DIR="$HOME/.9router"

# Deteksi IP publik
PUBLIC_IP=$(curl -fsSL --max-time 5 ifconfig.me 2>/dev/null || \
            curl -fsSL --max-time 5 api.ipify.org 2>/dev/null || \
            echo "localhost")

echo
info "Konfigurasi:"
echo -e "  Port          : ${BOLD}$PORT${RESET}"
echo -e "  Data dir      : ${BOLD}$DATA_DIR${RESET}"
echo -e "  IP Publik     : ${BOLD}$PUBLIC_IP${RESET}"
echo -e "  JWT Secret    : ${BOLD}[auto-generated]${RESET}"
echo -e "  API Key Secret: ${BOLD}[auto-generated]${RESET}"
echo

read -rp "$(echo -e "${YELLOW}Lanjutkan instalasi? [Y/n]: ${RESET}")" CONFIRM
CONFIRM=${CONFIRM:-Y}
[[ "$CONFIRM" =~ ^[Nn]$ ]] && { warn "Instalasi dibatalkan."; exit 0; }

echo
echo -e "${BOLD}=== Step 1: Update sistem ===${RESET}"
apt-get update -qq
ok "System updated"

# ── Install Docker (skip jika sudah ada) ─────────────────────
echo -e "\n${BOLD}=== Step 2: Install Docker ===${RESET}"
if command -v docker &>/dev/null; then
  ok "Docker sudah terinstall: $(docker --version)"
else
  info "Menginstall Docker..."
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  ok "Docker terinstall: $(docker --version)"
fi

# ── Buat data directory ──────────────────────────────────────
echo -e "\n${BOLD}=== Step 3: Persiapan direktori ===${RESET}"
mkdir -p "$DATA_DIR"
ok "Data dir: $DATA_DIR"

# ── Stop & hapus container lama jika ada ─────────────────────
echo -e "\n${BOLD}=== Step 4: Deploy 9Router ===${RESET}"
if docker ps -a --format '{{.Names}}' | grep -q "^9router$"; then
  warn "Container lama ditemukan, menghentikan & menghapus..."
  docker stop 9router &>/dev/null || true
  docker rm 9router &>/dev/null || true
fi

info "Pulling image terbaru..."
docker pull decolua/9router:latest

info "Menjalankan container..."
docker run -d \
  --name 9router \
  --restart unless-stopped \
  -p "${PORT}:20128" \
  -v "${DATA_DIR}:/app/data" \
  -e DATA_DIR=/app/data \
  -e JWT_SECRET="$JWT_SECRET" \
  -e INITIAL_PASSWORD="$DASHBOARD_PASS" \
  -e API_KEY_SECRET="$API_KEY_SECRET" \
  decolua/9router:latest

ok "Container 9router berjalan"

# ── Tunggu container siap ─────────────────────────────────────
info "Menunggu 9Router siap..."
for i in {1..15}; do
  if curl -fsSL --max-time 2 "http://localhost:${PORT}" &>/dev/null; then
    ok "9Router merespons"; break
  fi
  echo -n "."
  sleep 2
done
echo

# ── Konfigurasi UFW jika aktif ───────────────────────────────
echo -e "${BOLD}=== Step 5: Konfigurasi firewall ===${RESET}"
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
  ufw allow "${PORT}/tcp" &>/dev/null
  ok "UFW: port $PORT dibuka"
else
  info "UFW tidak aktif, lewati konfigurasi firewall"
fi

# ── Simpan konfigurasi ke file ───────────────────────────────
CONFIG_FILE="$DATA_DIR/.env.saved"
cat > "$CONFIG_FILE" <<EOF
# 9Router — Konfigurasi tersimpan
# Dibuat oleh install-9router.sh pada $(date)

PORT=$PORT
DATA_DIR=$DATA_DIR
JWT_SECRET=$JWT_SECRET
INITIAL_PASSWORD=<tersimpan aman, lihat saat install>
API_KEY_SECRET=$API_KEY_SECRET
PUBLIC_IP=$PUBLIC_IP
DASHBOARD_URL=http://${PUBLIC_IP}:${PORT}
EOF
chmod 600 "$CONFIG_FILE"
ok "Konfigurasi disimpan di: $CONFIG_FILE"

# ── Perintah berguna ─────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║         ✅ 9Router Berhasil Diinstall!         ║${RESET}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════╝${RESET}"
echo
echo -e "${BOLD}🌐 Dashboard  :${RESET} http://${PUBLIC_IP}:${PORT}"
echo -e "${BOLD}🔑 Password   :${RESET} (yang kamu masukkan tadi)"
echo -e "${BOLD}📁 Data dir   :${RESET} ${DATA_DIR}"
echo
echo -e "${BOLD}🔧 Konfigurasi Claude Code / Codex / Cursor:${RESET}"
echo -e "   Endpoint  : http://${PUBLIC_IP}:${PORT}/v1"
echo -e "   API Key   : (copy dari dashboard → API Keys)"
echo -e "   Model     : kr/claude-sonnet-4.5"
echo
echo -e "${BOLD}📋 Perintah berguna:${RESET}"
echo -e "   Cek status  : ${CYAN}docker ps${RESET}"
echo -e "   Lihat log   : ${CYAN}docker logs -f 9router${RESET}"
echo -e "   Restart     : ${CYAN}docker restart 9router${RESET}"
echo -e "   Stop        : ${CYAN}docker stop 9router${RESET}"
echo -e "   Update      : ${CYAN}docker pull decolua/9router:latest && docker restart 9router${RESET}"
echo
echo -e "${YELLOW}⚠  Langkah berikutnya:${RESET}"
echo -e "   1. Buka dashboard di browser"
echo -e "   2. Login dengan password yang kamu buat"
echo -e "   3. Pergi ke Providers → Connect Kiro AI (gratis)"
echo -e "   4. Hubungkan ke Claude Code / Cursor / Cline"
echo
