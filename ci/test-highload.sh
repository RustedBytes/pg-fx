#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/pg_config" >&2
    exit 2
fi

pg_config="$1"
pg_bindir="$("$pg_config" --bindir)"
pg_major="$("$pg_config" --version | sed -n 's/.* \([0-9][0-9]*\).*/\1/p')"
test_port="$((57000 + pg_major))"
test_root="$(mktemp -d "/tmp/pg-fx-load-pg${pg_major}.XXXXXX")"
script_root="$(cd "$(dirname "$0")" && pwd)"

history_rows="${FX_LOAD_HISTORY_ROWS:-100000}"
rate_clients="${FX_LOAD_RATE_CLIENTS:-8}"
rate_transactions="${FX_LOAD_RATE_TRANSACTIONS:-250}"
quote_clients="${FX_LOAD_QUOTE_CLIENTS:-16}"
quote_transactions="${FX_LOAD_QUOTE_TRANSACTIONS:-100}"
expiry_clients="${FX_LOAD_EXPIRY_CLIENTS:-8}"
minimum_rate_tps="${FX_LOAD_MIN_RATE_TPS:-50}"
minimum_quote_tps="${FX_LOAD_MIN_QUOTE_TPS:-100}"
expected_rates="$((history_rows + rate_clients * rate_transactions))"
expected_quotes="$((quote_clients * quote_transactions))"
expiry_transactions="$(((expected_quotes + 25 * expiry_clients - 1) / (25 * expiry_clients) + 2))"

cleanup() {
    "$pg_bindir/pg_ctl" -D "$test_root/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$test_root"
}
trap cleanup EXIT

cargo pgrx install --pg-config "$pg_config"
"$pg_bindir/initdb" -D "$test_root/data" --no-locale --encoding=UTF8 >/dev/null
"$pg_bindir/pg_ctl" -D "$test_root/data" \
    -o "-F -p $test_port -k $test_root -c listen_addresses='' -c max_connections=100" \
    -w start >/dev/null
"$pg_bindir/createdb" -h "$test_root" -p "$test_port" pg_fx_load

"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_fx_load -v history_rows="$history_rows" <<'SQL'
CREATE EXTENSION pg_fx;

SELECT count(*)
FROM (
    SELECT fx_source_upsert(
        'load_' || source_no,
        source_no,
        true,
        interval '30 days'
    )
    FROM generate_series(1, 32) source_no
) sources;

INSERT INTO fx_rates(source_id, pair, bid, ask, volume, observed_at, received_at)
SELECT
    s.id,
    'USD/EUR'::fx_pair,
    0.84 + (observation_no % 1000) / 1000000.0,
    0.85 + (observation_no % 1000) / 1000000.0,
    1000,
    clock_timestamp() - observation_no * interval '1 millisecond',
    clock_timestamp()
FROM generate_series(1, :history_rows) observation_no
JOIN fx_sources s ON s.name = 'load_' || (1 + observation_no % 32);

SELECT fx_rule_create('USD/EUR', 'retail');
ANALYZE fx_sources;
ANALYZE fx_rates;
SQL

pgbench_common=(
    -n -M prepared -h "$test_root" -p "$test_port" -U "$(id -un)" pg_fx_load
)

"$pg_bindir/pgbench" "${pgbench_common[@]}" \
    -c "$rate_clients" -j "$rate_clients" -t "$rate_transactions" \
    -f "$script_root/highload/rates.sql" >"$test_root/rates.out" 2>&1 &
rate_pid=$!
"$pg_bindir/pgbench" "${pgbench_common[@]}" \
    -c "$quote_clients" -j "$quote_clients" -t "$quote_transactions" \
    -f "$script_root/highload/quotes.sql" >"$test_root/quotes.out" 2>&1 &
quote_pid=$!

load_failed=0
wait "$rate_pid" || load_failed=1
wait "$quote_pid" || load_failed=1
cat "$test_root/rates.out"
cat "$test_root/quotes.out"
if [[ "$load_failed" -ne 0 ]]; then
    echo "concurrent rate/quote load failed" >&2
    exit 1
fi

rate_tps="$(awk '/^tps = .*without initial connection time/ { print $3 }' "$test_root/rates.out")"
if [[ -z "$rate_tps" ]] || ! awk -v actual="$rate_tps" -v minimum="$minimum_rate_tps" \
    'BEGIN { exit !(actual >= minimum) }'; then
    echo "rate/composite throughput ${rate_tps:-unknown} TPS is below required ${minimum_rate_tps} TPS" >&2
    exit 1
fi

quote_tps="$(awk '/^tps = .*without initial connection time/ { print $3 }' "$test_root/quotes.out")"
if [[ -z "$quote_tps" ]] || ! awk -v actual="$quote_tps" -v minimum="$minimum_quote_tps" \
    'BEGIN { exit !(actual >= minimum) }'; then
    echo "quote throughput ${quote_tps:-unknown} TPS is below required ${minimum_quote_tps} TPS" >&2
    exit 1
fi

"$pg_bindir/pgbench" "${pgbench_common[@]}" \
    -c "$expiry_clients" -j "$expiry_clients" -t "$expiry_transactions" \
    -f "$script_root/highload/expire.sql"

"$pg_bindir/psql" -X -v ON_ERROR_STOP=1 -h "$test_root" -p "$test_port" \
    -d pg_fx_load -v expected_rates="$expected_rates" -v expected_quotes="$expected_quotes" <<'SQL'
CREATE TEMP TABLE load_expectations(expected_rates bigint, expected_quotes bigint);
INSERT INTO load_expectations VALUES (:expected_rates, :expected_quotes);

DO $assertions$
DECLARE
    expected_rate_count bigint;
    expected_quote_count bigint;
BEGIN
    SELECT expected_rates, expected_quotes
    INTO expected_rate_count, expected_quote_count
    FROM load_expectations;

    IF (SELECT count(*) FROM fx_rates) <> expected_rate_count THEN
        RAISE EXCEPTION 'rate count mismatch: expected %, got %',
            expected_rate_count, (SELECT count(*) FROM fx_rates);
    END IF;
    IF (SELECT count(*) FROM fx_quotes) <> expected_quote_count THEN
        RAISE EXCEPTION 'quote count mismatch: expected %, got %',
            expected_quote_count, (SELECT count(*) FROM fx_quotes);
    END IF;
    IF EXISTS (SELECT 1 FROM fx_quotes WHERE status <> 'expired') THEN
        RAISE EXCEPTION 'concurrent expiry left quotes in a non-expired state';
    END IF;
    IF EXISTS (SELECT 1 FROM fx_validate() WHERE NOT valid) THEN
        RAISE EXCEPTION 'fx_validate reported an invariant failure after load';
    END IF;
END
$assertions$;
SQL

echo "high-load test passed: $expected_rates rates, $expected_quotes quotes, ${rate_tps} rate/composite TPS, ${quote_tps} quote TPS"
