# shellcheck shell=bash
# Shared by the BrewberryPi CLIs (ADR-0002): logging, atomic writes, the
# global options --yes and --json, and the confirmation protocol with the brew
# warning. The CLIs are the only implementation of every operator command; the
# device web interface runs them, so prompts and warnings come from here.
#
# Before sourcing, set PROG (the command's name) and APP_CONFIG (the app's
# config.json, for the brew warning).

# Exit code of an action that needs confirmation and got neither --yes nor a
# terminal to ask on. The web interface shows the prompt and runs it again
# with --yes.
NEED_CONFIRM=10

log() { echo "$PROG: $*" >&2; }
die() { log "$*"; exit 1; }

# Atomic write of a small file on /data: temp file, fsync, rename, fsync dir.
write_atomic() { # <path>  (content on stdin)
   local tmp=$1.tmp
   cat > "$tmp"
   sync "$tmp"
   mv "$tmp" "$1"
   sync "$(dirname "$1")"
}

# Global options, anywhere on the command line: --yes (confirmed) and --json
# (machine-readable output). Sets YES, JSON and ARGS (the other arguments):
#   parse_opts "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
parse_opts() {
   YES=0 JSON=0 ARGS=()
   local a
   for a in "$@"; do
      case $a in
         --yes) YES=1 ;;
         --json) JSON=1 ;;
         *) ARGS+=("$a") ;;
      esac
   done
}

# The app's engine state from its /healthz (runtime contract §5), or nothing
# when the app doesn't answer. NoProcess means no brew is loaded.
engine_state() {
   local port
   port=$(jq -r '.server.port // 8080' "$APP_CONFIG" 2> /dev/null || echo 8080)
   [[ $port =~ ^[0-9]+$ ]] || port=8080
   curl -fsS -m 2 "http://127.0.0.1:$port/healthz" 2> /dev/null | jq -r '.engine // empty' 2> /dev/null || true
}

# confirm <what the action does>: the same protocol for every action that
# restarts the app or reboots. A loaded or running brew is a warning, never a
# refusal (ADR-0002). With --yes: go ahead. On a terminal: ask for 'yes'.
# Otherwise: print the prompt ({"confirm": ...} with --json) and exit
# NEED_CONFIRM without changing anything.
confirm() {
   local prompt=$1 engine answer
   engine=$(engine_state)
   if [ -n "$engine" ] && [ "$engine" != NoProcess ]; then
      prompt="A brew is loaded or running (engine: $engine). This ends it. $prompt"
   fi
   if [ "$YES" = 1 ]; then
      log "$prompt"
      return 0
   fi
   if [ -t 0 ]; then
      echo "$prompt" >&2
      echo "Type 'yes' to continue:" >&2
      read -r answer || answer=""
      [ "$answer" = yes ] || die "cancelled"
      return 0
   fi
   if [ "$JSON" = 1 ]; then
      jq -n --arg c "$prompt" '{confirm: $c}'
   else
      echo "$prompt" >&2
   fi
   log "confirmation needed: run it again with --yes"
   exit "$NEED_CONFIRM"
}
