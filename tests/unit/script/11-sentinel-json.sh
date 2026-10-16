#!/bin/bash
set -eu

workdir=$(mktemp -d "${TMPDIR:-/tmp}/pgcopydb-sentinel-json.XXXXXX")
pgcopydb list schema --dir "$workdir" > /dev/null
pgcopydb stream sentinel setup --dir "$workdir" 0/10 0/20

json=$(pgcopydb stream sentinel get --dir "$workdir" --json)
# JSON may escape the slash in an LSN. Compare the reported value, not spelling.
endpos=$(printf '%s\n' "$json" | tr -d '\\' | sed -n 's/.*"endpos": "\([^"]*\)".*/\1/p')
test "$endpos" = "0/20"
test "$(pgcopydb stream sentinel get --dir "$workdir" --endpos)" = "$endpos"
echo 'sentinel JSON endpos: PASSED'
