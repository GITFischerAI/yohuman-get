#!/usr/bin/env bash
# Yo Human installer — makes your local Claude Code driveable from the Yo Human app.
# Usage:  curl -fsSL https://yohuman.ai/yohuman-install.sh | bash -s -- YOUR-PAIRING-CODE
set -euo pipefail
CODE="${1:-}"
HD="$HOME/.yohuman-v2"; BIN="$HD/bin"
echo "→ Yo Human setup starting…"
command -v claude >/dev/null || { echo "✗ Claude Code not found. Install: https://claude.com/claude-code"; exit 1; }
command -v jq     >/dev/null || { echo "✗ jq not found. Install: brew install jq"; exit 1; }
command -v screen >/dev/null || { echo "✗ screen missing (ships with macOS?)."; exit 1; }
command -v curl   >/dev/null || { echo "✗ curl missing."; exit 1; }
echo "✓ prerequisites OK"
mkdir -p "$BIN" "$HD/spool" "$HD/inbox" "$HD/log" "$HD/run"
cat > "$BIN/lib.sh" <<'YH__ENGINE__EOF'
#!/usr/bin/env bash
# Yo Human V2 — shared injection library (the "typing engine" core).
# Encodes everything proven in Phase 0. Source this; don't run it directly.
#
# Hard-won rules baked in (see docs/V2_PHASE0_FINDINGS.md):
#   - `screen -X` needs `-p 0` or it silently no-ops.
#   - The Claude TUI submits on carriage return (\r), NOT line-feed.
#   - Let the TUI settle briefly before the first keystroke.
#   - On a free-text menu option: type FIRST, then Enter (never Enter-first).
#   - `hardcopy` is unreliable; the continuous `screen -L` log is the truth.
#   - Navigate menus by COUNTING ROWS from the hook's option list — never blind.

. "$HOME/.yohuman-v2/config.sh" 2>/dev/null

SESS="${YH_V2_SCREEN:-yh-v2}"
LOG="${YH_V2_LOG:-$HOME/.yohuman-v2/log}/screenlog.0"
CR="$(printf '\r')"
SETTLE="${YH_SETTLE:-0.8}"   # seconds to let the TUI render between actions
VERIFY="${YH_VERIFY:-1.8}"   # seconds before reading the log (must exceed the 1s flush)

# --- raw key helpers ---------------------------------------------------------
yh_send()        { screen -S "$SESS" -p 0 -X stuff "$1"; }              # raw bytes, no Enter
yh_enter()       { screen -S "$SESS" -p 0 -X stuff "$CR"; }
yh_clear_input() { screen -S "$SESS" -p 0 -X stuff "$(printf '\025')"; } # Ctrl-U kills the line
yh_down()        { screen -S "$SESS" -p 0 -X stuff "$(printf '\033[B')"; }
yh_up()          { screen -S "$SESS" -p 0 -X stuff "$(printf '\033[A')"; }
yh_esc()         { screen -S "$SESS" -p 0 -X stuff "$(printf '\033')"; }       # Esc — reject/cancel

# Type text then submit (settle between, so the TUI captures it all).
yh_type_submit() { yh_send "$1"; sleep "$SETTLE"; yh_enter; }

