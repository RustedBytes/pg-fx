# pg_fx

`pg_fx` is the PostgreSQL pricing and quote layer between exact asset types and
an immutable ledger. It stores source-attributed bid/ask observations, rejects
stale prices, applies side-aware customer rules and fees, and persists expiring
quotes whose pricing can be audited later.

It performs no HTTP or market-data fetching and never moves balances:

```text
market feeds -> application collector -> pg_fx -> pg_money / pg_cryptocurrency
                                              -> pg_ledger
```

The extension supports PostgreSQL 14–18, Rust 1.96+, and pgrx 0.19.2.

## Build and install

```bash
cargo install cargo-pgrx --version 0.19.2 --locked
cargo pgrx init --pg18=/path/to/pg_config
./install.sh --pg-config /path/to/pg_config
```

Then install the packaged extension:

```sql
CREATE EXTENSION pg_fx;
```

`pg_fx` can be installed into a dedicated schema, but is intentionally
non-relocatable afterward because its functions pin a safe schema-qualified
search path:

```sql
CREATE SCHEMA pricing;
CREATE EXTENSION pg_fx SCHEMA pricing;
```

## Quick start

Register an application-fed source and add a bid/ask observation:

```sql
SELECT fx_source_upsert('primary_bank', source_priority => 10,
                        source_max_age => interval '30 seconds');

SELECT fx_rate_insert(
    source             => 'primary_bank',
    rate_pair          => 'USD/EUR',
    rate_bid           => 0.8510,
    rate_ask           => 0.8520,
    rate_observed_at   => clock_timestamp()
);

SELECT fx_bid('USD/EUR'), fx_ask('USD/EUR'), fx_mid('USD/EUR');
```

Add a retail rule and create a first-class quote:

```sql
SELECT fx_rule_create(
    rule_pair => 'USD/EUR',
    segment   => 'retail',
    minimum   => 0,
    maximum   => 10000,
    markup    => 50,  -- basis points
    fixed     => 5    -- charged in the input asset
);

SELECT * FROM fx_create_quote(
    rate_pair       => 'USD/EUR',
    quote_side      => 'sell_base',
    amount          => 1000,
    customer_segment => 'retail',
    customer_id     => 'customer-123'
);
```

The quote records market rate, customer rate, input fee, output amount, spread,
source observation, rule, creation time, and expiry. Only the state may make a
one-way transition from `open` to `executed`, `expired`, or `cancelled`.

## pg_ledger handoff

`pg_fx` deliberately does not call `ledger_post`. Build the balanced
`pg_ledger` transaction in the application transaction and attach the quote's
canonical audit payload:

```sql
SELECT ledger_post(
    ARRAY[
        ledger_posting(customer_usd,  '-1000 USD'),
        ledger_posting(liquidity_usd,   '995 USD'),
        ledger_posting(fee_income_usd,    '5 USD'),
        ledger_posting(liquidity_eur, '-842.51 EUR'),
        ledger_posting(customer_eur,   '842.51 EUR')
    ],
    reference       => 'fx:' || quote_id,
    idempotency_key => 'fx:' || quote_id,
    metadata        => fx_quote_ledger_metadata(quote_id)
);

SELECT fx_execute_quote(quote_id);
```

Use one PostgreSQL transaction for the ledger posting and quote transition.
`fx_execute_quote` marks the pricing decision as used; it does not move assets.

## Optional amount interoperability

There is no hard dependency on `pg_money` or `pg_cryptocurrency`. When either
is already installed, `pg_fx` adds an `fx_convert` overload for its exact amount
type. If it is installed later, enable the adapter explicitly:

```sql
SELECT fx_enable_pg_money();
SELECT fx_enable_pg_cryptocurrency();
```

The generic numeric conversion API always requires an explicit pair, side,
rate, output scale, and rounding policy.

See [the SQL API](docs/API.md), [architecture](docs/ARCHITECTURE.md), and
[security model](docs/SECURITY.md).

## Development

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --no-default-features --features pg18 -- \
    -D warnings -W clippy::pedantic
cargo pgrx test pg18 --no-default-features --features pg18
./ci/test-extension.sh "$(cargo pgrx info pg-config 18)"
```
