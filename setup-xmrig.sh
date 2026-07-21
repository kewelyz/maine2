#!/usr/bin/env bash
#
# setup-xmrig.sh — Script belajar: install & build XMRig di Ubuntu/Debian.
# Tujuan edukasi: memahami proses build software mining dari sumbernya.
#
# Fitur:
#   - Otomatis mendeteksi hostname sebagai worker name
#   - Setiap device (laptop/PC) akan muncul sebagai worker terpisah di pool
#
# Pakai:
#   chmod +x setup-xmrig.sh
#   ./setup-xmrig.sh
#
set -euo pipefail

# === KONFIGURASI WALLET ===
# Ganti dengan alamat wallet XMR milikmu
WALLET="496yoRYLVjwFqKgZLsU2HB6wqTdktwYBJ9QFpA2Eo3uY8XCCewnKTjgGnHAopaJLH6GuSLQW2myjuf9cKcAapv1aSDb2kj6"
POOL="pool.supportxmr.com:3333"

# === AUTO-DETECT WORKER NAME ===
# Menggunakan hostname supaya setiap device punya nama unik di pool.
# Contoh: laptop-andi, pc-rumah, dll.
# Kamu bisa ganti hostname device dengan: sudo hostnamectl set-hostname nama-baru
WORKER_NAME=$(hostname)

echo "=== Worker name terdeteksi: $WORKER_NAME ==="
echo ""

echo "=== [1/6] Update paket sistem ==="
sudo apt-get update -y

echo "=== [2/6] Install dependency build ==="
# Dependency untuk meng-compile XMRig dari source code.
sudo apt-get install -y \
  git build-essential cmake automake libtool autoconf \
  libhwloc-dev libuv1-dev libssl-dev

echo "=== [3/6] Ambil source code XMRig ==="
BUILD_DIR="$HOME/xmrig-build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
if [ ! -d "xmrig" ]; then
  git clone https://github.com/xmrig/xmrig.git
fi

echo "=== [4/6] Compile XMRig ==="
cd xmrig
mkdir -p build
cd build
cmake ..
make -j "$(nproc)"    # -j = pakai semua core biar compile cepat

echo "=== [5/6] Aktifkan huge pages (optimasi hashrate RandomX) ==="
# RandomX butuh banyak memori; huge pages mempercepat akses memori.
sudo sysctl -w vm.nr_hugepages=1280

echo "=== [6/6] Generate config.json dengan worker name: $WORKER_NAME ==="
CONFIG_PATH="$BUILD_DIR/xmrig/build/config.json"
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

echo ""
echo "=========================================================="
echo " Selesai! XMRig ter-build di: $BUILD_DIR/xmrig/build/xmrig"
echo ""
echo " Worker name: $WORKER_NAME"
echo " Config file: $CONFIG_PATH"
echo ""
echo " Langkah berikut:"
echo "  1) Benchmark : cd $BUILD_DIR/xmrig/build && ./xmrig --bench=1M"
echo "  2) Mulai mining : cd $BUILD_DIR/xmrig/build && ./xmrig"
echo ""
echo " Tips: Untuk ganti worker name, ubah hostname device:"
echo "       sudo hostnamectl set-hostname nama-unik-mu"
echo "       Lalu jalankan ulang script ini."
echo "=========================================================="
