#!/bin/bash
# One mission-load run on the SENDER board (as root). The peer board must already run F' (FPGA backend,
# e.g. `sudo bash ~/aup_kit_v6/wcore_node.sh 5 1` or `sudo bash mission_run.sh receiver`), so it verifies
# every frame; keep the peer constant across runs so only the sender's signer changes.
#   sudo bash mission_run.sh BACKEND RATE LOAD_LEVEL SECONDS [TAG]
#     BACKEND    cpu  = PQClean ML-DSA-44 in-process on the A53 (F' WCORE_BACKEND=cpu)
#                fpga = v6/v7 fabric signer (WCORE_BACKEND=fpga)
#     RATE       signed crosslink frames per second (PeerPing via one persistent GDS connection)
#     LOAD_LEVEL 0..4 cores running the mission load: core order CORE_ORDER (default "1 3 0 2"):
#                first core = adcs_load (SCHED_FIFO $ADCS_PRIO), others = payload_load (SCHED_OTHER)
#     SECONDS    measured window
#   sudo bash mission_run.sh receiver   -> only starts GDS + F' (fpga backend) and returns
# Env overrides: PINNING SIGNER_PRIO ADCS_BIN PAYLOAD_BIN PAYLOAD_INPUT ADCS_RATE ADCS_PRIO PAYLOAD_RATE CORE_ORDER DRIVER_MODE KIT RUNS
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT=${KIT:-/home/xilinx/aup_kit_v7}
DEP=/home/xilinx/wepwawet-core/fprime/deployment
PRJ=/home/xilinx/wepwawet-core/fprime/core-source/WepwawetDeployment
VENV=/home/xilinx/Wepwawet/fprime-venv
PY=/usr/local/share/pynq-venv/bin/python
HWCSV=/home/xilinx/wepwawet-core/logs/fprime_hw_stats.csv
ADCS_BIN=${ADCS_BIN:-$HERE/../adcs/adcs_load}
PAYLOAD_BIN=${PAYLOAD_BIN:-$HERE/../payload/payload_load}
PAYLOAD_INPUT=${PAYLOAD_INPUT:-$HERE/../payload/data/tiles.raw}
ADCS_RATE=${ADCS_RATE:-100}; ADCS_PRIO=${ADCS_PRIO:-80}; PAYLOAD_RATE=${PAYLOAD_RATE:-5}
CORE_ORDER=${CORE_ORDER:-"1 3 0 2"}; DRIVER_MODE=${DRIVER_MODE:-open}
PINNING=${PINNING:-core}        # core = static per-core pinning (default); none = all threads free on cpus 0-3 (Linux scheduler)
SIGNER_PRIO=${SIGNER_PRIO:-0}   # >0: whole F' process (incl. the signer) at SCHED_FIFO SIGNER_PRIO (below ADCS_PRIO)
RUNS=${RUNS:-/home/xilinx/wepwawet-core/logs/mission_runs}

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
for f in /etc/profile.d/xrt_setup.sh /etc/profile.d/pynq_venv.sh; do [ -f $f ] && . $f; done
[ -x $KIT/wcore_check ] || gcc -O2 -o $KIT/wcore_check $KIT/wcore_check.c || { echo "ABORT: cannot build wcore_check"; exit 1; }

stop_all() { pkill -f "$DEP/WepwawetDeployment" 2>/dev/null; pkill -f "./WepwawetDeployment" 2>/dev/null
             pkill -f fprime-gds 2>/dev/null; pkill -f fprime_gds 2>/dev/null
             pkill -f adcs_load 2>/dev/null; pkill -f payload_load 2>/dev/null
             fuser -k 50000/tcp 50050/tcp 5000/tcp >/dev/null 2>&1
             sleep 1; pkill -9 -f fprime_gds 2>/dev/null; pkill -9 -f fprime-gds 2>/dev/null; }   # GDS comm can ignore SIGTERM and spin a core
