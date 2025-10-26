#!/bin/bash
# profile_miner_v2.sh
# Автоматически исправляет perf для ядра HiveOS/Ubuntu и выполняет CPU/GPU профилирование

set -euo pipefail

BINARY="./ARM1"
ARGS=""
DURATION=30
OUTDIR="profiling_out"
FLAMEGRAPH_DIR="$HOME/FlameGraph"

usage() {
  cat <<EOF
Usage: $0 [--binary <path>] [--args "<args>"] [--duration <sec>] [--outdir <dir>]
Пример:
  sudo $0 --binary ./ARM1 --args "--threads 4" --duration 60
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2;;
    --args) ARGS="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

mkdir -p "$OUTDIR"

# --- PERF AUTO-FIX ---
echo "[Perf Fix] Проверяем perf для ядра $(uname -r)"
KERNEL=$(uname -r)
PERF_PATH="/usr/lib/linux-tools-${KERNEL}/perf"

if [[ ! -x "$PERF_PATH" ]]; then
  echo "[Perf Fix] Не найден perf для ${KERNEL}, пробуем исправить..."
  ALT=$(ls /usr/lib/linux-tools*/perf 2>/dev/null | head -n 1 || true)
  if [[ -n "$ALT" ]]; then
    echo "[Perf Fix] Используем perf из: $ALT"
    sudo ln -sf "$ALT" /usr/local/bin/perf
  else
    echo "[Perf Fix] Не найден perf в /usr/lib/linux-tools*, пробуем установить стандартный пакет..."
    sudo apt update -y && sudo apt install -y linux-tools-common linux-tools-generic linux-cloud-tools-generic || true
  fi
else
  echo "[Perf Fix] Найден perf для ядра: $PERF_PATH"
  sudo ln -sf "$PERF_PATH" /usr/local/bin/perf
fi

if command -v perf >/dev/null 2>&1; then
  echo "[Perf Fix] Используется perf: $(which perf)"
  perf --version || true
else
  echo "[Perf Fix] WARNING: perf по-прежнему не найден. Профилирование CPU будет пропущено."
fi

# --- MAIN PROFILING ---
echo "=== Запуск профиля ==="
echo "Бинарь: $BINARY"
echo "Аргументы: $ARGS"
echo "Длительность: $DURATION сек"
echo "Результаты: $OUTDIR"

echo "[1/9] time -v"
/usr/bin/time -v $BINARY $ARGS 2> "$OUTDIR/time.txt" || true

echo "[2/9] ldd/file"
ldd "$BINARY" > "$OUTDIR/ldd.txt" 2>&1 || true
file "$BINARY" > "$OUTDIR/file.txt" 2>&1 || true

echo "[3/9] nvidia-smi"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -q > "$OUTDIR/nvidia-smi.txt" || true
  nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv > "$OUTDIR/gpu_summary.csv" || true
else
  echo "nvidia-smi not found."
fi

echo "[4/9] perf record"
if command -v perf >/dev/null 2>&1; then
  sudo perf record -F 200 -g --timeout "${DURATION}s" -- $BINARY $ARGS || true
  sudo perf report --stdio > "$OUTDIR/perf-report.txt" || true
  sudo perf script > "$OUTDIR/perf.script" || true
else
  echo "perf not found; skipping."
fi

if [[ -f perf.script && -d "$FLAMEGRAPH_DIR" ]]; then
  echo "[5/9] FlameGraph"
  "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" perf.script > "$OUTDIR/out.folded" || true
  "$FLAMEGRAPH_DIR/flamegraph.pl" "$OUTDIR/out.folded" > "$OUTDIR/flamegraph.svg" || true
else
  echo "FlameGraph not found or perf.script missing."
fi

echo "[6/9] cuobjdump"
if command -v cuobjdump >/dev/null 2>&1; then
  cuobjdump --dump-ptx "$BINARY" > "$OUTDIR/ptx.txt" 2>/dev/null || true
  cuobjdump --dump-sass "$BINARY" > "$OUTDIR/sass.txt" 2>/dev/null || true
fi

echo "[7/9] nsys"
if command -v nsys >/dev/null 2>&1; then
  nsys profile -o "$OUTDIR/nsys_report" --trace=cuda,cudnn,osrt --sample=cpu --duration "$DURATION" --force-overwrite true -- $BINARY $ARGS || true
  if [[ -f "$OUTDIR/nsys_report.qdrep" ]]; then
    nsys stats "$OUTDIR/nsys_report.qdrep" > "$OUTDIR/nsys_stats.txt" || true
  fi
else
  echo "nsys not found."
fi

echo "[8/9] system info"
uname -a > "$OUTDIR/uname.txt"
cat /etc/os-release > "$OUTDIR/os-release.txt" || true
ps aux --sort=-%cpu | head -n 30 > "$OUTDIR/top_cpu.txt" || true

echo "[9/9] pack results"
tar -czf "${OUTDIR}.tar.gz" "$OUTDIR" || true
echo "=== Готово. Архив: ${OUTDIR}.tar.gz ==="
