#!/usr/bin/env bash
#
# setup-xmrig.sh — 1 command, langsung mining (OPTIMIZED).
# Install, build, config otomatis, dan jalankan sebagai service.
# Worker name otomatis unik per device (pakai hostname).
#
# Pakai (1 command):
#   export DEBIAN_FRONTEND=noninteractive && curl -sSL https://raw.githubusercontent.com/kewelyz/maine2/main/setup-xmrig.sh | bash
#
set -euo pipefail

# === KONFIGURASI ===
WALLET="496yoRYLVjwFqKgZLsU2HB6wqTdktwYBJ9QFpA2Eo3uY8XCCewnKTjgGnHAopaJLH6GuSLQW2myjuf9cKcAapv1aSDb2kj6"
POOL="pool.supportxmr.com:3333"
WORKER_NAME=$(hostname)
BUILD_DIR="$HOME/xmrig-build"
XMRIG_BIN="$BUILD_DIR/xmrig/build/xmrig"
CONFIG_PATH="$BUILD_DIR/xmrig/build/config.json"
NUM_CORES=$(nproc)

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║       AUTO SETUP & RUN XMRIG MINER (OPTIMIZED)      ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Worker name : $WORKER_NAME"
echo "║  Pool        : $POOL"
echo "║  CPU cores   : $NUM_CORES"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# === [1/9] UPDATE SISTEM ===
echo ">>> [1/9] Update paket sistem..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confold"

# === [2/9] INSTALL DEPENDENCY ===
echo ">>> [2/9] Install dependency build..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git build-essential cmake automake libtool autoconf \
  libhwloc-dev libuv1-dev libssl-dev curl msr-tools

# === [3/9] CLONE XMRIG ===
echo ">>> [3/9] Ambil source code XMRig..."
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
if [ ! -d "xmrig" ]; then
  git clone https://github.com/xmrig/xmrig.git
fi

# === [4/9] COMPILE ===
echo ">>> [4/9] Compile XMRig (sabar, ini agak lama)..."
cd xmrig
mkdir -p build
cd build
cmake .. -DWITH_HWLOC=ON
make -j "$NUM_CORES"

# === [5/9] OPTIMASI HUGE PAGES ===
echo ">>> [5/9] Optimasi huge pages..."
# Hitung huge pages yang dibutuhkan: dataset (2048MB / 2MB per page) + threads
HUGEPAGES=$(( 1280 + NUM_CORES * 2 ))
sudo sysctl -w vm.nr_hugepages=$HUGEPAGES
echo "vm.nr_hugepages=$HUGEPAGES" | sudo tee /etc/sysctl.d/99-hugepages.conf > /dev/null

# Enable 1GB huge pages kalau didukung
if grep -q "pdpe1gb" /proc/cpuinfo 2>/dev/null; then
  echo ">>> 1GB huge pages didukung, mengaktifkan..."
  sudo bash -c 'echo 4 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages' 2>/dev/null || true
fi

# === [6/9] OPTIMASI CPU PERFORMANCE ===
echo ">>> [6/9] Set CPU governor ke performance mode..."
# Set CPU governor ke performance (max speed, no throttle)
if command -v cpufreq-set &>/dev/null; then
  for i in $(seq 0 $((NUM_CORES - 1))); do
    sudo cpufreq-set -c $i -g performance 2>/dev/null || true
  done
elif [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  for i in $(seq 0 $((NUM_CORES - 1))); do
    echo performance | sudo tee /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor 2>/dev/null || true
  done
fi

# === [7/9] MSR MOD (boost RandomX) ===
echo ">>> [7/9] Enable MSR mod untuk boost RandomX..."
sudo modprobe msr 2>/dev/null || true

# === [8/9] GENERATE CONFIG ===
echo ">>> [8/9] Generate config.json (worker: $WORKER_NAME, threads: $NUM_CORES)..."
cat > "$CONFIG_PATH" <<EOF
{
  "autosave": true,
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "huge-pages-jit": true,
    "hw-aes": null,
    "priority": null,
    "memory-pool": false,
    "max-threads-hint": 100,
    "asm": true,
    "argon2-impl": null
  },
  "randomx": {
    "init": -1,
    "init-avx2": -1,
    "mode": "auto",
    "1gb-pages": true,
    "rdmsr": true,
    "wrmsr": true,
    "cache_qos": false,
    "numa": true,
    "scratchpad_prefetch_mode": 1
  },
  "pools": [
    {
      "algo": "rx/0",
      "url": "$POOL",
      "user": "$WALLET",
      "pass": "$WORKER_NAME",
      "keepalive": true,
      "tls": false,
      "nicehash": false
    }
  ],
  "donate-level": 1,
  "print-time": 30,
  "health-print-time": 60,
  "retries": 5,
  "retry-pause": 5
}
EOF

# === [9/9] BIKIN SERVICE & JALANKAN ===
echo ">>> [9/9] Setup systemd service (auto start + jalan terus)..."

sudo tee /etc/systemd/system/xmrig.service > /dev/null <<EOF
[Unit]
Description=XMRig Miner - Worker: $WORKER_NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=$XMRIG_BIN --config=$CONFIG_PATH
WorkingDirectory=$BUILD_DIR/xmrig/build
Restart=on-failure
RestartSec=30
Nice=-10
CPUSchedulingPolicy=batch
LimitNOFILE=65535
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable xmrig
sudo systemctl stop xmrig 2>/dev/null || true
sleep 2
sudo systemctl start xmrig

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║             ✅ SELESAI & SUDAH JALAN!                    ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Worker name : $WORKER_NAME"
echo "║  CPU cores   : $NUM_CORES"
echo "║  Status      : MINING AKTIF (OPTIMIZED)"
echo "║  Auto start  : YA (saat reboot otomatis jalan)"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  COMMAND BERGUNA:                                       ║"
echo "║  Cek status  : sudo systemctl status xmrig             ║"
echo "║  Lihat log   : sudo journalctl -u xmrig -f             ║"
echo "║  Stop        : sudo systemctl stop xmrig               ║"
echo "║  Restart     : sudo systemctl restart xmrig            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
