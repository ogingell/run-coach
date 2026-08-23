#!/bin/bash
# Strava API access for the run coach.
#
# Used when the Claude.ai Strava connector isn't reachable — it lives in the
# desktop app and is not available to `claude -p` headless. Whether a cloud
# routine can see it is unverified; this is the fallback either way.
#
# Credentials, in order of precedence:
#   bin/secrets.env                          local Mac (gitignored)
#   STRAVA_CLIENT_ID / _SECRET / _REFRESH_TOKEN   environment (cloud routine)
#
# State: .strava-tokens.json caches the access token and the current refresh
# token. A cloud routine gets a fresh clone every run, so that file won't
# exist — STRAVA_REFRESH_TOKEN seeds it instead. See rotation note below.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

# See tg.sh — `[[ -f x ]] && source x` aborts under `set -e` when absent.
if [[ -f "$DIR/secrets.env" ]]; then
  # shellcheck source=/dev/null
  source "$DIR/secrets.env"
fi

STATE_DIR="${RUN_COACH_STATE_DIR:-$ROOT}"
TOKENS="$STATE_DIR/.strava-tokens.json"
API="https://www.strava.com/api/v3"
REDIRECT="http://localhost/exchange_token"

die() { echo "$*" >&2; exit 1; }

need_client() {
  [[ -n "${STRAVA_CLIENT_ID:-}" && -n "${STRAVA_CLIENT_SECRET:-}" ]] \
    || die "STRAVA_CLIENT_ID / STRAVA_CLIENT_SECRET not set — add to bin/secrets.env or the environment"
}

# Writes the token file atomically with 600 perms. Best-effort: on a read-only
# or ephemeral filesystem this is allowed to fail without killing the run,
# since the access token we just fetched is still good for six hours.
save_tokens() {
  local json="$1" tmp
  tmp="$(mktemp "$STATE_DIR/.strava-tokens.XXXXXX" 2>/dev/null)" || {
    echo "note: could not write token cache to $STATE_DIR (continuing)" >&2
    return 0
  }
  printf '%s\n' "$json" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$TOKENS"
}

# The refresh token currently in play: the cached file if we have one,
# otherwise the environment seed.
current_refresh() {
  if [[ -f "$TOKENS" ]]; then
    jq -r '.refresh_token // empty' "$TOKENS"
  else
    printf '%s' "${STRAVA_REFRESH_TOKEN:-}"
  fi
}

# Echoes a valid access token, refreshing it if it expires within 5 minutes.
access_token() {
  need_client
  if [[ -f "$TOKENS" ]]; then
    local now exp
    now=$(date +%s)
    exp=$(jq -r '.expires_at // 0' "$TOKENS")
    if (( exp - now > 300 )); then
      jq -r '.access_token' "$TOKENS"
      return
    fi
  fi

  local refresh resp new_refresh
  refresh="$(current_refresh)"
  [[ -n "$refresh" ]] \
    || die "no refresh token — run 'strava.sh auth-url' locally, or set STRAVA_REFRESH_TOKEN"

  resp=$(curl -sS --max-time 30 -X POST "https://www.strava.com/oauth/token" \
    -d client_id="$STRAVA_CLIENT_ID" \
    -d client_secret="$STRAVA_CLIENT_SECRET" \
    -d grant_type=refresh_token \
    -d refresh_token="$refresh")
  jq -e '.access_token' >/dev/null 2>&1 <<<"$resp" \
    || die "token refresh failed: $resp"

  # Strava's docs say the refresh token MAY rotate. In a cloud routine the
  # rewritten cache file is thrown away with the clone, so a rotation would
  # silently break tomorrow's run. Shout about it rather than fail quietly.
  new_refresh=$(jq -r '.refresh_token' <<<"$resp")
  if [[ -n "${STRAVA_REFRESH_TOKEN:-}" && "$new_refresh" != "$refresh" ]]; then
    echo "WARNING: Strava rotated the refresh token. Update STRAVA_REFRESH_TOKEN in the routine environment to: $new_refresh" >&2
  fi

  save_tokens "$(jq -c '{access_token, refresh_token, expires_at}' <<<"$resp")"
  jq -r '.access_token' <<<"$resp"
}

api() {  # api <path-with-query>
  local tok; tok=$(access_token)
  curl -sS --max-time 60 -H "Authorization: Bearer $tok" "$API/$1"
}