# --- session / log -----------------------------------------------------------
# NOTE: `screen -ls` always exits non-zero, so under `set -o pipefail` a piped grep
# would wrongly report "dead". Capture first, then match.
# Extract the agent's self-written one-line card — the text inside 📱[[ ... ]] — from the
# screen log. The TUI splits words with CSI cursor-column moves, so convert those to spaces,
# then pull the bracketed text. Vendor-neutral: works for ANY agent told to emit the marker
# (no Claude transcript dependency). $1 = optional log file (defaults to $LOG).
yh_extract_card() {
  local f="${1:-$LOG}"
  sed -E $'s/\033\\[[0-9;?]*[A-Za-z]/ /g' "$f" 2>/dev/null \
    | tr -d '\r' | sed 's/[^[:print:]]//g' \
    | grep -oE '\[\[[^][]+\]\]' | tail -1 \
    | sed -E 's/^\[\[//; s/\]\]$//' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

yh_session_alive() { local out; out="$(screen -ls 2>/dev/null)"; printf '%s' "$out" | grep -q "[.]$SESS[[:space:]]"; }
yh_log_clean()     { sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g' "$LOG" 2>/dev/null | sed 's/[^[:print:]]//g'; }
yh_log_bytes()     { wc -c < "$LOG" 2>/dev/null | tr -d ' '; }

# --- the watchdog primitive: did our keystrokes actually land? ----------------
# Sends a unique marker as raw text (no submit), confirms it appears in the log,
# then clears it. Returns 0 if the engine can type into the session, 1 if not.
yh_injection_landed() {
  local marker="YHPROBE_${1:-$$}"
  yh_clear_input; sleep 0.3
  yh_send "$marker"; sleep "$VERIFY"   # wait past the log flush before reading
  if yh_log_clean | grep -q "$marker"; then
    yh_clear_input
    return 0
  fi
  yh_clear_input
  return 1
}

# Wait until a selection menu is actually rendered (avoids racing a half-drawn menu,
# which drops keystrokes). "Esc to cancel" is present whenever a menu is open.
# Pair with a per-step log truncation so this never matches a stale menu.
yh_wait_menu() {
  local d=$(( $(date +%s) + ${1:-10} ))
  while [ "$(date +%s)" -lt "$d" ]; do
    if yh_log_clean | grep -q "Esc to cancel"; then sleep 0.8; return 0; fi
    sleep 0.4
  done
  return 1
}

# --- multiple-choice navigation by ROW COUNT (never blind) -------------------
# yh_pick_choice <target_index> <total_options>
# Moves the highlight from the default (row 1) DOWN to <target_index>. The caller
# derives indices from the hook's captured option list — see p1-hook.sh's spool.
yh_pick_choice() {
  local target="$1" steps
  steps=$(( target - 1 ))
  [ "$steps" -lt 0 ] && steps=0
  local i=0
  while [ "$i" -lt "$steps" ]; do yh_down; sleep 0.4; i=$((i+1)); done
  sleep "$SETTLE"
  yh_enter   # select the highlighted option
}

# Answer via the free-text ("Type something" / Other) row, by row count.
# yh_answer_other <other_row_index> <text>
# Navigate to the Other row, then TYPE the text (not Enter-first), then submit.
yh_answer_other() {
  local row="$1" text="$2" steps i=0
  steps=$(( row - 1 )); [ "$steps" -lt 0 ] && steps=0
  while [ "$i" -lt "$steps" ]; do yh_down; sleep 0.4; i=$((i+1)); done
  sleep "$SETTLE"
  yh_send "$text"    # type directly into the highlighted free-text field
  sleep "$SETTLE"
  yh_enter           # submit
}
YH__ENGINE__EOF
cat > "$BIN/yohuman" <<'YH__ENGINE__EOF'
#!/usr/bin/env bash
# yohuman — the ONE command a user runs. Launches Claude Code so their phone can drive it,
# bringing up the whole engine (file watcher + reply poller) invisibly. No API, all local.
#
#   yohuman              → same as `yohuman code` in the current folder
#   yohuman code [dir]   → start a phone-driveable Claude Code session (attaches, feels normal)
#   yohuman up           → just start the background engine (watcher + reply poller)
#   yohuman down         → stop the engine + any managed session
#   yohuman status       → what's running
#   yohuman pair <code>  → save the pairing code you got from the Yo Human app
#
# The only thing a user does differently from normal Claude Code is type `yohuman` instead of
# `claude`. Everything else — the watcher, the reply rail — is handled for them.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOME/.yohuman-v2/config.sh" 2>/dev/null

case "${1:-code}" in
  code|"")
    [ "${1:-}" = "code" ] && shift
    # 1) bring up the background engine (idempotent, silent)
    bash "$HERE/yohuman-engine.sh" daemons >/dev/null 2>&1
    # 2) launch + attach Claude Code inside the wrapper — looks/feels like normal `claude`
    echo "🟢 Yo Human is on — work normally, then step away. Your phone will reach you."
    exec bash "$HERE/yohuman-code.sh" "${1:-$PWD}"
    ;;
  up)      bash "$HERE/yohuman-engine.sh" daemons ;;
  down)    bash "$HERE/yohuman-engine.sh" down ;;
  status)  bash "$HERE/yohuman-engine.sh" status ;;
  pair)
    code="${2:?usage: yohuman pair <code>}"
    mkdir -p "$HOME/.yohuman-v2"
    # Persist the pairing channel for the engine + poller to use.
    grep -q '^YH_PUSH_CHANNEL=' "$HOME/.yohuman-v2/config.sh" 2>/dev/null \
      && sed -i '' "s/^YH_PUSH_CHANNEL=.*/YH_PUSH_CHANNEL=\"$code\"/" "$HOME/.yohuman-v2/config.sh" \
      || echo "YH_PUSH_CHANNEL=\"$code\"" >> "$HOME/.yohuman-v2/config.sh"
    echo "paired → $code (this device now reaches the Yo Human app on that code)"
    ;;
  *) echo "usage: yohuman [code [dir] | up | down | status | pair <code>]" >&2; exit 1 ;;
