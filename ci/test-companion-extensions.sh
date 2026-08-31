#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 /path/to/pg_config /path/to/pg-cryptocurrency /path/to/pg-ledger" >&2
    exit 2
fi

pg_config="$1"
crypto_repo="$2"
ledger_repo="$3"
pg_bindir="$("$pg_config" --bindir)"
pg_major="$("$pg_config" --version | sed -n 's/.* \([0-9][0-9]*\).*/\1/p')"
test_port="$((57000 + pg_major))"
test_root="$(mktemp -d "/tmp/pg-fx-companions-pg${pg_major}.XXXXXX")"

cleanup() {
    "$pg_bindir/pg_ctl" -D "$test_root/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$test_root"
}
trap cleanup EXIT

cargo pgrx install --pg-config "$pg_config"
(cd "$crypto_repo" && cargo pgrx install --pg-config "$pg_config")
(cd "$ledger_repo" && cargo pgrx install --pg-config "$pg_config")

"$pg_bindir/initdb" -D "$test_root/data" --no-locale --encoding=UTF8 >/dev/null
"$pg_bindir/pg_ctl" -D "$test_root/data" -o "-F -p $test_port -k $test_root" -w start >/dev/null

for database in crypto_first fx_first ledger_interop full_stack; do
    "$pg_bindir/createdb" -h "$test_root" -p "$test_port" "$database"
done

money_control="$("$pg_config" --sharedir)/extension/pg_money.control"
if [[ -f "$money_control" ]]; then
    "$pg_bindir/createdb" -h "$test_root" -p "$test_port" money_first
    "$pg_bindir/createdb" -h "$test_root" -p "$test_port" fx_money_late
fi

"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -v crypto_first=true \
    -h "$test_root" -p "$test_port" -d crypto_first \
    -f "$(dirname "$0")/pg-cryptocurrency-interop.sql"
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -v crypto_first=false \
    -h "$test_root" -p "$test_port" -d fx_first \
    -f "$(dirname "$0")/pg-cryptocurrency-interop.sql"
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 \
    -h "$test_root" -p "$test_port" -d ledger_interop \
    -f "$(dirname "$0")/pg-ledger-interop.sql"
"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 \
    -h "$test_root" -p "$test_port" -d full_stack \
    -f "$(dirname "$0")/full-stack-interop.sql"

if [[ -f "$money_control" ]]; then
    "$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -v companions_first=true \
        -h "$test_root" -p "$test_port" -d money_first \
        -f "$(dirname "$0")/pg-money-interop.sql"
    "$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -v companions_first=false \
        -h "$test_root" -p "$test_port" -d fx_money_late \
        -f "$(dirname "$0")/pg-money-interop.sql"
fi