# Trim Strava's very large activity objects down to what a coach actually reads,
# and pre-compute pace/duration so the model never has to do arithmetic on
# metres-per-second.
TRIM='{
  id, name,
  type: .sport_type,
  start: .start_date_local,
  distance_km: ((.distance / 100 | round) / 10),
  moving: (.moving_time as $s
           | if $s >= 3600
             then "\($s/3600|floor)h\((($s%3600)/60)|floor|tostring|if length<2 then "0"+. else . end)"
             else "\($s/60|floor)m" end),
  moving_time_s: .moving_time,
  pace_per_km: (if (.moving_time > 0 and .distance > 0) and (.sport_type|test("Run|Walk|Hike"))
                then ((.moving_time / (.distance/1000)) as $p
                      | "\($p/60|floor):\(($p%60|floor)|tostring|if length<2 then "0"+. else . end)")
                else null end),
  elev_m: (.total_elevation_gain | round),
  hr_avg: (.average_heartrate // null | if . then round else null end),
  hr_max: (.max_heartrate // null | if . then round else null end),
  cadence: (.average_cadence // null),
  effort: (.suffer_score // null)
}'

case "${1:-}" in
  auth-url)
    need_client
    echo "Open this, approve, then copy the 'code=' value out of the URL you land on:"
    echo
    echo "https://www.strava.com/oauth/authorize?client_id=${STRAVA_CLIENT_ID}&redirect_uri=${REDIRECT}&response_type=code&approval_prompt=force&scope=activity:read_all,profile:read_all"
    echo
    echo "Then run:  strava.sh auth-code <code>"
    ;;

  auth-code)
    need_client
    code="${2:?auth-code requires the code from the redirect URL}"
    resp=$(curl -sS --max-time 30 -X POST "https://www.strava.com/oauth/token" \
      -d client_id="$STRAVA_CLIENT_ID" \
      -d client_secret="$STRAVA_CLIENT_SECRET" \
      -d grant_type=authorization_code \
      -d code="$code")
    jq -e '.access_token' >/dev/null 2>&1 <<<"$resp" \
      || die "code exchange failed: $resp"
    save_tokens "$(jq -c '{access_token, refresh_token, expires_at}' <<<"$resp")"
    echo "authorised as: $(jq -r '.athlete.firstname + " " + .athlete.lastname' <<<"$resp")"
    ;;

  activities)  # activities <days-back>
    days="${2:-35}"
    [[ "$days" =~ ^[0-9]+$ ]] || die "activities requires a number of days"
    after=$(( $(date +%s) - days * 86400 ))
    api "athlete/activities?after=${after}&per_page=200" \
      | jq -c "if type==\"array\" then [ .[] | $TRIM ] else . end"
    ;;

  activity)  # activity <id> — full detail, includes the description
    id="${2:?activity requires an id}"
    [[ "$id" =~ ^[0-9]+$ ]] || die "activity id must be numeric"
    api "activities/${id}" \
      | jq -c "if .id then ($TRIM + {description, laps: [(.laps // [])[] | {
            lap: .lap_index,
            distance_km: ((.distance/100|round)/10),
            moving_time_s: .moving_time,
            pace_per_km: (if .moving_time>0 and .distance>0
                          then ((.moving_time/(.distance/1000)) as \$p
                                | \"\(\$p/60|floor):\((\$p%60|floor)|tostring|if length<2 then \"0\"+. else . end)\")
                          else null end),
            hr_avg: (.average_heartrate // null)
          }]}) else . end"
    ;;

  streams)  # streams <id>
    id="${2:?streams requires an id}"
    [[ "$id" =~ ^[0-9]+$ ]] || die "streams id must be numeric"
    api "activities/${id}/streams?keys=time,distance,heartrate,cadence,velocity_smooth,altitude&key_by_type=true"
    ;;

  athlete)
    api "athlete"
    ;;

  *)
    cat >&2 <<'USAGE'
usage: strava.sh <command>

  auth-url              print the one-time authorisation URL
  auth-code <code>      exchange the code from that URL for tokens
  activities <days>     trimmed activity list for the last N days (default 35)
  activity <id>         one activity in full, including description and laps
  streams <id>          raw time/distance/HR/cadence streams
  athlete               profile sanity check
USAGE
    exit 1
    ;;
esac
