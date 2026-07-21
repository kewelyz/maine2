#!/usr/bin/env bash
# XMRig Ubuntu/Debian installer: build release terbaru, konfigurasi adaptif,
# worker unik, systemd auto-start, dan health check lokal.
#
# Jalankan:
#   curl -fsSL https://raw.githubusercontent.com/kewelyz/maine2/main/setup-xmrig.sh | bash
#
# Override opsional:
#   WALLET=... WORKER_NAME=pc-utama POOL=pool.supportxmr.com:3333 bash setup-xmrig.sh
set -Eeuo pipefail

WALLET="${WALLET:-496yoRYLVjwFqKgZLsU2HB6wqTdktwYBJ9QFpA2Eo3uY8XCCewnKTjgGnHAopaJLH6GuSLQW2myjuf9cKcAapv1aSDb2kj6}"
POOL="${POOL:-pool.supportxmr.com:3333}"
WORKER_NAME="${WORKER_NAME:-$(hostname -s)}"
INSTALL_HOME="${INSTALL_HOME:-$HOME/xmrig-build}"
SOURCE_DIR="$INSTALL_HOME/xmrig"
BUILD_DIR="$SOURCE_DIR/build"
XMRIG_BIN="$BUILD_DIR/xmrig"
CONFIG_PATH="$BUILD_DIR/config.json"
API_PORT="${API_PORT:-18080}"
CPU_THREADS="$(nproc)"

if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    command -v sudo >/dev/null 2>&1 || {
        echo "ERROR: sudo tidak tersedia. Jalankan sebagai root atau install sudo." >&2
        exit 1
    }
    SUDO=(sudo)
fi

run_root() {
    "${SUDO[@]}" "$@"
}

