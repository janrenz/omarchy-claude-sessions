#!/bin/sh
# Claude Code status line: which subscription account this session runs as,
# with its plan and limits, from `omarchy agent account`.
#
# Claude reads its login from CLAUDE_CONFIG_DIR, which `omarchy agent account`
# points at an added account's home and leaves unset for the primary one, and
# the status line command inherits it from the session.
#
# Orca had the status line before; its script only forwards the payload to
# Orca and prints nothing, so it still gets every payload, first.

set -u

payload="$(cat)"

orca="$HOME/.orca/agent-hooks/claude-statusline.sh"
if [ -f "$orca" ] && [ -r "$orca" ]; then
  printf '%s' "$payload" | /bin/sh "$orca" >/dev/null 2>&1 || :
fi

home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
home="${home%/}"

# Limits come from the last collected usage record rather than this payload,
# so every account reads the same way the bar widget shows it.
omarchy agent account list claude --json 2>/dev/null | jq -r --arg home "$home" '
  def pct: (. * 100 | round | tostring) + "%";
  def short: if test("^Session") then "5h" elif test("^Weekly") then "Woche" else . end;
  .[0] as $p
  | ($p.accounts | map(select((.home | sub("/+$"; "")) == $home)) | first) as $a
  | if $a == null then "Konto unbekannt"
    else
      ($a.limits | map(select(.title == null))
        | map((if .percent >= 0.9 then "\u001b[31m" else "" end)
              + (.label | short) + " " + (.percent | pct)
              + (if .percent >= 0.9 then "\u001b[0m\u001b[2m" else "" end))) as $limits
      | "\u001b[1m\($a.label)\u001b[0m"
        + "\u001b[2m"
        + ([$a.plan, ($a.email // "")] + $limits | map(select(. != "")) | map(" · " + .) | join(""))
        + "\u001b[0m"
    end
' 2>/dev/null || printf 'Konto: %s\n' "$home"
