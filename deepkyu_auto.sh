#!/usr/bin/env bash
# deepkyu_auto.sh -- closed-loop driver for ONE rung of the deep-kyu even-game ladder.
#
# THE SCRIPT IS THE DECISION-MAKER. There is no human in the loop and no dial is ever
# hand-computed here: the ONLY source of a dial is the "x_next" field of the strict-JSON
# action contract emitted by `deepkyu_place2.py --json-out`. This driver reads that field,
# checks it, and passes it verbatim to `deepkyu_ladder.py set`. Bash never does arithmetic
# on a dial, never rounds one, and never invents one -- not even to recover from an error.
# If the contract is unreadable, self-contradictory, or a version this driver was not
# written against, the driver HALTS. It does not guess.
#
# ---------------------------------------------------------------------------------------
# THE CONTRACT IT OBEYS (deepkyu_place2.py, JSON "contract": 3). Three actions:
#
#   PLAY   x_next is a legal dial and n_next > 0 games. Play them there, then call again.
#   DONE   the rung is certified AT x_next; n_next == 0. Play nothing. Stop the loop.
#   STOP   the target is unattainable on this lever; n_next == 0. Play nothing. Halt and
#          print stop_reason, which is always a statement about DATA.
#
# There is no "CERTIFY" action in contract v3. The state that phrase describes -- keep
# playing where you are -- is expressed as PLAY with "moved": false, i.e. x_next equal to
# the dial already set; the driver then plays a chunk WITHOUT touching the dial. Any action
# string other than the three above is treated as a contract violation and HALTS the loop.
#
# n_suggest is deliberately IGNORED. n_next is the field with the authority; n_suggest
# exists only so the tool's own benchmark can price obedience, and a driver that read it
# would be back in the "charitable mode" that made the shipped benchmark untrustworthy.
#
# ---------------------------------------------------------------------------------------
# HOW A CHUNK IS PLAYED, and why it is not n_next games in one go.
#
# n_next is a BUDGET at a dial (typically 540 games ~ 10 h at rung 1's 56 games/h). It is
# not a safe unit of work here: this environment SIGKILLs a process at ~25-45 min, and a
# katago match killed mid-wave loses every game in flight. So the driver walks the budget
# in COMPLETION WAVES of WAVE games (default 12 = numGameThreads), passing GAMES=<wave> to
# deepkyu_step.sh so numGamesTotal makes katago exit CLEANLY after the wave instead of being
# cut down by the timeout. After every wave the tool is re-run and the contract re-read,
# which is what "re-run the tool after each chunk" means in a campaign whose chunk is a wave.
# The step timeout remains as a backstop only; it should never be what ends a wave.
#
# ---------------------------------------------------------------------------------------
# ANTI-THRASH. Changing the dial changes the bot NAME, which opens a FRESH SGF bucket: the
# games at the old dial are stranded and cannot contribute to a certificate at the new one.
# The tool's tie-break is an indifference band in games, and the fidelity term can and does
# flip the recommendation by one lattice step between waves (observed live: 0.6300 -> 0.6400
# for a cost the tool itself printed as "saves -133 games"). So a dial change is permitted
# at most once per HOLD completed chunks. When the tool asks to move and the hold is not yet
# satisfied, the driver DEFERS: it plays the wave at the dial ALREADY SET -- a dial that a
# previous contract, not this script, chose -- and logs the deferral with the tool's own cost
# numbers, so that every override is auditable. The hold never invents a dial and never
# blocks DONE or STOP.
#
# ---------------------------------------------------------------------------------------
# KILL-SAFETY. Every iteration is idempotent and re-derived from disk: the SGFs are the
# state, the tool is re-run from scratch each time, and the only thing this driver persists
# is the anti-thrash bookkeeping (written atomically, AFTER the wave it counts, so a kill
# can only ever make the driver more reluctant to move, never less). Kill it at any point
# and re-run the same command line; it resumes. It holds no katago and no GPU itself.
#
# CONCURRENCY. Games are played ONLY by deepkyu_step.sh, which takes the campaign's atomic
# mkdir lock at $RUN/.busy.d and so serializes against every other step on this machine --
# one katago at a time, always. This driver additionally takes its own singleton lock at
# $RUN/.auto.d so that two drivers cannot alternate waves and thrash the dial between them.
# Both locks carry a pid and are reclaimed when that pid is gone.
#
# ---------------------------------------------------------------------------------------
# USAGE
#   bash deepkyu_auto.sh --dry-run              # decide and print, play nothing, touch nothing
#   bash deepkyu_auto.sh                        # closed loop on rung 1 until CERTIFIED or STOP
#   bash deepkyu_auto.sh --rung 1 --hold 4 --wave 12 --max-iters 20
#   bash deepkyu_auto.sh --reset                # forget the anti-thrash counter and start fresh
#
# FLAGS (each also settable as an environment variable)
#   --dry-run            DRY=1          decide, print, and exit without playing or writing
#   --rung N             RUNG=1         which ladder rung to drive
#   --wave G             WAVE=12        games per katago invocation (one completion wave)
#   --hold N             HOLD=3         chunks that must pass between two dial changes
#   --max-iters N        MAX_ITERS=0    stop after N iterations (0 = until certified/stopped)
#   --step-timeout S     STEP_TIMEOUT=1800   backstop timeout, seconds, per wave
#   --reset              RESET=1        clear the persisted anti-thrash state first
#   --threads/--nnbatch/--nnserver      THREADS=12 NNBATCH=8 NNSERVER=1 (see deepkyu_step.sh)
#
# EXIT CODES
#   0  the rung is CERTIFIED (ladder status), or the tool returned DONE, or --max-iters hit
#   2  the tool returned STOP: the target is unattainable on this lever (stop_reason logged)
#   3  HALT -- contract violation, unreadable JSON, or a state the driver must not guess at
#   4  HALT -- the decision tool failed repeatedly
#   5  another deepkyu_auto.sh is already running
# ---------------------------------------------------------------------------------------
set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# One campaign root for every child. deepkyu_step.sh reads RUN; deepkyu_ladder.py (and so
# deepkyu_place2.py, which gets its SGF dir and cache from it) reads DEEPKYU_RUN. Resolving them
# together is what stops a driver from deciding against one campaign and playing into another.
RUN=${RUN:-${DEEPKYU_RUN:-$HOME/.katago_tune/deepkyu}}
export DEEPKYU_RUN="$RUN"