on_error() {
    local exit_code=$?
    echo "ERROR: setup gagal di baris $1 (exit $exit_code)." >&2
    if command -v systemctl >/dev/null 2>&1; then
        run_root systemctl status xmrig --no-pager 2>/dev/null || true
        run_root journalctl -u xmrig -n 40 --no-pager 2>/dev/null || true
    fi
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# Nama worker dikirim ke pool; batasi ke karakter yang aman dan mudah dibaca.
WORKER_NAME="$(printf '%s' "$WORKER_NAME" | tr -cs '[:alnum:]_.-' '-' | sed 's/^-//; s/-$//')"
[[ -n "$WORKER_NAME" ]] || WORKER_NAME="worker-$(cat /etc/machine-id 2>/dev/null | cut -c1-8)"

# Alamat Monero standar berupa 95 atau 106 karakter base58.
if [[ ! "$WALLET" =~ ^[1-9A-HJ-NP-Za-km-z]{95}([1-9A-HJ-NP-Za-km-z]{11})?$ ]]; then
    echo "ERROR: WALLET tampaknya bukan alamat Monero yang valid." >&2
    echo "Gunakan: WALLET=alamat_wallet_kamu bash setup-xmrig.sh" >&2
    exit 1
fi

printf '\n=== XMRig adaptive setup ===\n'
printf 'Worker : %s\nPool   : %s\nvCPU   : %s\n\n' "$WORKER_NAME" "$POOL" "$CPU_THREADS"

export DEBIAN_FRONTEND=noninteractive

# Pulihkan dpkg yang sebelumnya terputus tanpa mengganti konfigurasi lokal SSH.
# Perintah ini aman dijalankan walau tidak ada paket yang tertunda.
echo '>>> Memastikan database paket konsisten...'
run_root env DEBIAN_FRONTEND=noninteractive dpkg --force-confold --configure -a

echo '>>> Install dependency build (tanpa full system upgrade)...'
run_root apt-get update -y
run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confold" \
    git build-essential cmake automake libtool autoconf \
    libhwloc-dev libuv1-dev libssl-dev msr-tools curl jq

echo '>>> Ambil release stabil XMRig terbaru...'
mkdir -p "$INSTALL_HOME"
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    git clone https://github.com/xmrig/xmrig.git "$SOURCE_DIR"
fi
git -C "$SOURCE_DIR" fetch --tags --prune origin
LATEST_TAG="$(git -C "$SOURCE_DIR" tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"
[[ -n "$LATEST_TAG" ]] || {
    echo 'ERROR: tag release stabil XMRig tidak ditemukan.' >&2
    exit 1
}
git -C "$SOURCE_DIR" checkout --detach "$LATEST_TAG"

echo ">>> Build $LATEST_TAG dalam mode Release..."
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_HWLOC=ON
cmake --build "$BUILD_DIR" --parallel "$CPU_THREADS"
[[ -x "$XMRIG_BIN" ]] || {
    echo "ERROR: binary tidak ditemukan di $XMRIG_BIN" >&2
    exit 1
}

# XMRig merekomendasikan 1280 huge pages 2 MiB per NUMA node untuk RandomX.
# Batasi terhadap RAM agar mesin kecil tidak dipaksa mereservasi hampir semua RAM.
if [[ -d /sys/devices/system/node ]]; then
    NUMA_NODES="$(find /sys/devices/system/node -maxdepth 1 -type d -name 'node[0-9]*' 2>/dev/null | wc -l)"
else
    NUMA_NODES=1
fi
(( NUMA_NODES > 0 )) || NUMA_NODES=1
MEM_TOTAL_MB="$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
REQUIRED_HP=$((1280 * NUMA_NODES))
MAX_SAFE_HP=$((((MEM_TOTAL_MB - 1024) > 0 ? (MEM_TOTAL_MB - 1024) : 0) / 2))
HUGE_PAGES="$REQUIRED_HP"
if (( HUGE_PAGES > MAX_SAFE_HP )); then
    HUGE_PAGES="$MAX_SAFE_HP"
fi
if (( HUGE_PAGES < 1168 )); then
    echo "ERROR: RAM terlalu kecil untuk dataset RandomX penuh + cadangan 1 GiB sistem." >&2
    echo "RAM terdeteksi: ${MEM_TOTAL_MB} MiB; minimum praktis sekitar 3.5 GiB." >&2
    exit 1
fi

echo ">>> Reservasi $HUGE_PAGES huge pages 2 MiB untuk $NUMA_NODES NUMA node..."
printf 'vm.nr_hugepages=%s\n' "$HUGE_PAGES" | run_root tee /etc/sysctl.d/99-xmrig-hugepages.conf >/dev/null
run_root sysctl -p /etc/sysctl.d/99-xmrig-hugepages.conf >/dev/null

# Jangan mereservasi 4 GiB 1GB pages secara paksa saat runtime. Aktifkan hanya
# jika administrator memang sudah menyediakannya saat boot (minimal 3 per node).
ONE_GB_PAGES=false
ONE_GB_COUNT=0
if [[ -r /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages ]]; then
    ONE_GB_COUNT="$(< /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)"
    if (( ONE_GB_COUNT >= 3 * NUMA_NODES )); then
        ONE_GB_PAGES=true
    fi
fi

# MSR dapat memberi peningkatan besar, tetapi hypervisor VPS mungkin menolaknya.
if run_root modprobe msr 2>/dev/null; then
    printf 'msr\n' | run_root tee /etc/modules-load.d/xmrig-msr.conf >/dev/null
fi

# Performance governor hanya diterapkan jika interface cpufreq tersedia; pada VPS
# biasanya tidak tersedia dan CPU diatur oleh host.
if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
    for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -e "$governor" ]] && printf 'performance\n' | run_root tee "$governor" >/dev/null || true
    done
fi

echo '>>> Tulis konfigurasi XMRig...'
cat > "$CONFIG_PATH" <<EOF
{
  "autosave": false,
  "background": false,
  "colors": false,
  "title": false,
  "randomx": {
    "init": -1,
    "init-avx2": -1,
    "mode": "auto",
    "1gb-pages": $ONE_GB_PAGES,
    "rdmsr": true,
    "wrmsr": true,
    "cache_qos": false,
    "numa": true
  },
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "huge-pages-jit": true,
    "hw-aes": null,
    "priority": null,
    "memory-pool": false,
    "yield": false,
    "max-threads-hint": 100,
    "asm": true
  },
  "opencl": false,
  "cuda": false,
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
  "http": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": $API_PORT,
    "access-token": null,
    "restricted": true
  },
  "donate-level": 1,
  "print-time": 30,
  "health-print-time": 60,
  "retries": 10,
  "retry-pause": 5
}
EOF
jq empty "$CONFIG_PATH"