esac
YH__ENGINE__EOF
cat > "$BIN/yohuman-code.sh" <<'YH__ENGINE__EOF'
#!/usr/bin/env bash
# yohuman-code — run Claude Code "almost normally" but inside a screen session the
# Yo Human watcher can type into. The screen layer is invisible to the user.
#
#   yohuman-code [workdir]        start (if needed) AND attach — the human-facing path
#   yohuman-code start [workdir]  start detached only (used by the engine / tests)
#   yohuman-code stop             tear the session down
#   yohuman-code status           is it running?
#
# Isolation: logs to ~/.yohuman-v2/log/screenlog.0; default workdir is the V2 sandbox.
set -euo pipefail
. "$HOME/.yohuman-v2/config.sh" 2>/dev/null

SESS="${YH_V2_SCREEN:-yh-v2}"
LOGDIR="${YH_V2_LOG:-$HOME/.yohuman-v2/log}"

_alive() { screen -ls 2>/dev/null | grep -q "[.]$SESS[[:space:]]"; }

_start() {
  local workdir="${1:-${YH_V2_WORKDIR:-$HOME/.yohuman-v2/yohuman-v2-filewatcher-sandbox}}"
  mkdir -p "$workdir" "$LOGDIR"
  if _alive; then echo "yohuman-code: session '$SESS' already running"; return 0; fi
  : > "$LOGDIR/screenlog.0"
  # screen 4.00.03 writes screenlog.0 to its OWN cwd, so launch from LOGDIR.
  ( cd "$LOGDIR" && screen -L -dmS "$SESS" bash -lc "cd '$workdir' && exec claude" )
  sleep 1
  # screen's default log flush is 10s — far too slow for the watcher's verify step.
  # Flush every 1s so log-based verification is timely.
  screen -S "$SESS" -p 0 -X logfile flush 1 2>/dev/null || true
  sleep 2
  echo "yohuman-code: started '$SESS' (claude in $workdir), log $LOGDIR/screenlog.0"
  # Birth the session's thread on the phone immediately (don't wait for the first
  # completion buzz). Skipped during test batches so test runs never buzz the phone.
  if [ ! -f "$HOME/.yohuman-v2/test-mode" ]; then
    HERE_NOTIFY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/yohuman-notify.sh"
    printf '{"cwd":"%s"}' "$workdir" | bash "$HERE_NOTIFY" start >/dev/null 2>&1 || true
  fi
}

