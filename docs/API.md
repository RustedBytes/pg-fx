# SQL API

## Types

- `fx_pair`: canonical `BASE/QUOTE` identity. Simple symbols are uppercase;
  namespaced `pg_cryptocurrency` assets such as `USDC@ethereum` retain their
  lowercase network namespace.
- `fx_side`: `buy_base` or `sell_base`.
- `fx_quote_status`: `open`, `executed`, `expired`, or `cancelled`.
- `fx_rate_strategy`: `latest`, `priority`, `best_bid`, `best_ask`, `median`,
  `weighted_median`, `vwap`, or `trimmed_mean`.
- `fx_rounding_mode`: `half_even`, `half_up`, `down`, or `up`.
- `fx_price_snapshot`: derived pair, bid/ask, timestamps, and JSON provenance.

`fx_pair` has default B-tree and hash operator classes.

```sql
SELECT 'USD/EUR'::fx_pair;
SELECT fx_pair('BTC', 'USD');
SELECT fx_pair_base('BTC/USD'), fx_pair_quote('BTC/USD');
SELECT fx_pair_valid('USDT@ethereum/UAH');
```

## Sources and observations

```text
fx_source_upsert(source_name, source_priority = 100, source_enabled = true,
                 source_max_age = '30 seconds', source_metadata = {})
fx_rate_insert(source, rate_pair, rate_bid, rate_ask,
               rate_observed_at = clock_timestamp(),
               rate_received_at = clock_timestamp(), rate_max_age = NULL,
               rate_metadata = {}, rate_volume = NULL)
fx_rate_latest(rate_pair)
fx_rate_current(rate_pair, as_of = clock_timestamp())
fx_rate_candidates(rate_pair, as_of = clock_timestamp())
```

`observed_at` is the upstream applicability time; `received_at` is ingestion
time. Rows in `fx_rates` are append-only. `fx_rate_candidates` returns the
newest fresh observation for every enabled source. `fx_rate_current` chooses
the candidate with the lowest source priority. It raises instead of returning
a stale price.

`fx_rate_latest` returns the globally newest enabled observation without
applying source priority or staleness. Use `fx_rate_current` for executable
pricing. `rate_volume` is optional but must be positive when supplied;
volume-weighted strategies use fresh observations that carry it.

## Prices and derivation

```text
fx_bid(pair, as_of = clock_timestamp())
fx_ask(pair, as_of = clock_timestamp())
fx_mid(pair, as_of = clock_timestamp())
fx_best_bid(pair, as_of = clock_timestamp())
fx_best_ask(pair, as_of = clock_timestamp())
fx_composite_rate(pair, strategy = 'priority', as_of = clock_timestamp())
fx_weighted_median(pair, as_of = clock_timestamp())
fx_vwap(pair, as_of = clock_timestamp())
fx_trimmed_mean(pair, as_of = clock_timestamp())
fx_inverse(pair, bid, ask)
fx_inverse(pair, as_of = clock_timestamp())
fx_cross_rate(target_pair, via, as_of = clock_timestamp())
fx_spread_bps(bid, ask)
fx_spread_bps(pair, as_of = clock_timestamp())
```

Inverse prices use `inverse bid = 1 / ask` and `inverse ask = 1 / bid`.
Cross rates multiply both legs and retain both source-rate IDs in provenance.
Composite strategies use the newest fresh observation from each enabled
source. `trimmed_mean` removes the lowest and highest 10 percent by mid price;
`weighted_median` and `vwap` use volume and raise when no fresh volume-bearing
observation exists.

## Conversion and rounding

```text
fx_round(value, scale, mode = 'half_even')
fx_convert(amount, pair, side, rate, output_scale = 2,
           rounding = 'half_even') -> numeric
fx_convert(input_text, output_asset, rate, output_scale = 2,
           rounding = 'half_even') -> text
```

For `sell_base`, output is `amount * rate`; for `buy_base`, output is
`amount / rate`. Rates remain unrestricted PostgreSQL `numeric`, independent of
either asset's storage precision. Rounding is always explicit at the asset
boundary.

## Rules and quotes