RUNG=${RUNG:-1}
WAVE=${WAVE:-12}
HOLD=${HOLD:-3}
MAX_ITERS=${MAX_ITERS:-0}
THREADS=${THREADS:-12}
NNBATCH=${NNBATCH:-8}
NNSERVER=${NNSERVER:-1}
STEP_TIMEOUT=${STEP_TIMEOUT:-1800}
DRY=${DRY:-0}
RESET=${RESET:-0}
MAX_TOOL_FAILS=${MAX_TOOL_FAILS:-3}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n)    DRY=1 ;;
    --rung)          RUNG=$2; shift ;;
    --wave)          WAVE=$2; shift ;;
    --hold)          HOLD=$2; shift ;;
    --max-iters)     MAX_ITERS=$2; shift ;;
    --step-timeout)  STEP_TIMEOUT=$2; shift ;;
    --threads)       THREADS=$2; shift ;;
    --nnbatch)       NNBATCH=$2; shift ;;
    --nnserver)      NNSERVER=$2; shift ;;
    --reset)         RESET=1 ;;
    -h|--help)       awk 'NR==1{next} !/^#/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 3 ;;
  esac
  shift
done

LOGDIR="$RUN/logs"
LOG="$LOGDIR/auto.log"
ARCHIVE="$LOGDIR/auto"
STATE="$RUN/auto_rung${RUNG}.state"
ACT="$RUN/auto_rung${RUNG}_action.json"
BUSY="$RUN/.busy.d"
ALOCK="$RUN/.auto.d"
mkdir -p "$LOGDIR" "$ARCHIVE"

# Rotate before appending, so a loop that runs for days cannot fill the disk the campaign needs.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 52428800 ]; then
  mv -f "$LOG" "$LOG.1"
fi