# Penting: tidak ada CPUQuota. CPUQuota=100% membatasi seluruh service ke
# kapasitas sekitar satu CPU, bukan 100% dari semua vCPU.
echo '>>> Pasang service systemd tanpa CPU quota...'
run_root tee /etc/systemd/system/xmrig.service >/dev/null <<EOF
[Unit]
Description=XMRig RandomX miner ($WORKER_NAME)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
WorkingDirectory=$BUILD_DIR
ExecStart=$XMRIG_BIN --config=$CONFIG_PATH
Restart=always
RestartSec=10
KillSignal=SIGINT
TimeoutStopSec=20
Nice=-10
LimitMEMLOCK=infinity
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# Helper status: menunjukkan status lokal dan hashrate XMRig, tanpa menunggu pool.
run_root tee /usr/local/bin/xmrig-status >/dev/null <<EOF
#!/usr/bin/env bash
set -u
systemctl is-active xmrig || true
printf '\nService:\n'
systemctl status xmrig --no-pager -n 5 || true
printf '\nHashrate lokal/API:\n'
if summary="\$(curl -fsS --max-time 2 http://127.0.0.1:$API_PORT/2/summary)"; then
    jq '{uptime, accepted: .results.shares_good, rejected: (.results.shares_total - .results.shares_good), hashrate_hs: .hashrate.total, hugepages: .hugepages, resources}' <<<"\$summary"
else
    echo 'API belum siap; tunggu dataset selesai dibuat lalu coba lagi.'
fi
printf '\nLog terakhir:\n'
journalctl -u xmrig -n 20 --no-pager
EOF
run_root chmod 0755 /usr/local/bin/xmrig-status

run_root systemctl daemon-reload
run_root systemctl enable xmrig >/dev/null
run_root systemctl restart xmrig

# Verifikasi proses sungguhan, bukan sekadar menganggap systemctl start berhasil.
echo '>>> Tunggu dataset RandomX dan verifikasi service...'
HASHRATE=0
HASH_VERIFIED=false
for _ in $(seq 1 72); do
    if ! run_root systemctl is-active --quiet xmrig; then
        echo 'ERROR: service XMRig berhenti saat startup.' >&2
        run_root journalctl -u xmrig -n 60 --no-pager >&2
        exit 1
    fi
    if SUMMARY="$(curl -fsS --max-time 2 "http://127.0.0.1:$API_PORT/2/summary" 2>/dev/null)"; then
        HASHRATE="$(jq -r '[.hashrate.total[]? // 0] | max // 0' <<<"$SUMMARY")"
        if awk "BEGIN {exit !($HASHRATE > 0)}"; then
            HASH_VERIFIED=true
            break
        fi
    fi
    sleep 5
done

if [[ "$HASH_VERIFIED" != true ]]; then
    echo 'ERROR: service aktif tetapi hashrate lokal belum terdeteksi setelah 6 menit.' >&2
    run_root journalctl -u xmrig -n 80 --no-pager >&2
    exit 1
fi

run_root systemctl is-active --quiet xmrig
SERVICE_CPU_QUOTA="$(run_root systemctl show xmrig -p CPUQuotaPerSecUSec --value 2>/dev/null || true)"

printf '\n=== SELESAI ===\n'
printf 'Versi          : %s\n' "$LATEST_TAG"
printf 'Worker         : %s\n' "$WORKER_NAME"
printf 'vCPU terdeteksi: %s\n' "$CPU_THREADS"
printf 'NUMA node      : %s\n' "$NUMA_NODES"
printf '2 MiB pages    : %s\n' "$HUGE_PAGES"
printf '1 GiB pages    : %s (%s tersedia)\n' "$ONE_GB_PAGES" "$ONE_GB_COUNT"
printf 'CPU quota      : %s (harus infinity)\n' "$SERVICE_CPU_QUOTA"
printf 'Status         : %s\n' "$(run_root systemctl is-active xmrig)"
printf '\nCek kapan saja: xmrig-status\nLog live       : sudo journalctl -u xmrig -f\n'

xmrig-status || true
