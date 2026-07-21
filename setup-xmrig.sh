#!/usr/bin/env bash
#
# setup-xmrig.sh — Script belajar: install & build XMRig di Ubuntu/Debian.
# Tujuan edukasi: memahami proses build software mining dari sumbernya.
#
# Pakai:
#   chmod +x setup-xmrig.sh
#   ./setup-xmrig.sh
#
set -euo pipefail

echo "=== [1/5] Update paket sistem ==="
sudo apt-get update -y

echo "=== [2/5] Install dependency build ==="
# Dependency untuk meng-compile XMRig dari source code.
sudo apt-get install -y \
  git build-essential cmake automake libtool autoconf \
  libhwloc-dev libuv1-dev libssl-dev

echo "=== [3/5] Ambil source code XMRig ==="
BUILD_DIR="$HOME/xmrig-build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
if [ ! -d "xmrig" ]; then
  git clone https://github.com/xmrig/xmrig.git
fi

echo "=== [4/5] Compile XMRig ==="
cd xmrig
mkdir -p build
cd build
cmake ..
make -j "$(nproc)"    # -j = pakai semua core biar compile cepat

echo "=== [5/5] Aktifkan huge pages (optimasi hashrate RandomX) ==="
# RandomX butuh banyak memori; huge pages mempercepat akses memori.
sudo sysctl -w vm.nr_hugepages=1280

echo ""
echo "=========================================================="
echo " Selesai! XMRig ter-build di: $BUILD_DIR/xmrig/build/xmrig"
echo ""
echo " Langkah berikut:"
echo "  1) Benchmark : ./xmrig --bench=1M"
echo "  2) Edit config.json (isi alamat wallet-mu)"
echo "  3) Mining    : ./xmrig -c /path/ke/config.json"
echo "=========================================================="