case "${1:-attach}" in
  start)  shift; _start "${1:-}";;
  stop)   screen -S "$SESS" -X quit 2>/dev/null && echo "stopped '$SESS'" || echo "no '$SESS'";;
  status) _alive && echo "running" || echo "stopped";;
  attach) _start ""; echo "attaching… (Ctrl-A then D to detach)"; exec screen -r "$SESS";;
  *)      _start "$1"; echo "attaching… (Ctrl-A then D to detach)"; exec screen -r "$SESS";;
esac
YH__ENGINE__EOF
cat > "$BIN/yohuman-engine.sh" <<'YH__ENGINE__EOF'
#!/usr/bin/env bash
# yohuman-engine — supervisor. Brings up the screened Claude + the watcher loop + the
# watchdog canary together, and tears them all down. This is the always-on engine for a
# real (non-test) session; for test batches use yohuman-testrun.sh instead.
#
#   yohuman-engine.sh up        # start screened Claude + watcher + watchdog (daemons)
#   yohuman-engine.sh down      # stop everything
#   yohuman-engine.sh status    # what's running
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

RUN="${YH_V2_HOME:-$HOME/.yohuman-v2}/run"
mkdir -p "$RUN"
W_PID="$RUN/watcher.pid"; D_PID="$RUN/watchdog.pid"; P_PID="$RUN/replypoll.pid"

_running() { local f="$1"; [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; }

start_daemon() {  # start_daemon <pidfile> <logfile> <cmd...>
  local pid="$1" logf="$2"; shift 2
  if _running "$pid"; then echo "already running (pid $(cat "$pid"))"; return 0; fi
  # Also skip if launchd (or anything else) already runs this daemon — no duplicates.
  if pgrep -f "$(basename "$2") watch" >/dev/null 2>&1; then echo "already running (external)"; return 0; fi
  nohup "$@" >>"$logf" 2>&1 &
  echo $! > "$pid"
}

case "${1:-status}" in
  daemons)
    # Bring up ONLY the background daemons (watcher + reply poller) — no screened claude.
    # Used by the `yohuman code` launcher, which attaches the user's own live session.
    start_daemon "$W_PID" "${YH_V2_LOG}/watcher.log"   bash "$HERE/yohuman-watcher.sh" watch
    start_daemon "$P_PID" "${YH_V2_LOG}/replypoll.log" bash "$HERE/yohuman-replypoll.sh" watch
    echo "engine daemons up — watcher=$(cat "$W_PID" 2>/dev/null) replypoll=$(cat "$P_PID" 2>/dev/null)"
    ;;
  up)
    bash "$HERE/yohuman-code.sh" start >/dev/null
    start_daemon "$W_PID" "${YH_V2_LOG}/watcher.log"   bash "$HERE/yohuman-watcher.sh" watch
    start_daemon "$D_PID" "${YH_V2_LOG}/watchdog.log"  bash "$HERE/yohuman-watchdog.sh" watch 300
    start_daemon "$P_PID" "${YH_V2_LOG}/replypoll.log" bash "$HERE/yohuman-replypoll.sh" watch
    echo "engine up — claude=$(bash "$HERE/yohuman-code.sh" status) watcher=$(cat "$W_PID") watchdog=$(cat "$D_PID") replypoll=$(cat "$P_PID")"
    ;;
  down)
    for f in "$W_PID" "$D_PID" "$P_PID"; do
      _running "$f" && kill "$(cat "$f")" 2>/dev/null && echo "stopped $(basename "$f" .pid) ($(cat "$f"))"
      rm -f "$f"
    done
    bash "$HERE/yohuman-code.sh" stop >/dev/null && echo "stopped screened claude"
    ;;
  status)
    echo "screened claude: $(bash "$HERE/yohuman-code.sh" status)"
    _running "$W_PID" && echo "watcher:   running ($(cat "$W_PID"))" || echo "watcher:   stopped"
    _running "$D_PID" && echo "watchdog:  running ($(cat "$D_PID"))" || echo "watchdog:  stopped"
    _running "$P_PID" && echo "replypoll: running ($(cat "$P_PID"))" || echo "replypoll: stopped"
    ;;
  *) echo "usage: yohuman-engine.sh up|down|status" >&2; exit 1;;