```text
fx_rule_create(rule_pair, segment = 'retail', minimum = 0, maximum = NULL,
               markup = 0, fixed = 0, percentage = 0,
               rule_priority = 100, starts_at = -infinity,
               ends_at = infinity, rule_metadata = {})

fx_create_quote(rate_pair, quote_side, amount,
                customer_segment = 'retail', customer_id = NULL,
                expires_in = '30 seconds', output_scale = 2,
                rounding = 'half_even', quote_metadata = {})
fx_create_quote(input, output_asset, customer_id = NULL,
                customer_segment = 'retail', expires_in = '30 seconds',
                output_scale = 2, rounding = 'half_even', quote_metadata = {})
fx_get_quote(quote_id)
fx_quote_is_valid(quote_id, as_of = clock_timestamp())
fx_quote_effective_status(quote_id, as_of = clock_timestamp())
fx_expire_quote(quote_id, as_of = clock_timestamp())
fx_expire_quotes(as_of = clock_timestamp())
fx_expire_quotes_batch(batch_size = 1000, as_of = clock_timestamp())
fx_execute_quote(quote_id, executed_time = clock_timestamp())
fx_cancel_quote(quote_id, cancelled_time = clock_timestamp())
```

`markup` is in basis points. `fixed` is denominated in the input asset and
`percentage` uses percentage units (`0.5` means 0.5%). Rules match half-open
amount ranges and validity windows; lower priority values win. Markup math is
side-aware:

- `sell_base`: market bid multiplied by `1 - markup_bps / 10000`.
- `buy_base`: market ask multiplied by `1 + markup_bps / 10000`.

Quote pricing, provenance, identity, timestamps, and metadata are immutable.
Only one state transition from `open` is accepted.

Expiry is time-based before stored status is swept: `fx_quote_is_valid` returns
false and `fx_quote_effective_status` returns `expired` at the boundary. Run
Call `fx_expire_quotes_batch()` repeatedly when persisted status must reflect
every due quote. Its batches are bounded to 100,000 rows and concurrent workers
use `SKIP LOCKED` to divide work without waiting on each other.
`fx_expire_quotes()` performs an unbounded lock-skipping sweep. Cancellation
expires a due quote instead of recording it as cancelled.

## Ledger metadata and validation

```text
fx_quote_ledger_metadata(quote_id) -> jsonb
fx_validate() -> table(check_name, valid, details)
fx_validate(pair) -> boolean
```

The ledger payload contains the quote ID, side, both amounts/assets, fee,
market and customer rates, spread, source, source-rate ID, and relevant times.

## Optional adapters

```text
fx_enable_pg_money() -> boolean
fx_enable_pg_cryptocurrency() -> boolean
fx_enable_cross_asset_quotes() -> boolean
```

With `pg_money`, `fx_convert(money_with_currency, text, numeric)` delegates to
`money_exchange`. With `pg_cryptocurrency`,
`fx_convert(crypto_amount, text, numeric, fx_rounding_mode)` uses the target
asset's registered decimal scale; a target-typed `crypto_asset` overload is
also installed. Adapter functions return `false` when the required extension
or API is absent.

The adapters also add exact-input quote overloads. They obtain the input amount
and canonical identity from `money_with_currency` or `crypto_amount`, validate
the target through the companion extension, and derive output precision from
currency or crypto-asset metadata:

```text
fx_create_quote(money_with_currency, output_currency_text, ...)
fx_create_quote(crypto_amount, crypto_asset, ...)
fx_create_quote(money_with_currency, crypto_asset, ...)
fx_create_quote(crypto_amount, output_currency_text, ...)
```

Cast crypto targets explicitly to `crypto_asset` and fiat targets paired with a
`crypto_amount` explicitly to `text`; this avoids overload ambiguity for string
literals. The cross-asset enable function returns false unless both companion
extensions expose the required APIs.

## Views

- `fx_current_rates`: current primary/fallback rows with calculated mid and age.
- `fx_quote_details`: quote rows with stored and effective status, live validity,
  and source name.
- `fx_active_rules`: rules active at statement time.
