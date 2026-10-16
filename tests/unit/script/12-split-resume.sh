#!/bin/bash
set -eu

workdir=$(mktemp -d "${TMPDIR:-/tmp}/pgcopydb-split-resume.XXXXXX")
dbname="split_resume_$$"
psql -X -v ON_ERROR_STOP=1 -d "$PGCOPYDB_SOURCE_PGURI" -qc "CREATE DATABASE $dbname"
psql -X -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" -qc "CREATE DATABASE $dbname"
export PGCOPYDB_SOURCE_PGURI="${PGCOPYDB_SOURCE_PGURI%/*}/$dbname"
export PGCOPYDB_TARGET_PGURI="${PGCOPYDB_TARGET_PGURI%/*}/$dbname"

psql -X -v ON_ERROR_STOP=1 -d "$PGCOPYDB_SOURCE_PGURI" -q <<'SQL'
CREATE TABLE t(id integer PRIMARY KEY, note text);
INSERT INTO t SELECT g, 'row-'||g FROM generate_series(1,24) g;
ANALYZE t;
SQL
psql -X -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" -q <<'SQL'
CREATE TABLE t(id integer PRIMARY KEY, note text);
CREATE FUNCTION interrupt_copy() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.id > 12 THEN
        RAISE EXCEPTION 'interrupt the later COPY part';
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER interrupt_copy BEFORE INSERT ON t
    FOR EACH ROW EXECUTE FUNCTION interrupt_copy();
SQL

copy_parts() {
    pgcopydb copy table-data --dir "$workdir" --not-consistent \
        --split-tables-larger-than '1 B' --split-max-parts 3 \
        --table-jobs 1 --fail-fast "$@"
}

if copy_parts > "$workdir/first.log" 2>&1; then
    echo 'Expected the later COPY part to fail' >&2
    exit 1
fi
rows=$(psql -X -At -d "$PGCOPYDB_TARGET_PGURI" -c 'SELECT count(*) FROM t')
test "$rows" -gt 0
test "$rows" -lt 24
psql -X -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" -qc 'DROP TRIGGER interrupt_copy ON t'
copy_parts --resume > "$workdir/resume.log" 2>&1
rows=$(psql -X -At -d "$PGCOPYDB_TARGET_PGURI" -c 'SELECT count(*),sum(id) FROM t')
test "$rows" = '24|300'
copy_parts --resume > "$workdir/completed-resume.log" 2>&1
rows=$(psql -X -At -d "$PGCOPYDB_TARGET_PGURI" -c 'SELECT count(*),sum(id) FROM t')
test "$rows" = '24|300'
echo 'split COPY resume preserves completed parts: PASSED'