esac
YH__ENGINE__EOF
cat > "$BIN/yohuman-watcher.sh" <<'YH__ENGINE__EOF'
#!/usr/bin/env bash
# yohuman-watcher — the engine. Watches the V2 inbox for phone replies and types
# them into the screen'd Claude session, navigating menus by ROW COUNT (from the
# hook's captured option list) and verifying every injection landed.
#
#   yohuman-watcher watch   # loop forever (the real engine)
#   yohuman-watcher once    # process exactly one queued reply, then exit (tests)
#
# Reads replies from $YH_V2_INBOX, layout from $YH_V2_SPOOL/current.json.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

INBOX="${YH_V2_INBOX:-$HOME/.yohuman-v2/inbox}"
SPOOL="${YH_V2_SPOOL:-$HOME/.yohuman-v2/spool}"
LOGF="${YH_V2_LOG:-$HOME/.yohuman-v2/log}/watcher.log"
mkdir -p "$INBOX" "$SPOOL" "$(dirname "$LOGF")"

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOGF"; }

process_one() {
  local f="$1"
  local kind value ts
  kind="$(jq -r '.kind' "$f" 2>/dev/null)"
  value="$(jq -r '.value' "$f" 2>/dev/null)"
  ts="$(jq -r '.ts' "$f" 2>/dev/null)"
  log "reply $ts: kind=$kind value=$(printf '%s' "$value" | cut -c1-60)"

  if ! yh_session_alive; then
    if [ "$kind" = "newtask" ]; then
      # No session running? A phone-initiated task SPAWNS one (no Terminal needed):
      # the user taps ✏️ on the phone and work starts in the default workspace.
      local ws="$HOME/YoHuman/workspace"; mkdir -p "$ws"
      log "no session — auto-starting one in $ws for the phone task"
      bash "$HERE/yohuman-code.sh" start "$ws" >/dev/null 2>&1
      sleep 2; yh_enter; sleep 3     # clear the first-run trust prompt if shown
      yh_session_alive || { log "ABORT: could not auto-start a session"; return 1; }
    else
      log "ABORT: screen session '$SESS' not running — leaving reply queued"
      return 1
    fi
  fi
  # NOTE: we do NOT run a type-probe here — a text probe doesn't echo when a question
  # MENU is open (focus is on selection, not a text field), so it would false-fail.
  # Per-injection correctness is verified below via pane-advance; the standalone
  # idle-time canary lives in yohuman-watchdog.sh.

  local before after
  before="$(yh_log_bytes)"

  case "$kind" in
    newtask)
      yh_clear_input; sleep 0.3
      yh_type_submit "$value"
      log "injected new task"
      ;;
    other)
      local other_row
      other_row="$(jq -r '.other_row // 3' "$SPOOL/current.json" 2>/dev/null)"
      yh_wait_menu 10 || log "WARN: menu not detected before navigating"
      log "answering via Other (row $other_row)"
      yh_answer_other "$other_row" "$value"
      ;;
    choice)
      local n
      n="$(jq -r '(.options|length) // 0' "$SPOOL/current.json" 2>/dev/null)"
      yh_wait_menu 10 || log "WARN: menu not detected before navigating"
      log "picking choice $value of $n"
      yh_pick_choice "$value" "$n"
      ;;
    allow)
      # Permission prompt: "1. Yes" is highlighted by default — Enter selects it.
      yh_wait_menu 12 || log "WARN: permission menu not detected before approving"
      log "approving (allow) via keystroke"
      yh_enter
      ;;
    reject)
      # Permission prompt: Esc = "cancel" = deny the tool.
      yh_wait_menu 12 || log "WARN: permission menu not detected before rejecting"
      log "rejecting via keystroke (Esc)"
      yh_esc
      ;;
    *) log "unknown kind '$kind' — skipping"; return 1;;
  esac

  sleep "$VERIFY"
  after="$(yh_log_bytes)"
  # Verify: the pane changed after our injection (the TUI redrew = it accepted input).
  if [ "${after:-0}" -gt "${before:-0}" ]; then
    log "OK: pane advanced ($before → $after bytes) — injection accepted"
  else
    log "WARN: pane did not change — injection may not have registered"
  fi

  # mark spool consumed, archive the reply
  if [ -f "$SPOOL/current.json" ]; then
    jq '.status="done"' "$SPOOL/current.json" > "$SPOOL/current.json.tmp" 2>/dev/null \
      && mv "$SPOOL/current.json.tmp" "$SPOOL/current.json"
  fi
  mv "$f" "$f.done" 2>/dev/null || rm -f "$f"
  return 0
}