ts()  { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG"; }
logf() { printf '%s\n' "$*" | tee -a "$LOG"; }          # continuation line, no timestamp
cat_into_log() { sed 's/^/  | /' "$1" | tee -a "$LOG"; }  # the tool's own reasoning, quoted

# ---------------------------------------------------------------- singleton driver lock
release_alock() { [ "${ALOCK_HELD:-0}" = "1" ] && rm -rf "$ALOCK"; }
ALOCK_HELD=0
if [ "$DRY" = "0" ]; then
  if ! mkdir "$ALOCK" 2>/dev/null; then
    owner=$(cat "$ALOCK/pid" 2>/dev/null || echo "")
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      log "REFUSING TO START: deepkyu_auto.sh is already running as pid $owner"
      exit 5
    fi
    rm -rf "$ALOCK"; mkdir "$ALOCK" 2>/dev/null || { log "REFUSING TO START: cannot take $ALOCK"; exit 5; }
    log "cleared a stale driver lock from pid ${owner:-?}"
  fi
  echo $$ > "$ALOCK/pid"; ALOCK_HELD=1
  trap 'release_alock' EXIT
fi

# ---------------------------------------------------------------- persisted state (TAB kv)
st_get() { # st_get KEY DEFAULT
  local v=""
  [ -f "$STATE" ] && v=$(awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$STATE")
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}
st_put() { # st_put dial chunks_at_dial changes iters  -- atomic
  [ "$DRY" = "1" ] && return 0
  local tmp="$STATE.tmp.$$"
  { printf 'rung\t%s\n' "$RUNG"
    printf 'dial\t%s\n' "$1"
    printf 'chunks_at_dial\t%s\n' "$2"
    printf 'changes\t%s\n' "$3"
    printf 'iters\t%s\n' "$4"
    printf 'updated\t%s\n' "$(ts)"; } > "$tmp" && mv -f "$tmp" "$STATE"
}

if [ "$RESET" = "1" ] && [ "$DRY" = "0" ]; then rm -f "$STATE"; fi

# ---------------------------------------------------------------- ladder helpers
ladder_dial() {  # the dial currently written in ladder.json, formatted losslessly
  python3 - "$HERE" "$RUNG" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import deepkyu_ladder as dl
st = dl.load(); i = int(sys.argv[2]) - 1
r = st["ranks"][i]
s = "%.10g" % float(r["x"])
assert float(s) == float(r["x"]), "dial does not round-trip"
print("%s\t%s" % (r["rank"], s))
PY
}

rung_status() {  # -> writes status to $1; returns 0 if THIS rung is CERTIFIED
  python3 "$HERE/deepkyu_ladder.py" status > "$1" 2>&1 || return 2
  awk -v r="$RUNG" '$1==r && $NF=="CERTIFIED"{f=1} END{exit f?0:1}' "$1"
}

# ---------------------------------------------------------------- the contract reader
# Strict: rejects bare NaN/Infinity (RFC 8259), the wrong contract version, an action this
# driver does not know, any n_next that contradicts its action, an out-of-domain or
# off-lattice dial, and a rank that disagrees with ladder.json. Emits TAB key/value.
read_contract() { # read_contract ACTJSON -> kv on stdout; rc 0 ok, 3 violation
  python3 - "$HERE" "$1" "$RUNG" <<'PY'
import json, sys, math
sys.path.insert(0, sys.argv[1])

def bare(tok):
    raise ValueError("the tool emitted the bare token %s, which is not JSON (RFC 8259)" % tok)

def die(msg):
    sys.stderr.write("CONTRACT VIOLATION: %s\n" % msg); sys.exit(3)

try:
    d = json.loads(open(sys.argv[2]).read(), parse_constant=bare)
except Exception as e:
    die("could not parse %s strictly: %s" % (sys.argv[2], e))

if d.get("contract") != 3:
    die("contract version %r; this driver was written against version 3. Re-read the "
        "contract in deepkyu_place2.py and update deepkyu_auto.sh before running a loop."
        % (d.get("contract"),))

action = d.get("action")
if action not in ("PLAY", "DONE", "STOP"):
    die("action %r is not one of PLAY / DONE / STOP" % (action,))

n = d.get("n_next")
if not isinstance(n, int) or isinstance(n, bool):
    die("n_next is %r, not an int" % (n,))
if action == "PLAY" and n <= 0:
    die("PLAY with n_next = %d: the loop would not terminate" % n)
if action != "PLAY" and n != 0:
    die("%s with n_next = %d -- those games would be played nowhere" % (action, n))
if action == "STOP" and not d.get("stop_reason"):
    die("STOP with no stop_reason")

import deepkyu_place2 as p2, deepkyu_ladder as dl
x = d.get("x_next")
if x is None:
    die("x_next is null: this driver has no other source for a dial and will not invent one")
if True:
    if not isinstance(x, float) and not isinstance(x, int):
        die("x_next is %r, not a number" % (x,))
    x = float(x)
    if not math.isfinite(x):
        die("x_next is not finite")
    if not p2.in_domain(x):
        die("x_next %.6f is outside the legal dial domain [%.2f, %.2f]" % (x, p2.X_LO, p2.X_HI))
    if abs(p2.snap(x) - x) > 1e-9:
        die("x_next %.6f is off the %.3f lattice: it would open an SGF bucket that no later "
            "chunk can land in again" % (x, p2.LATTICE))

# the dial string handed to `deepkyu_ladder.py set` -- formatted, then proved to round-trip,
# so the driver can never ship a rounded dial.
xs = "%.10g" % x
if float(xs) != x:
    die("x_next %r does not round-trip through its text form %r" % (x, xs))

st = dl.load()
rk = st["ranks"][int(sys.argv[3]) - 1]["rank"]
if d.get("rank") and d["rank"] != rk:
    die("the tool decided for rank %r but ladder.json rung %s is rank %r"
        % (d["rank"], sys.argv[3], rk))
xc = st["ranks"][int(sys.argv[3]) - 1]["x"]

def flat(v):
    if v is None:  return ""
    if isinstance(v, bool): return "1" if v else "0"
    if isinstance(v, float): return "%.6g" % v
    return str(v).replace("\t", " ").replace("\n", " ")

fwd = d.get("forward") or {}
sens = d.get("sensitivity") or []
xs_set = sorted({s.get("x_next") for s in sens if s.get("x_next") is not None})
out = {
    "action": action, "x_next": xs, "n_next": str(n), "rank": rk,
    "x_cur": "%.10g" % float(xc),
    "moved": flat(d.get("moved")), "bot": flat(d.get("bot")), "strong": flat(d.get("strong")),
    "target": flat(d.get("target")), "n_suggest": flat(d.get("n_suggest")),
    "stop_reason": flat(d.get("stop_reason")), "hopeless": flat(d.get("hopeless")),
    "room": flat(d.get("room")), "why_room": flat(d.get("why_room")),
    "p_safe": flat(d.get("p_safe")), "p_band": flat(d.get("p_band")),
    "prior_dependent": flat(d.get("prior_dependent")),
    "med_gap": flat(d.get("med_gap")), "miss": flat(d.get("expected_target_miss")),
    "bank_n": flat((d.get("bank") or [None, None])[1]),
    "p_cert": flat(fwd.get("p_cert")), "fwd_med": flat(fwd.get("med")),
    "sens_spread": flat(round(max(xs_set) - min(xs_set), 6) if xs_set else None),
    "sens_agree": flat(sum(1 for s in sens if s.get("x_next") == d.get("x_next"))),
    "sens_n": flat(len(sens)),
    "certified_at": flat(d.get("certified_at")), "gap": flat(d.get("gap")),
    "pub_ci": flat(d.get("pub_ci")), "n_cert": flat(d.get("n")),
    # contract v3: the rule is two-sided, so a dial can be OVERSHOT -- still nominally alive,
    # but past the point at which its own coverage half can be recovered -- and a certificate
    # has a LIFETIME, after which more games into the same bucket destroy it.
    "x_cur_dead": flat(d.get("x_cur_dead")), "p_centre": flat(d.get("p_centre")),
    "survives_to": flat(d.get("survives_to")), "headroom": flat(d.get("headroom")),
}
for k, v in out.items():
    sys.stdout.write("%s\t%s\n" % (k, v))
PY
}

# ---------------------------------------------------------------- banner
log "==================================================================================="
log "deepkyu_auto.sh  rung=$RUNG  wave=$WAVE games  hold=$HOLD chunks  max-iters=${MAX_ITERS:-0}$([ "$DRY" = "1" ] && echo '  [DRY RUN]')"
log "repo=$HERE  run=$RUN  pid=$$"
IFS=$'\t' read -r RANK DIAL0 < <(ladder_dial) || { log "HALT: cannot read ladder.json"; exit 3; }
log "rung $RUNG is rank $RANK, dial currently x=$DIAL0"

S_DIAL=$(st_get dial "$DIAL0")
S_CHG=$(st_get changes 0)
S_IT=$(st_get iters 0)
if [ ! -f "$STATE" ]; then
  # No bookkeeping yet -- but "how long has this dial been served" is not a thing to guess at
  # when the campaign already records it. The current dial's OWN bucket holds N games, so it has
  # already served floor(N / WAVE) chunk-equivalents; that is what the hold is about (games
  # committed to a bucket that a dial change would strand). A dial with no games is unserved and
  # the hold bites from the first wave, which is exactly when thrash is most expensive.
  BOOT="$ARCHIVE/status_boot.txt"
  S_CH=$HOLD
  if rung_status "$BOOT"; then :; fi
  BANK=$(awk -v r="$RUNG" '$1==r{print $4+0; exit}' "$BOOT" 2>/dev/null)
  if [ -n "${BANK:-}" ]; then
    S_CH=$(( BANK / WAVE )); [ "$S_CH" -gt "$HOLD" ] && S_CH=$HOLD
    log "no anti-thrash state at $STATE: the current dial x=$DIAL0 already banks $BANK game(s),"
    logf "   i.e. $S_CH chunk-equivalent(s) of the $HOLD required -- derived from deepkyu_ladder.py"
    logf "   status, not assumed."
  else
    log "no anti-thrash state at $STATE and status gave no bank: assuming the hold is served."
  fi
elif S_CH=$(st_get chunks_at_dial 0); [ "$S_DIAL" != "$DIAL0" ]; then
  log "ANTI-THRASH RESET: state remembers dial $S_DIAL but ladder.json says $DIAL0 -- the dial"
  logf "                    was changed outside this driver, so the hold restarts at 0 chunks."
  S_CH=0; S_DIAL=$DIAL0
else
  log "resuming: $S_CH chunk(s) played at dial $S_DIAL, $S_CHG dial change(s), $S_IT iteration(s) so far"
fi

if [ -d "$BUSY" ]; then
  bowner=$(cat "$BUSY/pid" 2>/dev/null || echo "?")
  if kill -0 "$bowner" 2>/dev/null; then
    log "NOTE: the campaign lock $BUSY is held by pid $bowner (a katago step is running)."
    logf "      deepkyu_step.sh will queue behind it; one katago at a time is preserved."
  else
    log "NOTE: $BUSY is stale (pid ${bowner}); deepkyu_step.sh will reclaim it."
  fi
fi

TOOL_FAILS=0
IT=0
while :; do
  IT=$((IT + 1))
  log "-----------------------------------------------------------------------------------"
  log "ITERATION $IT (lifetime $((S_IT + IT)))"

  # (4a) THE GOAL GATE -- deepkyu_ladder.py status is the campaign's own definition of done.
  STFILE="$ARCHIVE/status_$(date +%Y%m%d_%H%M%S).txt"
  rung_status "$STFILE"; rc=$?
  if [ "$rc" = "0" ]; then
    log "STOP THE LOOP: deepkyu_ladder.py status reports rung $RUNG CERTIFIED."
    awk -v r="$RUNG" '$1==r' "$STFILE" | tee -a "$LOG"
    exit 0
  fi
  if [ "$rc" != "1" ]; then log "HALT: deepkyu_ladder.py status failed (rc=$rc)"; cat_into_log "$STFILE"; exit 3; fi
  log "not yet certified:"
  awk -v r="$RUNG" '$1==r' "$STFILE" | sed 's/^/  | /' | tee -a "$LOG"

  # (1) RUN THE DECISION TOOL. It is the only thing allowed to choose a dial.
  STAMP=$(date +%Y%m%d_%H%M%S)
  REPORT="$ARCHIVE/report_$STAMP.txt"
  # --acc-k 1 turns the GEOMETRIC continuation OFF (identity extrapolant, the pre-fix tool).
  # Adversarial verification (workflow w4a1rs5jd, verify:noise-amplification) REJECTED the
  # geometric branch on measured grounds: on an exactly LINEAR truth the acceleration factor fires
  # from binomial noise on 46-53% of designs, costing a resolved P(certify) of -0.046 [-0.072,-0.020]
  # at 600-game arms and -0.094 [-0.118,-0.070] at 2400, and it costs a RESOLVED +419 [+102,+786]
  # games on `compound` -- the very truth it was built for. The flag is preferred over editing
  # ACC_K because selftest [13] asserts the two branches differ; a source revert needs [13] relaxed
  # in the same commit. Drop the flag only if [13] is re-specified and the harm is re-measured.
  log "running: python3 deepkyu_place2.py --rung $RUNG --acc-k 1 --json-out $ACT"
  if ! python3 "$HERE/deepkyu_place2.py" --rung "$RUNG" --acc-k 1 --json-out "$ACT" > "$REPORT" 2>&1; then
    if grep -q "no games at all for this rung" "$REPORT"; then
      # Cold start: the tool cannot decide with zero games, and this driver must not invent a
      # dial to break the deadlock. It plays ONE wave at the dial ALREADY in ladder.json --
      # a dial chosen by whoever configured the rung, not computed here -- and re-asks.
      log "BOOTSTRAP: the rung has no games, so the tool cannot decide yet."
      logf "           playing one wave at the dial already configured (x=$DIAL0); no dial is computed here."
      if [ "$DRY" = "1" ]; then
        log "DRY RUN: would play $WAVE games at x=$DIAL0 and re-run the tool."; exit 0
      fi
      RUN="$RUN" RUNGS="$RUNG" N=1 GAMES="$WAVE" CHUNK="$STEP_TIMEOUT" THREADS="$THREADS" \
        NNBATCH="$NNBATCH" NNSERVER="$NNSERVER" bash "$HERE/deepkyu_step.sh" 2>&1 | tee -a "$LOG"
      S_CH=$((S_CH + 1)); st_put "$DIAL0" "$S_CH" "$S_CHG" "$((S_IT + IT))"
      continue
    fi
    TOOL_FAILS=$((TOOL_FAILS + 1))
    log "the decision tool FAILED (attempt $TOOL_FAILS/$MAX_TOOL_FAILS):"
    tail -20 "$REPORT" | sed 's/^/  | /' | tee -a "$LOG"
    [ "$TOOL_FAILS" -ge "$MAX_TOOL_FAILS" ] && { log "HALT: the decision tool failed $TOOL_FAILS times in a row."; exit 4; }
    sleep 30; continue
  fi
  TOOL_FAILS=0
  cp -f "$ACT" "$ARCHIVE/act_$STAMP.json" 2>/dev/null || true

  # THE TOOL'S REASONING, into the log verbatim. This is the audit trail: a driver with no
  # human in it must leave behind exactly why it did what it did.
  log "the tool's report (archived at $REPORT):"
  cat_into_log "$REPORT" >/dev/null
  sed -n '/-- 5. ACTION/,$p' "$REPORT" | sed 's/^/  | /'

  # (2) PARSE AND VERIFY THE CONTRACT.
  KV="$ARCHIVE/kv_$STAMP.tsv"
  if ! read_contract "$ACT" > "$KV" 2>"$KV.err"; then
    log "HALT: the action contract did not verify."
    cat_into_log "$KV.err"
    exit 3
  fi
  ACTION=""; X_NEXT=""; N_NEXT=""; X_CUR=""; BOT=""; STOP_REASON=""; WHY_ROOM=""
  MOVED=""; P_SAFE=""; P_BAND=""; PRIOR_DEP=""; MED_GAP=""; MISS=""; BANK_N=""
  P_CERT=""; FWD_MED=""; SENS_SPREAD=""; SENS_AGREE=""; SENS_N=""; TARGET=""; N_SUGGEST=""
  CERT_AT=""; GAP=""; PUB_CI=""; N_CERT=""; HOPELESS=""; ROOM=""
  X_CUR_DEAD=""; P_CENTRE=""; SURVIVES=""; HEADROOM=""
  while IFS=$'\t' read -r k v; do
    case "$k" in
      action) ACTION=$v;; x_next) X_NEXT=$v;; n_next) N_NEXT=$v;; x_cur) X_CUR=$v;;
      bot) BOT=$v;; stop_reason) STOP_REASON=$v;; why_room) WHY_ROOM=$v;; moved) MOVED=$v;;
      p_safe) P_SAFE=$v;; p_band) P_BAND=$v;; prior_dependent) PRIOR_DEP=$v;;
      med_gap) MED_GAP=$v;; miss) MISS=$v;; bank_n) BANK_N=$v;; p_cert) P_CERT=$v;;
      fwd_med) FWD_MED=$v;; sens_spread) SENS_SPREAD=$v;; sens_agree) SENS_AGREE=$v;;
      sens_n) SENS_N=$v;; target) TARGET=$v;; n_suggest) N_SUGGEST=$v;;
      certified_at) CERT_AT=$v;; gap) GAP=$v;; pub_ci) PUB_CI=$v;; n_cert) N_CERT=$v;;
      hopeless) HOPELESS=$v;; room) ROOM=$v;;
      x_cur_dead) X_CUR_DEAD=$v;; p_centre) P_CENTRE=$v;;
      survives_to) SURVIVES=$v;; headroom) HEADROOM=$v;;
    esac
  done < "$KV"

  log "CONTRACT v3 VERIFIED: action=$ACTION x_next=$X_NEXT n_next=$N_NEXT (x_cur=$X_CUR target=$TARGET)"
  logf "   bot=$BOT  med_gap=$MED_GAP  P(centre)=$P_CENTRE  P(cert)=$P_CERT  bank=$BANK_N games"
  [ "$X_CUR_DEAD" = "1" ] && logf "   x_cur=$X_CUR is DEAD (refuted or overshot): no game played there can certify."
  logf "   n_suggest=$N_SUGGEST (IGNORED BY DESIGN: n_next is the field with the authority)"
  logf "   hopeless=$HOPELESS room=$ROOM  why_room: $WHY_ROOM"
  [ "$PRIOR_DEP" = "1" ] && logf "   PRIOR-DEPENDENT: p_safe=$P_SAFE < 0.90 -- monotonicity alone does not pin this dial."
  logf "   sensitivity: $SENS_AGREE/$SENS_N assumptions agree, dial spread $SENS_SPREAD"

  # (4b) THE OTHER TWO EXITS.
  if [ "$ACTION" = "DONE" ]; then
    log "STOP THE LOOP: the tool returns DONE -- the rung is certified."
    logf "   certified_at=$CERT_AT  n=$N_CERT  gap=$GAP  published 95% CI $PUB_CI"
    logf "   FREEZE THIS BUCKET: the certificate survives to n=${SURVIVES:-unbounded} games (${HEADROOM:-unbounded} more)."
    logf "   The rule is two-sided, so games added to a certified bucket re-test coverage at a"
    logf "   NARROWER window and can destroy a certificate that is already published. Do not"
    logf "   play another game against $CERT_AT. (deepkyu_ladder.py plan already drops a"
    logf "   certified rung from ACTIVE, so a plain campaign step will not top it up.)"
    if [ "$X_NEXT" != "$X_CUR" ]; then
      log "NOTE: the certificate stands at x=$X_NEXT but ladder.json is set to x=$X_CUR."
      logf "      This driver does not move the dial on DONE (the contract says play nothing),"
      logf "      so \`deepkyu_ladder.py status\` will keep reporting the CURRENT dial's bucket."
      logf "      An operator who wants status to show the certificate must set it deliberately."
    fi
    exit 0
  fi
  if [ "$ACTION" = "STOP" ]; then
    log "STOP THE LOOP: the tool returns STOP -- the target is UNATTAINABLE on this lever."
    logf "   stop_reason: $STOP_REASON"
    logf "   (hopeless=$HOPELESS and room=$ROOM: both halves of the stop gate are satisfied,"
    logf "    so this is a statement about the data, not about the absence of data.)"
    exit 2
  fi

  # (3) PLAY. From here the action is PLAY and n_next > 0.
  PLAY_AT="$X_NEXT"
  CHANGE=0
  if [ "$X_NEXT" = "$X_CUR" ]; then
    log "DECISION: PLAY at the dial already set (x=$X_CUR). No dial change, no new SGF bucket."
  elif [ "$S_CH" -lt "$HOLD" ] && [ "$X_CUR_DEAD" != "1" ]; then
    PLAY_AT="$X_CUR"
    log "ANTI-THRASH OVERRIDE: the tool asks to move x=$X_CUR -> x=$X_NEXT, but only $S_CH of the"
    logf "   required $HOLD chunk-equivalent(s) have been served at this dial. A change strands this"
    logf "   bucket's games, and the tool's own tie band is wider than the lattice step it is"
    logf "   asking for. DEFERRING: this wave is played at the dial ALREADY SET (x=$X_CUR),"
    logf "   which a previous contract chose; nothing is computed here. The move will be"
    logf "   re-proposed (or withdrawn) by the tool after $((HOLD - S_CH)) more chunk(s)."
  elif [ "$X_CUR_DEAD" = "1" ]; then
    CHANGE=1
    log "DECISION: CHANGE THE DIAL x=$X_CUR -> x=$X_NEXT -- x_cur is DEAD, so the anti-thrash"
    logf "   hold is OVERRIDDEN ($S_CH of $HOLD chunk-equivalents served). The hold exists to stop"
    logf "   the tool stranding a bucket that could still certify; a refuted or OVERSHOT bucket"
    logf "   cannot, and every further wave into it is waste that deepens the overshoot."
  else
    CHANGE=1
    log "DECISION: CHANGE THE DIAL x=$X_CUR -> x=$X_NEXT ($S_CH >= $HOLD chunk-equivalents served here)."
    logf "   this opens a fresh SGF bucket: the games at x=$X_CUR stay with x=$X_CUR."
  fi
  NPLAY=$WAVE
  [ "$N_NEXT" -lt "$NPLAY" ] && NPLAY=$N_NEXT
  log "PLAN: play $NPLAY game(s) at x=$PLAY_AT (one completion wave; the tool's budget n_next=$N_NEXT"
  logf "      is walked $WAVE at a time so a SIGKILL costs at most one wave), then re-run the tool."

  if [ "$DRY" = "1" ]; then
    log "DRY RUN -- nothing below is executed:"
    [ "$CHANGE" = "1" ] && logf "   WOULD RUN: python3 $HERE/deepkyu_ladder.py set \"$RANK=$X_NEXT\""
    [ "$CHANGE" = "0" ] && logf "   WOULD RUN: (no dial change)"
    logf "   WOULD RUN: RUNGS=$RUNG N=1 GAMES=$NPLAY CHUNK=$STEP_TIMEOUT THREADS=$THREADS NNBATCH=$NNBATCH NNSERVER=$NNSERVER bash $HERE/deepkyu_step.sh"
    logf "   WOULD THEN: re-run deepkyu_place2.py and repeat, until status says CERTIFIED or the tool says STOP."
    logf "   WOULD WRITE state: dial=$PLAY_AT chunks_at_dial=$([ "$CHANGE" = "1" ] && echo 1 || echo $((S_CH + 1))) changes=$((S_CHG + CHANGE))"
    log "DRY RUN COMPLETE: no games played, no dial written, no lock taken, no state written."
    exit 0
  fi

  if [ "$CHANGE" = "1" ]; then
    python3 "$HERE/deepkyu_ladder.py" set "$RANK=$X_NEXT" 2>&1 | sed 's/^/  | /' | tee -a "$LOG"
    NEWD=$(ladder_dial | cut -f2)
    if [ "$NEWD" != "$X_NEXT" ]; then
      log "HALT: asked for $RANK=$X_NEXT but ladder.json now reads $NEWD."
      exit 3
    fi
    S_CH=0; S_CHG=$((S_CHG + 1))
    st_put "$X_NEXT" 0 "$S_CHG" "$((S_IT + IT))"
  fi

  log "playing: RUNGS=$RUNG N=1 GAMES=$NPLAY CHUNK=$STEP_TIMEOUT -> deepkyu_step.sh (it takes $BUSY)"
  RUN="$RUN" RUNGS="$RUNG" N=1 GAMES="$NPLAY" CHUNK="$STEP_TIMEOUT" THREADS="$THREADS" \
    NNBATCH="$NNBATCH" NNSERVER="$NNSERVER" bash "$HERE/deepkyu_step.sh" 2>&1 \
    | sed 's/^/  | /' | tee -a "$LOG"
  S_CH=$((S_CH + 1))
  st_put "$PLAY_AT" "$S_CH" "$S_CHG" "$((S_IT + IT))"
  log "wave complete: $S_CH chunk-equivalent(s) now served at x=$PLAY_AT; re-running the tool."

  if [ "$MAX_ITERS" != "0" ] && [ "$IT" -ge "$MAX_ITERS" ]; then
    log "stopping: --max-iters $MAX_ITERS reached (the rung is NOT certified; re-run to continue)."
    exit 0
  fi
done
