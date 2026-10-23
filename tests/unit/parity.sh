#!/bin/bash
# CLI ⇄ web parity (ADR-0002, OS9): every operator command is in the CLIs'
# usage headers, the command catalogue, the device web page and the user
# manual's command reference, and nowhere else. A command added to one of
# them only fails here. Declared exceptions are catalogue entries with
# "webOnly" naming their CLI counterpart (the password change: passwd).
# Run by scripts/lint.sh.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
CATALOGUE=$ROOT_DIR/layer/brewberry-web.rootfs-overlay/usr/share/brewberry/commands.json
PAGE=$ROOT_DIR/layer/brewberry-web.rootfs-overlay/usr/lib/brewberry-web/index.html
MANUAL=$ROOT_DIR/docs/user-manual.md
CLIS="brewberry-update brewberry-config brewberry-system brewberry-maint brewberry-wifi"

failures=0
same() { # <description> <set A> <set B>
   local a b
   a=$(printf '%s\n' "$2" | sed '/^$/d' | sort -u)
   b=$(printf '%s\n' "$3" | sed '/^$/d' | sort -u)
   if [ "$a" = "$b" ]; then
      echo "ok    $1"
   else
      echo "FAIL  $1:"
      { diff <(echo "$a") <(echo "$b") || true; } | sed -n 's/^</        only in the first:  /p; s/^>/        only in the second: /p'
      failures=1
   fi
}

cli_path() { find "$ROOT_DIR"/layer/*.rootfs-overlay/usr/local/sbin -name "$1" -type f | head -n 1; }

# "<cli> <subcommand>" from each CLI's usage header (the comment block at the top).
cli_cmds=""
for cli in $CLIS; do
   f=$(cli_path "$cli")
   [ -n "$f" ] || { echo "FAIL  $cli not found"; failures=1; continue; }
   cli_cmds+=$(sed -n '2,/^set -euo/p' "$f" | grep -oE "^#   $cli [a-z-]+" | sed 's/^#   //')$'\n'
done

cat_cmds=$(jq -r '.commands[] | select(.argv) | "\(.argv[0]) \(.argv[1])"' "$CATALOGUE")
cat_ids=$(jq -r '.commands[].id' "$CATALOGUE")
web_only=$(jq -r '.commands[] | select(.webOnly) | .webOnly' "$CATALOGUE")
page_ids=$(grep -oE 'data-cmd="[a-z.-]+"|dataset\.cmd = "[a-z.-]+"' "$PAGE" | grep -oE '"[a-z.-]+"' | tr -d '"')
# shellcheck disable=SC2016  # literal backticks and awk fields
manual_cmds=$(sed -n '/^## 9\. Command reference/,/^## /p' "$MANUAL" | grep -oE '^\| `[^`]+`' |
   sed -E 's/^\| `//; s/`$//' | awk '{ print ($1 ~ /^brewberry-/ ? $1 " " $2 : $1) }')

same "CLI usage headers ⇄ catalogue" "$cli_cmds" "$cat_cmds"
same "catalogue ⇄ device web page (data-cmd)" "$cat_ids" "$page_ids"
same "catalogue ⇄ user manual's command reference" "$(printf '%s\n%s\n' "$cat_cmds" "$web_only")" "$manual_cmds"
same "catalogue CLIs ⇄ the operator CLIs" "$(jq -r '.commands[] | select(.argv) | .argv[0]' "$CATALOGUE")" "$(tr ' ' '\n' <<< "$CLIS")"

# Every catalogue entry runs something or names its CLI counterpart.
expect_none=$(jq -r '.commands[] | select((.argv | not) and (.webOnly | not)) | .id' "$CATALOGUE")
same "every catalogue entry has argv or webOnly" "$expect_none" ""
# Placeholders have patterns (the helper refuses anything else).
missing=$(jq -r '.commands[] | select(.argv) | . as $c | .argv[] | select(test("^\\{[a-z]+\\}$")) | ltrimstr("{") | rtrimstr("}")
   | select(. != "upload" and ($c.args[.] | not)) | "\($c.id) \(.)"' "$CATALOGUE")
same "every placeholder has an argument pattern" "$missing" ""

exit "$failures"