next_reply() { ls -1tr "$INBOX"/*.json 2>/dev/null | head -1; }

case "${1:-watch}" in
  once)
    f="$(next_reply)"; [ -z "$f" ] && { log "no queued reply"; exit 0; }
    process_one "$f"
    ;;
  watch)
    log "watcher up — inbox=$INBOX session=$SESS"
    while true; do
      f="$(next_reply)"
      [ -n "$f" ] && process_one "$f"
      sleep 1
    done
    ;;
  *) echo "usage: yohuman-watcher watch|once" >&2; exit 1;;
esac
YH__ENGINE__EOF
cat > "$BIN/yohuman-replypoll.sh" <<'YH__ENGINE__EOF'
#!/usr/bin/env bash
# yohuman-replypoll — the phone→Mac bridge. Polls the get_reply RPC for typed/spoken replies
# the app posted, and drops each into the engine inbox (yohuman-watcher then types it into the
# agent). This is the production transport (additive Supabase — migration 0005_replies.sql).
#
#   yohuman-replypoll.sh watch       # loop (the daemon)
#   yohuman-replypoll.sh once        # one poll, then exit (tests)
#   yohuman-replypoll.sh selftest    # post a reply via post_reply, confirm it round-trips
#
# Channel comes from config (YH_PUSH_CHANNEL = yohuman-v2-test in V2). Never the real channel.
set -uo pipefail
. "$HOME/.yohuman-v2/config.sh" 2>/dev/null
INBOX="${YH_V2_INBOX:-$HOME/.yohuman-v2/inbox}"
LOGF="${YH_V2_LOG:-$HOME/.yohuman-v2/log}/replypoll.log"
mkdir -p "$INBOX" "$(dirname "$LOGF")"

CH="${YH_PUSH_CHANNEL:-yohuman-v2-test}"
KEY="${YH_PUSH_KEY:-sb_publishable_hdgb0arXA-MlSIdTn-aRfQ_vL_XG-g1}"
RPC="${YH_PUSH_URL%/functions/v1/push}/rest/v1/rpc"

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOGF"; }

# Claim one reply from the channel; write it to the inbox in the watcher's format.
poll_once() {
  local resp; resp="$(curl -s -X POST "$RPC/get_reply" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"p_channel\":\"$CH\"}" 2>/dev/null)"
  # null / empty => nothing waiting
  [ -z "$resp" ] && return 1
  [ "$resp" = "null" ] && return 1
  local kind body; kind="$(printf '%s' "$resp" | jq -r '.kind // empty' 2>/dev/null)"
  body="$(printf '%s' "$resp" | jq -r '.body // empty' 2>/dev/null)"
  [ -z "$kind" ] && return 1
  local ts; ts="$(date +%s)-$RANDOM"
  jq -n --arg ts "$ts" --arg k "$kind" --arg v "$body" '{ts:$ts,kind:$k,value:$v}' > "$INBOX/$ts.json"
  log "reply received → inbox: kind=$kind value=$(printf '%s' "$body" | cut -c1-50)"
  return 0
}

case "${1:-watch}" in
  once)  poll_once && echo "delivered one reply" || echo "no reply waiting";;
  watch)
    log "replypoll up — channel=$CH inbox=$INBOX"
    while true; do poll_once || true; sleep 2; done
    ;;
  selftest)
    # Requires migration 0005 applied. Posts a reply, then confirms get_reply returns it.
    log "selftest: posting a reply via post_reply…"
    curl -s -X POST "$RPC/post_reply" -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
      -H "Content-Type: application/json" \
      -d "{\"p_channel\":\"$CH\",\"p_request_id\":\"\",\"p_kind\":\"newtask\",\"p_body\":\"SELFTEST_$RANDOM\"}" >/dev/null
    sleep 1
    if poll_once; then echo "SELFTEST PASS — reply round-tripped through Supabase"; else
      echo "SELFTEST FAIL — is migration 0005_replies.sql applied?"; exit 1; fi
    ;;
  *) echo "usage: yohuman-replypoll.sh watch|once|selftest" >&2; exit 1;;
esac
YH__ENGINE__EOF
cat > "$BIN/yohuman-notify.sh" <<'YH__ENGINE__EOF'
#!/usr/bin/env bash
# yohuman-notify.sh <event> — Stop/Notification hook for a `yohuman code` session.
# Pushes a one-line card to the user's phone when their Claude Code session finishes or is
# waiting. Uses the agent's own self-summary (📱[[…]]) when present, else a generic line.
# Self-contained: no ntfy, no dependence on the live ~/.yohuman/ setup. Respects mute.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh" 2>/dev/null

[ -f "$HOME/.yohuman-v2/mute" ] && exit 0
EVENT="${1:-stop}"
INPUT="$(cat 2>/dev/null)"
CH="${YH_PUSH_CHANNEL:-}"
# ISOLATION: during a test batch, force the test channel no matter what the config
# says — a test must never be able to buzz the real phone.
[ -f "$HOME/.yohuman-v2/test-mode" ] && CH="yohuman-v2-test"
[ -z "$CH" ] && exit 0                       # not paired yet → nothing to do
URL="${YH_PUSH_URL:-https://ahfdcubxjcahonmzdoww.supabase.co/functions/v1/push}"
KEY="${YH_PUSH_KEY:-sb_publishable_hdgb0arXA-MlSIdTn-aRfQ_vL_XG-g1}"

PROJ="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null | xargs basename 2>/dev/null)"
[ -z "$PROJ" ] && PROJ="your project"

# Prefer the agent's own one-line card scraped from the screen log; fall back to a generic line.
SUMMARY="$(yh_extract_card 2>/dev/null)"
# Title MUST be "<Event> in <project>" — the app names the session thread by parsing
# the title after "in " (the push fn doesn't forward a project field).
case "$EVENT" in
  stop)  TITLE="Finished in $PROJ"; BODY="${SUMMARY:-Claude finished — ready for your next task}";;
  idle)  TITLE="Waiting in $PROJ";  BODY="${SUMMARY:-Claude needs your answer}";;
  error) TITLE="Error in $PROJ";    BODY="${SUMMARY:-Claude hit an error — needs you}";;
  start) TITLE="Started in $PROJ";  BODY="${SUMMARY:-Session started — ready for your tasks}";;
  *)     TITLE="Yo Human in $PROJ"; BODY="${SUMMARY:-Claude needs you}";;
esac

jq -n --arg c "$CH" --arg t "$TITLE" --arg b "$BODY" --arg s "code" \
  '{channel:$c,title:$t,body:$b,category:"INFO",source:$s}' \
  | curl -s --max-time 12 -X POST "$URL" -H "Authorization: Bearer $KEY" -H "apikey: $KEY" \
      -H "Content-Type: application/json" -d @- >/dev/null 2>&1 || true
exit 0
YH__ENGINE__EOF
chmod +x "$BIN/yohuman" "$BIN"/*.sh
echo "✓ engine installed → $BIN"
CFG="$HD/config.sh"
{
  echo 'YH_PUSH_URL="https://ahfdcubxjcahonmzdoww.supabase.co/functions/v1/push"'
  echo 'YH_PUSH_KEY="sb_publishable_hdgb0arXA-MlSIdTn-aRfQ_vL_XG-g1"'
  echo "YH_PUSH_CHANNEL=\"$CODE\""
  echo 'YH_V2_HOME="$HOME/.yohuman-v2"'
  echo 'YH_V2_SPOOL="$YH_V2_HOME/spool"'
  echo 'YH_V2_INBOX="$YH_V2_HOME/inbox"'
  echo 'YH_V2_LOG="$YH_V2_HOME/log"'
  echo 'YH_V2_SCREEN="yh"'
  echo 'YH_V2_WORKDIR="$PWD"'
} > "$CFG"
[ -n "$CODE" ] && echo "✓ paired to channel: $CODE" || echo "! run: yohuman pair <code>  (get it from the app)"
if [ -w /usr/local/bin ]; then ln -sf "$BIN/yohuman" /usr/local/bin/yohuman; echo "✓ yohuman on PATH (/usr/local/bin)";
else mkdir -p "$HOME/.local/bin"; ln -sf "$BIN/yohuman" "$HOME/.local/bin/yohuman";
     echo "✓ yohuman → ~/.local/bin  (if 'yohuman' isn't found, run: export PATH=\$HOME/.local/bin:\$PATH)"; fi
S="$HOME/.claude/settings.json"; mkdir -p "$HOME/.claude"; [ -f "$S" ] || echo '{}' > "$S"
# Clean up first-generation Yo Human leftovers (retired ntfy-era hooks) — only entries
# that reference ntfy are removed; nothing else is touched.
jq '(.hooks // {}) |= with_entries(.value |= map(select((.hooks[0].command // "") | test("ntfy") | not)))' \
  "$S" > "$S.tmp" 2>/dev/null && mv "$S.tmp" "$S" || true
add_hook() { local ev="$1" arg="$2"; local cmd="bash $BIN/yohuman-notify.sh $arg"
  jq --arg ev "$ev" --arg cmd "$cmd" '.hooks[$ev] = (((.hooks[$ev] // []) | map(select((.hooks[0].command // "") | contains("yohuman-notify.sh") | not))) + [{hooks:[{type:"command",command:$cmd}]}])' "$S" > "$S.tmp" && mv "$S.tmp" "$S"; }
add_hook Stop stop; add_hook Notification idle
echo "✓ notify hooks registered (and any old ntfy leftovers cleaned)"

# Always-on engine: LaunchAgents keep the watcher + reply poller running from login,
# restarting on crash — the user never starts anything by hand.
LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA"
make_agent() { local label="$1" script="$2"
  cat > "$LA/$label.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$BIN/$script</string><string>watch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HD/log/$script.launchd.log</string>
  <key>StandardErrorPath</key><string>$HD/log/$script.launchd.log</string>
</dict></plist>
PL
  if [ -z "${YH_SKIP_LAUNCHD:-}" ]; then
    launchctl unload "$LA/$label.plist" 2>/dev/null || true
    launchctl load "$LA/$label.plist" 2>/dev/null || true
  fi
}
make_agent ai.yohuman.watcher yohuman-watcher.sh
make_agent ai.yohuman.replypoll yohuman-replypoll.sh
echo "✓ engine running (starts automatically at login from now on)"
echo ""
echo "✅ Done. Yo Human is live on this Mac."
echo "   • Start a task from your PHONE anytime (tap the ✏️ in the app) — no Terminal needed."
echo "   • Or, if you use Claude Code directly, launch it with:  yohuman code"
