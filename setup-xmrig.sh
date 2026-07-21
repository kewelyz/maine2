#!/usr/bin/env bash
#
# setup-xmrig.sh — 1 command, langsung mining.
# Install, build, config otomatis, dan jalankan sebagai service.
# Worker name otomatis unik per device (pakai hostname).
#
# Pakai (1 command):
#   curl -sSL https://raw.githubusercontent.com/kewelyz/maine2/main/setup-xmrig.sh | bash
#
# Atau manual:
#   git clone https://github.com/kewelyz/maine2.git && cd maine2 && chmod +x setup-xmrig.sh && ./setup-xmrig.sh
#
set -euo pipefail

# === KONFIGURASI ===
WALLET="496yoRYLVjwFqKgZLsU2HB6wqTdktwYBJ9QFpA2Eo3uY8XCCewnKTjgGnHAopaJLH6GuSLQW2myjuf9cKcAapv1aSDb2kj6"
POOL="pool.supportxmr.com:3333"
WORKER_NAME=$(hostname)
BUILD_DIR="$HOME/xmrig-build"
XMRIG_BIN="$BUILD_DIR/xmrig/build/xmrig"
CONFIG_PATH="$BUILD_DIR/xmrig/build/config.json"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       AUTO SETUP & RUN XMRIG MINER              ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Worker name : $WORKER_NAME"
echo "║  Pool        : $POOL"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# === [1/7] UPDATE SISTEM ===
echo ">>> [1/7] Update paket sistem..."
sudo apt-get update -y && sudo apt-get upgrade -y

# === [2/7] INSTALL DEPENDENCY ===
echo ">>> [2/7] Install dependency build..."
sudo apt-get install -y \
  git build-essential cmake automake libtool autoconf \
  libhwloc-dev libuv1-dev libssl-dev curl

# === [3/7] CLONE XMRIG ===
echo ">>> [3/7] Ambil source code XMRig..."
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
if [ ! -d "xmrig" ]; then
  git clone https://github.com/xmrig/xmrig.git
fi

# === [4/7] COMPILE ===
echo ">>> [4/7] Compile XMRig (sabar, ini agak lama)..."
cd xmrig
mkdir -p build
cd build
cmake ..
make -j "$(nproc)"

# === [5/7] OPTIMASI ===
echo ">>> [5/7] Aktifkan huge pages..."
sudo sysctl -w vm.nr_hugepages=1280
# Biar permanen setelah reboot
echo "vm.nr_hugepages=1280" | sudo tee /etc/sysctl.d/99-hugepages.conf > /dev/null

# === [6/7] GENERATE CONFIG ===
echo ">>> [6/7] Generate config.json (worker: $WORKER_NAME)..."
cat > "$CONFIG_PATH" <<EOF
{
  "autosave": true,
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "max-threads-hint": 100
  },
  "pools": [
    {
      "algo": "rx/0",
      "url": "$POOL",
      "user": "$WALLET",
      "pass": "$WORKER_NAME",
      "keepalive": true,
      "tls": false
    }
  ],
  "print-time": 30,
  "health-print-time": 60
}
EOF

# === [7/7] BIKIN SERVICE & JALANKAN ===
echo ">>> [7/7] Setup systemd service (auto start + jalan terus)..."

sudo tee /etc/systemd/system/xmrig.service > /dev/null <<EOF
[Unit]
Description=XMRig Miner - Worker: $WORKER_NAME
After=network.target

[Service]
ExecStart=$XMRIG_BIN --config=$CONFIG_PATH
WorkingDirectory=$BUILD_DIR/xmrig/build
Restart=always
RestartSec=10
Nice=10
CPUQuota=100%

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable xmrig
sudo systemctl restart xmrig

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║            ✅ SELESAI & SUDAH JALAN!             ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Worker name : $WORKER_NAME"
echo "║  Status      : MINING AKTIF"
echo "║  Auto start  : YA (saat reboot otomatis jalan)"
echo "╠══════════════════════════════════════════════════╣"
echo "║  COMMAND BERGUNA:                               ║"
echo "║  Cek status  : sudo systemctl status xmrig     ║"
echo "║  Lihat log   : sudo journalctl -u xmrig -f     ║"
echo "║  Stop        : sudo systemctl stop xmrig       ║"
echo "║  Restart     : sudo systemctl restart xmrig    ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
