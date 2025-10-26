#!/bin/bash
# profile_miner.sh
# Собирает набор профилей и метрик для бинарного miner'a (Ubuntu 24, NVIDIA GPU)
# Сохраняет артефакты в profiling_out/ и упаковывает их в profiling_out.tar.gz
# Запуск: ./profile_miner.sh --binary ./ARM1 --args "--opt1 val1" --duration 30
set -euo pipefail

BINARY="./ARM1"
ARGS=""
DURATION=30           # время профилирования (в секундах) для perf/nsys
OUTDIR="profiling_out"
FLAMEGRAPH_DIR="$HOME/FlameGraph"

usage() {
  cat <<EOF
Usage: $0 [--binary <path>] [--args "<args>"] [--duration <sec>] [--outdir <dir>]

Defaults:
  --binary   ./ARM1
  --args     ""
  --duration 30
  --outdir   profiling_out

Пример:
  sudo $0 --binary ./ARM1 --args "--threads 4 --config cfg.json" --duration 60
EOF
  exit 1
}

# parse args
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
echo "Output directory: $OUTDIR"
echo "Binary: $BINARY"
echo "Args: $ARGS"
echo "Duration: $DURATION s"

# 1) basic time / memory measurement
echo "[1/9] /usr/bin/time -v"
{ /usr/bin/time -v $BINARY $ARGS ; } 2> "$OUTDIR/time.txt" || true
echo "Saved: $OUTDIR/time.txt"

# 2) ldd and file info
echo "[2/9] ldd / file / strings (summaries)"
ldd "$BINARY" > "$OUTDIR/ldd.txt" 2>&1 || true
file "$BINARY" > "$OUTDIR/file.txt" 2>&1 || true
strings -n 8 "$BINARY" | head -n 200 > "$OUTDIR/strings_head.txt" 2>&1 || true
echo "Saved: ldd,file,strings_head"

# 3) nvidia-smi snapshot
echo "[3/9] nvidia-smi snapshot"
if command -v nvidia-smi > /dev/null 2>&1; then
  nvidia-smi -q > "$OUTDIR/nvidia-smi.txt" || true
  nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv > "$OUTDIR/gpu_summary.csv" || true
  echo "Saved: nvidia-smi outputs"
else
  echo "nvidia-smi not found, skipping GPU snapshot"
fi

# 4) perf record
echo "[4/9] perf record (sampling)"
if command -v perf > /dev/null 2>&1; then
  sudo perf record -F 200 -g --timeout "${DURATION}s" -- $BINARY $ARGS || true
  sudo perf report --stdio > "$OUTDIR/perf-report.txt" || true
  sudo perf script > "$OUTDIR/perf.script" || true
  echo "Saved: perf-report.txt, perf.script"
else
  echo "perf not found, skipping perf."
fi

# 5) FlameGraph (if available & perf.script exists)
if [[ -f perf.script && -d "$FLAMEGRAPH_DIR" ]]; then
  echo "[5/9] Generating Flamegraph"
  "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" perf.script > "$OUTDIR/out.folded" || true
  "$FLAMEGRAPH_DIR/flamegraph.pl" "$OUTDIR/out.folded" > "$OUTDIR/flamegraph.svg" || true
  echo "Saved: $OUTDIR/flamegraph.svg"
else
  echo "FlameGraph not found or perf.script missing; skipping flamegraph."
fi

# 6) valgrind massif (optional — сильно замедляет)
echo "[6/9] valgrind massif (short run - 30s)"
if command -v valgrind > /dev/null 2>&1; then
  # run for shorter time to capture memory profile; user can re-run manually for longer test
  timeout 30 valgrind --tool=massif --stacks=yes --massif-out-file="$OUTDIR/massif.out" $BINARY $ARGS || true
  if [[ -f "$OUTDIR/massif.out" ]]; then
    if command -v ms_print > /dev/null 2>&1; then
      ms_print "$OUTDIR/massif.out" > "$OUTDIR/massif.txt" || true
    fi
  fi
  echo "Saved: massif outputs (if valgrind available)"
else
  echo "valgrind not installed; skipping massif."
fi

# 7) cuobjdump PTX/SASS (if CUDA embedded)
echo "[7/9] cuobjdump (dump PTX/SASS if available)"
if command -v cuobjdump > /dev/null 2>&1; then
  cuobjdump --dump-ptx "$BINARY" > "$OUTDIR/ptx.txt" 2>/dev/null || true
  cuobjdump --dump-sass "$BINARY" > "$OUTDIR/sass.txt" 2>/dev/null || true
  echo "Saved: ptx.txt, sass.txt (if any)"
else
  echo "cuobjdump not found; skipping PTX/SASS dump."
fi

# 8) nsys profiling (Nsight Systems) - system+CUDA tracing
echo "[8/9] nsys profile (if installed)"
if command -v nsys > /dev/null 2>&1; then
  nsys profile -o "$OUTDIR/nsys_report" --capture-range=cudaProfilerApi --trace=cuda,cudnn,osrt --sample=cpu --stop-timeout=5 --force-overwrite true --duration $DURATION -- $BINARY $ARGS || true
  if [[ -f "$OUTDIR/nsys_report.qdrep" ]]; then
    nsys stats "$OUTDIR/nsys_report.qdrep" > "$OUTDIR/nsys_stats.txt" || true
  fi
  echo "Saved: nsys report (.qdrep) and stats"
else
  echo "nsys not found; skipping Nsight Systems profiling."
fi

# 9) basic system snapshot and pack results
echo "[9/9] system info and pack results"
uname -a > "$OUTDIR/uname.txt"
cat /etc/os-release > "$OUTDIR/os-release.txt" || true
ps aux --sort=-%mem | head -n 30 > "$OUTDIR/top_mem.txt" || true
ps aux --sort=-%cpu | head -n 30 > "$OUTDIR/top_cpu.txt" || true

tar -czf "${OUTDIR}.tar.gz" "$OUTDIR" || true
echo "Packaging complete: ${OUTDIR}.tar.gz"
echo "Done. Please upload ${OUTDIR}.tar.gz or key files (perf-report.txt, flamegraph.svg, nsys_stats.txt, ptx.txt, time.txt) for analysis."