wait_ports() { for i in $(seq 1 90); do ss -tan | grep -qE ':50000 |:50050 ' || return 0; sleep 1; done; return 1; }
start_fsw() {   # $1 backend, $2 logdir
  # The ground software logs every frame under $PRJ/logs; keep that in RAM too so no SD-card write sits in the command path.
  if [ "${RAMLOG:-1}" = 1 ] && [ -d /dev/shm ]; then
    rm -rf /dev/shm/gds_logs; mkdir -p /dev/shm/gds_logs
    if [ ! -L $PRJ/logs ]; then [ -e $PRJ/logs ] && mv $PRJ/logs $PRJ/logs.sd_$(date +%s); ln -s /dev/shm/gds_logs $PRJ/logs; fi
  fi
  ( . $VENV/bin/activate; cd $PRJ; export PYTHONUNBUFFERED=1; exec fprime-gds --no-app ) > $2/gds.log 2>&1 &
  for i in $(seq 1 45); do ss -ltn | grep -q ':50000 ' && ss -ltn | grep -q ':50050 ' && break; grep -aq ERROR $2/gds.log && break; sleep 1; done
  ss -ltn | grep -q ':50000 ' || { echo "ABORT: GDS not listening on 50000 after 45 s"; grep -a -E "ERROR|Traceback" $2/gds.log | head -3; tail -3 $2/gds.log; return 1; }
  sleep 2
  ( cd $DEP; ulimit -c 0; WCORE_BACKEND=$1 exec ./WepwawetDeployment -a 127.0.0.1 -p 50000 ) > $2/fsw.log 2>&1 &
  for i in $(seq 1 40); do grep -aq "listening on" $2/fsw.log && break; sleep 0.5; done
  grep -aq "listening on" $2/fsw.log || { echo "ABORT: F' did not start"; tail -5 $2/fsw.log; return 1; }
  grep -aq "backend=$( [ $1 = cpu ] && echo 'cpu(PQClean)' || echo fpga )" $2/fsw.log || { echo "ABORT: F' backend is not $1"; grep -a WCORE $2/fsw.log | head -2; return 1; }
}

if [ "${1:-}" = "receiver" ]; then
  L=/home/xilinx/wepwawet-core/logs/mission_receiver_$(date +%Y%m%d_%H%M%S); mkdir -p $L
  stop_all; wait_ports || { echo "ABORT: ports busy"; exit 1; }
  $KIT/wcore_check || $PY $KIT/load_v6.py > $L/load.log 2>&1; $KIT/wcore_check || { echo "ABORT: FPGA image"; exit 1; }
  start_fsw fpga $L || exit 1
  echo "receiver up (fpga backend), logs $L; stop with: sudo bash $HERE/mission_run.sh stop"; exit 0
fi
if [ "${1:-}" = "stop" ]; then stop_all; echo stopped; exit 0; fi

BACKEND=${1:?backend cpu|fpga}; RATE=${2:?rate}; LOAD=${3:?load level 0..4}; SECS=${4:?seconds}; TAG=${5:-}
case $BACKEND in cpu|fpga) ;; *) echo "backend must be cpu or fpga"; exit 1;; esac
CFG=""; [ "$PINNING" = none ] && CFG="${CFG}_unpinned"; [ "$SIGNER_PRIO" -gt 0 ] && CFG="${CFG}_rt${SIGNER_PRIO}"
RUN=$RUNS/$(date +%Y%m%d_%H%M%S)_${BACKEND}_r${RATE}_L${LOAD}${CFG}${TAG:+_$TAG}; mkdir -p $RUN
echo "[run] $RUN"
# No SD-card writes inside the measured window: run files and the F' statistics file live in RAM and are copied at the end.
RUN_FINAL=$RUN
if [ "${RAMLOG:-1}" = 1 ] && [ -d /dev/shm ]; then
  RUN=/dev/shm/wcore_run_$$; rm -rf $RUN; mkdir -p $RUN
  if [ ! -L $HWCSV ]; then [ -f $HWCSV ] && mv $HWCSV $HWCSV.sd_$(date +%s); : > /dev/shm/fprime_hw_stats.csv; ln -s /dev/shm/fprime_hw_stats.csv $HWCSV; fi
  [ -e $HWCSV ] || : > /dev/shm/fprime_hw_stats.csv
