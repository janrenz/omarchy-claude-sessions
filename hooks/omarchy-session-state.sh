#!/bin/sh
# Claude Code hook: publishes per-session state for the jan.claude-sessions
# bar widget and sends desktop notifications when a session needs you.
#
#   omarchy-session-state.sh <start|prompt|tool|notify|stop|fail|end|prune>
#   omarchy-session-state.sh focus <window-address>
#
# State lives in ~/.local/state/claude-sessions/: one sessions/<id>.json per
# live session, and index.json (all of them as one array) that the widget
# watches. Hook input arrives as JSON on stdin.

set -u

action="${1:-}"
dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-sessions"
sessions="$dir/sessions"
mkdir -p "$sessions" 2>/dev/null || exit 0

input=""
[ "$action" = "prune" ] || input="$(cat 2>/dev/null || true)"

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

# Rewrites index.json from the per-session files. Written in place rather than
# renamed so the widget's file watch keeps following the same inode; a reader
# that catches it half-written just keeps its previous list.
rebuild_index() {
  tmp="$dir/.index.$$"
  if ls "$sessions"/*.json >/dev/null 2>&1; then
    jq -s 'sort_by(.started)' "$sessions"/*.json >"$tmp" 2>/dev/null || echo '[]' >"$tmp"
  else
    echo '[]' >"$tmp"
  fi
  cat "$tmp" >"$dir/index.json"
  rm -f "$tmp"
}

# Drops sessions whose claude process is gone (crashed or killed, so
# SessionEnd never ran).
prune() {
  for f in "$sessions"/*.json; do
    [ -e "$f" ] || continue
    pid="$(jq -r '.pid // 0' "$f" 2>/dev/null)"
    [ "${pid:-0}" -gt 0 ] 2>/dev/null || continue
    kill -0 "$pid" 2>/dev/null || rm -f "$f"
  done
}

# Brings a session's terminal to the front. One on a special workspace (the
# agent shelf is special:scratchpad) only shows once that workspace is toggled
# open, and one on a regular workspace stays covered while a special workspace
# is open, so toggle as needed; focusing then switches to its workspace.
focus() {
  addr="$1"
  ws="$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.name' 2>/dev/null)"
  [ -n "$ws" ] || return 0
  shown="$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused) | .specialWorkspace.name // empty' 2>/dev/null)"
  case "$ws" in
    special:*) target="$ws"; [ "$shown" = "$ws" ] && target="" ;;
    *) target="$shown" ;;
  esac
  if [ -n "$target" ]; then
    hyprctl dispatch "hl.dsp.workspace.toggle_special(\"${target#special:}\")" >/dev/null 2>&1
  fi
  hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null 2>&1
}

if [ "$action" = "prune" ]; then
  prune
  rebuild_index
  exit 0
fi

if [ "$action" = "focus" ]; then
  case "${2:-}" in 0x*) focus "$2" ;; esac
  exit 0
fi

id="$(field .session_id)"
[ -n "$id" ] || exit 0
case "$id" in */*|*..*) exit 0 ;; esac
file="$sessions/$id.json"

if [ "$action" = "end" ]; then
  rm -f "$file"
  prune
  rebuild_index
  exit 0
fi

current="$(jq -r '.state // empty' "$file" 2>/dev/null)"

# Tool calls are frequent; they only matter when they end a wait for input.
if [ "$action" = "tool" ] && [ -n "$current" ] && [ "$current" != "waiting" ]; then
  exit 0
fi

# The claude process and the terminal window it runs in, found by walking up
# the process tree. Looked up once and kept in the session file.
pid="$(jq -r '.pid // 0' "$file" 2>/dev/null)"
window="$(jq -r '.window // empty' "$file" 2>/dev/null)"
if [ "${pid:-0}" = "0" ] || [ -z "$window" ]; then
  clients="$(hyprctl clients -j 2>/dev/null || echo '[]')"
  p=$PPID
  while [ "${p:-0}" -gt 1 ]; do
    comm="$(cat /proc/"$p"/comm 2>/dev/null)" || break
    [ "${pid:-0}" = "0" ] && [ "$comm" = "claude" ] && pid=$p
    if [ -z "$window" ]; then
      window="$(printf '%s' "$clients" | jq -r --argjson p "$p" 'map(select(.pid == $p)) | .[0].address // empty' 2>/dev/null)"
    fi
    [ -n "$window" ] && break
    p="$(awk '{print $4}' /proc/"$p"/stat 2>/dev/null)"
  done
fi

cwd="$(field .cwd)"
[ -n "$cwd" ] || cwd="$PWD"
project="$(basename "$cwd")"
now="$(date +%s)"
message=""
notify_title=""
notify_body=""
urgency="normal"

case "$action" in
  start)  state="idle" ;;
  prompt) state="working" ;;
  tool)   state="working" ;;
  notify)
    message="$(field .message)"
    case "$(field .notification_type)" in
      idle_prompt) exit 0 ;;
      permission_prompt|elicitation_dialog)
        state="waiting"
        notify_title="Claude needs you · $project"
        notify_body="$message"
        urgency="critical"
        ;;
      *)
        state="${current:-idle}"
        notify_title="Claude · $project"
        notify_body="$message"
        ;;
    esac
    ;;
  stop)
    state="idle"
    message="$(field .last_assistant_message | tr '\n' ' ' | cut -c1-160)"
    notify_title="Claude finished · $project"
    notify_body="$message"
    ;;
  fail)
    state="error"
    message="$(field .error)"
    [ -n "$message" ] || message="The turn ended with an error"
    notify_title="Claude stopped · $project"
    notify_body="$message"
    urgency="critical"
    ;;
  *) exit 0 ;;
esac

started="$(jq -r '.started // empty' "$file" 2>/dev/null)"
[ -n "$started" ] || started="$now"

tmp="$sessions/.$id.$$"
jq -n \
  --arg id "$id" --arg cwd "$cwd" --arg project "$project" --arg state "$state" \
  --arg message "$message" --arg window "$window" \
  --argjson pid "${pid:-0}" --argjson started "$started" --argjson updated "$now" \
  '{id: $id, cwd: $cwd, project: $project, state: $state, message: $message,
    window: $window, pid: $pid, started: $started, updated: $updated}' >"$tmp" \
  && mv -f "$tmp" "$file"
rm -f "$tmp"

prune
rebuild_index

# Notify only when you aren't already looking at this session's terminal.
# Clicking the notification focuses that terminal.
if [ -n "$notify_title" ]; then
  active="$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty' 2>/dev/null)"
  if [ -z "$window" ] || [ "$active" != "$window" ]; then
    (
      choice="$(notify-send -a "Claude Code" -u "$urgency" -A default=Open --wait \
        -- "$notify_title" "${notify_body:- }" 2>/dev/null)"
      if [ "$choice" = "default" ] && [ -n "$window" ]; then
        focus "$window"
      fi
    ) </dev/null >/dev/null 2>&1 &
  fi
fi

exit 0
