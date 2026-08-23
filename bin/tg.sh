#!/bin/bash
# Telegram I/O for the run coach.
#
# Keeps the bot token out of the task prompt and gives permissions a single
# stable command to allow, instead of fragile curl patterns.
#
# Credentials are read from whichever exists:
#   bin/secrets.env      — local Mac (gitignored, never committed)
#   TG_TOKEN / TG_CHAT   — environment variables (cloud routine)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

# Plain `[[ -f x ]] && source x` would abort the script under `set -e` when the
# file is absent, which is the normal case in the cloud. Use an if.
if [[ -f "$DIR/secrets.env" ]]; then
  # shellcheck source=/dev/null
  source "$DIR/secrets.env"
fi

: "${TG_TOKEN:?TG_TOKEN not set — add it to bin/secrets.env or the environment}"
: "${TG_CHAT:?TG_CHAT not set — add it to bin/secrets.env or the environment}"

OFFSET_FILE="${RUN_COACH_STATE_DIR:-$ROOT}/.tg-offset"

case "${1:-}" in
  recv)
    offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
    curl -sS --max-time 20 \
      "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${offset}&timeout=0"
    ;;
  ack)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "ack requires a numeric update_id" >&2; exit 1; }
    echo "$2" > "$OFFSET_FILE"
    ;;
  send)
    msg="${2:?send requires a path to the message file}"
    [[ -f "$msg" ]] || { echo "no such file: $msg" >&2; exit 1; }
    curl -sS --max-time 20 -X POST \
      "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT}" \
      --data-urlencode "parse_mode=HTML" \
      --data-urlencode "text@${msg}"
    ;;
  sendrich)
    # <file> holds an InputRichMessage object (e.g. {"blocks":[...]}).
    # chat_id is injected here so the prompt never touches it.
    msg="${2:?sendrich requires a path to the rich_message JSON file}"
    [[ -f "$msg" ]] || { echo "no such file: $msg" >&2; exit 1; }
    # skip_entity_detection defaults on: bare "/km" in pace text would
    # otherwise be auto-linked as a bot command. The file can override it.
    jq -c --arg chat "$TG_CHAT" \
      '{chat_id: $chat, rich_message: ({skip_entity_detection: true} + .)}' "$msg" \
      | curl -sS --max-time 20 -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendRichMessage" \
        -H "Content-Type: application/json" --data-binary @-
    ;;
  *)
    echo "usage: tg.sh {recv | ack <update_id> | send <file> | sendrich <file>}" >&2
    exit 1
    ;;
esac