fi
cat > $RUN/params.json <<J
{"host":"$(hostname)","backend":"$BACKEND","rate":$RATE,"load_level":$LOAD,"seconds":$SECS,"tag":"$TAG",
 "adcs_rate":$ADCS_RATE,"adcs_prio":$ADCS_PRIO,"payload_rate":$PAYLOAD_RATE,"core_order":"$CORE_ORDER",
 "driver_mode":"$DRIVER_MODE","pinning":"$PINNING","signer_prio":$SIGNER_PRIO,"payload_input":"$PAYLOAD_INPUT","started_epoch":$(date +%s)}
J
stop_all; wait_ports || { echo "ABORT: GDS ports busy"; exit 1; }
# FPGA image must be alive in both backends (fpga uses it; cpu runs keep the board identical)
$KIT/wcore_check > $RUN/check_before.txt || { $PY $KIT/load_v6.py > $RUN/load.log 2>&1; $KIT/wcore_check > $RUN/check_before.txt || { echo "ABORT: FPGA image"; exit 1; }; }
HW0=$( [ -f $HWCSV ] && wc -l < $HWCSV || echo 0 )
start_fsw $BACKEND $RUN || { stop_all; exit 1; }
FSWPID=$(pgrep -f "WepwawetDeployment -a 127.0.0.1" | head -1)
if [ "$SIGNER_PRIO" -gt 0 ]; then chrt -f -a -p $SIGNER_PRIO $FSWPID > $RUN/sched.txt 2>&1 || { echo "ABORT: chrt failed"; stop_all; exit 1; }; fi

# mission load
CORES=($CORE_ORDER); LOADPIDS=()
LOADSECS=$(( SECS + 15 ))
if [ "$LOAD" -ge 1 ]; then
  [ -x "$ADCS_BIN" ] || { echo "ABORT: adcs_load not found at $ADCS_BIN"; stop_all; exit 1; }
  "$ADCS_BIN" --cpu ${CORES[0]} --prio $ADCS_PRIO --rate $ADCS_RATE --seconds $LOADSECS --csv $RUN/adcs.csv > $RUN/adcs.json 2> $RUN/adcs.err &
  LOADPIDS+=($!)
fi
if [ "$LOAD" -ge 2 ]; then
  [ -x "$PAYLOAD_BIN" ] || { echo "ABORT: payload_load not found at $PAYLOAD_BIN"; stop_all; exit 1; }
  PC=$(echo "${CORES[@]:1:$((LOAD-1))}" | tr ' ' ',')
  "$PAYLOAD_BIN" --cpus $PC --rate $PAYLOAD_RATE --seconds $LOADSECS --input "$PAYLOAD_INPUT" --csv $RUN/payload.csv > $RUN/payload.json 2> $RUN/payload.err &
  LOADPIDS+=($!)
fi

if [ "$PINNING" = none ]; then
  sleep 1; for p in $FSWPID "${LOADPIDS[@]}"; do taskset -a -p f $p >> $RUN/sched.txt 2>&1; done
fi
{ echo "== affinity/policy after setup"; for p in $FSWPID "${LOADPIDS[@]}"; do for t in /proc/$p/task/*; do tid=${t##*/}; echo "$p/$tid $(taskset -p $tid 2>/dev/null | awk '{print $NF}') $(chrt -p $tid 2>/dev/null | head -1 | awk -F: '{print $2}')"; done; done; } >> $RUN/sched.txt
# per-core utilisation sampler (1 Hz, /proc/stat deltas)
( prev=""; while true; do cur=$(grep -E '^cpu[0-9]+ ' /proc/stat); t=$(date +%s.%N)
    if [ -n "$prev" ]; then paste <(echo "$prev") <(echo "$cur") | awk -v t=$t '{n=NF/2; b0=0;i0=0;b1=0;i1=0;
      for(k=2;k<=n;k++){b0+=$k; b1+=$(k+n)}; i0=$5+$6; i1=$(5+n)+$(6+n);
      db=b1-b0; di=i1-i0; printf "%s,%s,%.1f\n", t, $1, (db>0)?100*(db-di)/db:0}'; fi
    prev="$cur"; sleep 1; done ) > $RUN/cpu_util.csv 2>/dev/null &
SAMPLER=$!

sleep 5                                    # let the loads reach steady state
if [ "$RATE" = "0" ]; then echo "rate 0: no signing (mission-load baseline)"; sleep $SECS; echo "{}" > $RUN/driver.json
else
( . $VENV/bin/activate; cd $PRJ; python $HERE/fsw_driver.py --rate $RATE --seconds $SECS --mode $DRIVER_MODE --out $RUN/driver.json ) > $RUN/driver.log 2>&1
fi
sleep 5                                    # drain in-flight PeerPings
kill $SAMPLER 2>/dev/null
for p in "${LOADPIDS[@]}"; do wait $p 2>/dev/null; done
$KIT/wcore_check > $RUN/check_after.txt
[ -f $HWCSV ] && tail -n +$((HW0 + 1)) $HWCSV > $RUN/hw_stats_run.csv || : > $RUN/hw_stats_run.csv
cp $RUN/fsw.log $RUN/fsw_full.log 2>/dev/null
stop_all
if [ "$RUN" != "$RUN_FINAL" ]; then cp -a $RUN/. $RUN_FINAL/ && rm -rf $RUN; RUN=$RUN_FINAL; fi
python3 - "$RUN" <<'PYEOF'
import csv, json, os, re, statistics, sys
run = sys.argv[1]; J = lambda f: (json.load(open(os.path.join(run, f))) if os.path.getsize(os.path.join(run, f)) else None) if os.path.exists(os.path.join(run, f)) else None
def lastjson(f):
    p = os.path.join(run, f)
    if not os.path.exists(p): return None
    for line in reversed(open(p, errors='replace').read().splitlines()):
        line = line.strip()
        if line.startswith('{'):
            try: return json.loads(line)
            except Exception: pass
    try: return json.load(open(p))
    except Exception: return None
def q(xs, p): xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else None
P = J('params.json'); fsw = open(os.path.join(run, 'fsw.log'), errors='replace').read() if os.path.exists(os.path.join(run, 'fsw.log')) else ''
rows = [r for r in csv.reader(open(os.path.join(run, 'hw_stats_run.csv'))) if len(r) >= 12]
sign = [r for r in rows if r[1] == 'sign']; ok = [r for r in sign if r[3] == '0']
lat_ms = [float(r[11]) / 1e3 for r in ok]
util = {}
for r in csv.reader(open(os.path.join(run, 'cpu_util.csv'))):
    if len(r) == 3: util.setdefault(r[1], []).append(float(r[2]))
S = dict(params=P, driver=J('driver.json'), adcs=lastjson('adcs.json'), payload=lastjson('payload.json'),
         sign=dict(requested=P['rate'] * P['seconds'], done=len(sign), ok=len(ok), failed=len(sign) - len(ok),
                   backends=sorted({r[2] for r in sign}),
                   lat_ms_p50=q(lat_ms, .5), lat_ms_p99=q(lat_ms, .99), lat_ms_max=max(lat_ms) if lat_ms else None,
                   lat_ms_mean=statistics.mean(lat_ms) if lat_ms else None,
                   pl_attempts_mean=statistics.mean(int(r[5]) for r in ok) if ok and P['backend'] == 'fpga' else None),
         fprime=dict(cycle_slips=len(re.findall(r'RateGroupCycleSlip|cycle slip', fsw, re.I)),
                     hw_errors=fsw.count('HwError') + fsw.count('fail closed'),
                     queue_full=len(re.findall(r'queue full|QUEUE_FULL|ASSERT', fsw, re.I)),
                     peer_accepted=fsw.count('Connected to peer'),
                     peer_failed=fsw.count('peer exchange failed'),
                     peer_frames_received_here=fsw.count('verdict=ACCEPT')),
         cpu_util_mean={k: round(statistics.mean(v), 1) for k, v in sorted(util.items())},
         image_before=open(os.path.join(run, 'check_before.txt')).read().strip() if os.path.exists(os.path.join(run, 'check_before.txt')) else None,
         image_after=open(os.path.join(run, 'check_after.txt')).read().strip() if os.path.exists(os.path.join(run, 'check_after.txt')) else None)
json.dump(S, open(os.path.join(run, 'run_summary.json'), 'w'), indent=1)
print(json.dumps({'run': os.path.basename(run), 'sign': S['sign'], 'fprime': S['fprime'], 'cpu_util_mean': S['cpu_util_mean']}, indent=1))
PYEOF
