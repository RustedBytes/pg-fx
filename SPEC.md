`pg-fx` should be the pricing and quote layer between `pg_money` / `pg_cryptocurrency` and `pg-ledger`.

Its job is not accounting, and it should not own balances. It should answer questions like: “What is the current executable USD/EUR price?”, “What rate did we quote this customer?”, “How much spread did we charge?”, “Which source produced this price?”, and “Was this quote still valid when the trade executed?”

A clean separation is:

```text
pg_money
    exact fiat amounts

pg_cryptocurrency
    exact crypto assets and amounts

pg_fx
    prices, pairs, quotes, spreads, conversions

pg_ledger
    immutable financial movements
```

For an exchange service, `pg_fx` becomes the pricing engine.

## Core concepts

The first important type is an FX pair:

```text
USD/EUR
BTC/USD
ETH/USDT
USDT/UAH
```

Conceptually:

```text
base / quote
```

So:

```text
BTC/USD = 108500
```

means:

```text
1 BTC = 108500 USD
```

I would define:

```rust
struct FxPair {
    base: Asset,
    quote: Asset,
}
```

where `Asset` can refer to either a `pg_money` currency or a `pg_cryptocurrency` asset.

That means `pg_fx` is not limited to fiat FX.

It can support:

```text
USD/EUR
EUR/UAH

BTC/USD
ETH/USD

BTC/USDT
ETH/USDC

USDT/UAH
```

using the same API.

## Do not represent a market as one rate

A simplistic system stores:

```text
USD/EUR = 0.8500
```

but an exchange actually needs:

```text
mid = 0.8500

bid = 0.8485
ask = 0.8515
```

The distinction matters.

For a pair:

```text
EUR/USD
```

you might have:

```text
bid = 1.1720
ask = 1.1740
mid = 1.1730
```

The exchange buys the base asset at the bid and sells it at the ask.

So the core quote should be something like:

```rust
struct FxRate {
    pair: FxPair,
    bid: Decimal,
    ask: Decimal,
    timestamp: Timestamp,
}
```

with invariant:

```text
bid <= ask
```

and typically:

```text
mid = (bid + ask) / 2
```

calculated rather than stored unless there is a good reason.

## Separate market rates from customer rates

This is one of the most important design decisions.

Suppose your upstream market gives:

```text
USD/EUR

bid = 0.8510
ask = 0.8520
```

You may quote a customer:

```text
customer buys EUR:

rate = 0.8485
```

because your markup/spread is included.

These are different objects.

I would model:

```text
fx_market_tick
fx_quote
```

separately.

A market observation:

```text
source        ECB / Binance / Kraken / bank / internal
pair          USD/EUR
bid           0.8510
ask           0.8520
observed_at
received_at
```

A customer quote:

```text
quote_id
pair
side
input_amount
output_amount
market_rate
customer_rate
spread
fee
expires_at
created_at
```

Then your ledger can reference:

```text
quote_id
```

without trying to reconstruct pricing later.

## `fx_quote` should be first-class

Suppose the user asks:

```text
Exchange 1000 USD to EUR
```

Your pricing engine might calculate:

```text
market mid       0.85150

customer rate    0.84800

input            1000 USD
output            848 EUR

gross spread      3.50 EUR equivalent
```

Then create:

```text
fx_quote
```

with an immutable ID.

For example:

```sql
SELECT fx_quote(
    'USD/EUR',
    'USD 1000'
);
```

might return:

```text
quote_id        fxq_...
pair            USD/EUR
side            sell_base
input           USD 1000.00
output          EUR 848.00
market_rate     0.851500
customer_rate   0.848000
expires_at      ...
```

Then execution is:

```sql
SELECT fx_execute_quote('fxq_...');
```

or the Rust service handles execution and sends the resulting postings to `pg-ledger`.

I would actually prefer the latter.

`pg_fx` should calculate and persist pricing.

`pg_ledger` should move money.

## Data model

A reasonable v1 schema would have four main tables.

### 1. `fx_sources`

```text
fx_sources

id
name
priority
enabled
metadata
```

Examples:

```text
ecb
nbu
kraken
coinbase
binance
internal_dealing
bank_partner_1
```

### 2. `fx_rates`

```text
fx_rates

id
source_id
pair
bid
ask

observed_at
received_at

metadata
```

Important distinction:

```text
observed_at
```

is when the upstream source says the price applies.

```text
received_at
```

is when your system saw it.

This matters for latency and stale-rate detection.

### 3. `fx_quotes`

```text
fx_quotes

id
pair

input_asset
output_asset

input_amount
output_amount

market_rate
customer_rate

spread
fee

source_rate_id

created_at
expires_at
executed_at

status

metadata
```

### 4. `fx_rules`

This is your pricing configuration:

```text
fx_rules

pair
customer_segment
min_amount
max_amount

markup_bps
fixed_fee
percentage_fee

priority
valid_from
valid_to
```

For example:

```text
USD/EUR
retail
0 - 1000
markup = 50 bps

USD/EUR
retail
1000 - 10000
markup = 30 bps

USD/EUR
vip
0 - infinity
markup = 10 bps
```

That lets you implement pricing without embedding business policy in Rust source code.

## Spread representation

I would support both:

```text
absolute spread
basis points
```

but normalize internally.

A basis point is:

```text
1 bp = 0.01%
```

So:

```text
50 bp = 0.50%
```

For example:

```text
market rate = 0.8500
markup = 50 bp
```

may produce roughly:

```text
customer rate = 0.84575
```

depending on trade direction and rounding rules.

I would strongly avoid treating markup as a generic symmetric formula without considering side.

You need explicit:

```text
BUY
SELL
```

or:

```text
BUY_BASE
SELL_BASE
```

because the math is direction-dependent.

## Suggested types

I would make these PostgreSQL-native types via pgrx:

```text
fx_pair
fx_side
fx_rate
fx_quote_status
```

For example:

```sql
SELECT 'USD/EUR'::fx_pair;
SELECT 'BTC/USD'::fx_pair;
```

and:

```text
fx_side =
    buy_base
    sell_base
```

Possibly:

```rust
enum FxSide {
    BuyBase,
    SellBase,
}
```

`fx_rate` could either be a structured type:

```text
USD/EUR@0.851234
```

or just a strongly validated decimal tied to a pair.

I slightly prefer keeping pair and price separate in SQL because it makes indexing and arithmetic simpler:

```text
pair fx_pair
rate numeric
```

rather than embedding everything in a large custom type.

## Price precision must not equal money precision

This is another important rule.

Money may have:

```text
USD = 2 decimals
JPY = 0
BTC = 8
USDC = 6
```

but FX rates often need much more precision:

```text
USD/EUR = 0.851372941
```

So `pg_fx` should use a high-precision decimal rate, not reuse the decimal scale of either asset.

Something like:

```text
NUMERIC(38,18)
```

could be reasonable, though I would probably avoid hard-coding too restrictive a typmod in the core extension.

Then conversion follows:

```text
raw output
    ↓
asset rounding rules
    ↓
final amount
```

For example:

```text
100 USD × 0.851372941
= 85.1372941 EUR

round to EUR minor unit
= 85.14 EUR
```

That rounding policy should be explicit.

## Rate sources and aggregation

Eventually, you may have multiple sources:

```text
Kraken     BTC/USD 108520
Coinbase   BTC/USD 108510
Binance    BTC/USDT 108490
```

Then `pg_fx` could provide:

```text
fx_best_bid()
fx_best_ask()
fx_mid()
fx_vwap()
fx_composite()
```

For example:

```sql
SELECT fx_best_bid('BTC/USD');
SELECT fx_best_ask('BTC/USD');
```

or:

```sql
SELECT fx_composite_rate(
    'BTC/USD',
    strategy => 'median'
);
```

Potential strategies:

```text
latest
priority source
median
weighted median
best bid/ask
VWAP
trimmed mean
```

For a basic exchange I would start with:

```text
primary source
fallback source
staleness check
```

rather than implementing a full market data aggregator immediately.

## Staleness is mandatory

Every rate should have an expiry or maximum age.

Example:

```text
crypto:
max age = 2 seconds

fiat retail:
max age = 30 seconds

central bank reference:
max age = 24 hours
```

Then:

```sql
SELECT fx_rate_current('USD/EUR');
```

should reject stale pricing rather than silently returning it.

Conceptually:

```text
ERROR: rate stale
pair: USD/EUR
age: 184 seconds
maximum_age: 30 seconds
```

For money exchange software, stale pricing is more dangerous than a temporary failure.

## Quotes must expire

A quote should have:

```text
created_at
expires_at
```

For example:

```text
crypto quote:
10 seconds

fiat cash-style quote:
30 seconds

bank transfer quote:
5 minutes
```

Then:

```sql
fx_quote_is_valid(id)
```

checks:

```text
status = OPEN
AND now() < expires_at
```

Once executed:

```text
OPEN → EXECUTED
```

or:

```text
OPEN → EXPIRED
OPEN → CANCELLED
```

A quote should never be edited.

## How it interacts with `pg-ledger`

This is where the architecture comes together.

Suppose:

```text
customer gives:
1000 USD

customer receives:
850 EUR
```

`pg_fx` determines:

```text
quote_id = Q1
customer_rate = 0.8500
```

Then `pg-ledger` records:

```text
customer.usd       -1000 USD
liquidity.usd      +1000 USD

liquidity.eur       -850 EUR
customer.eur        +850 EUR
```

Ledger transaction metadata:

```json
{
  "type": "fx_exchange",
  "quote_id": "Q1"
}
```

The ledger knows **what moved**.

The FX system knows **why those two amounts were chosen**.

That separation is extremely useful for auditing.

## Fees

I'd keep pricing fees in `pg_fx`, but account for them in `pg-ledger`.

For example:

```text
input = 1000 USD
service fee = 5 USD
convertible amount = 995 USD
rate = 0.8500
output = 845.75 EUR
```

`pg_fx` quote:

```text
input        1000 USD
fee             5 USD
net_input      995 USD
rate         0.8500
output       845.75 EUR
```

Ledger:

```text
customer.usd        -1000 USD
liquidity.usd        +995 USD
fee_income.usd         +5 USD

liquidity.eur       -845.75 EUR
customer.eur        +845.75 EUR
```

Still balanced by asset.

## Inverse rates

I would support derived inverse rates carefully.

Given:

```text
EUR/USD = 1.1750
```

inverse mid is:

```text
USD/EUR ≈ 0.8510638
```

But for bid/ask:

```text
inverse bid = 1 / ask
inverse ask = 1 / bid
```

not:

```text
1 / bid
1 / ask
```

This is an easy bug to make.

So `pg_fx` should expose:

```text
fx_inverse()
```

and centralize that logic.

## Cross rates

Eventually:

```text
UAH/EUR
```

may be unavailable directly, but you might have:

```text
UAH/USD
USD/EUR
```

Then:

```text
UAH/EUR =
UAH/USD × USD/EUR
```

You could expose:

```sql
SELECT fx_cross_rate(
    'UAH/EUR',
    via => 'USD'
);
```

But I'd make derived rates retain provenance:

```text
UAH/USD source A
USD/EUR source B
```

so you can audit exactly how the quote was calculated.

## Proposed API

A compact useful v1 could be:

```text
fx_pair()

fx_rate_insert()
fx_rate_latest()
fx_rate_current()

fx_mid()
fx_bid()
fx_ask()

fx_convert()

fx_create_quote()
fx_get_quote()
fx_expire_quote()

fx_inverse()
fx_spread_bps()

fx_validate()
```

Examples:

```sql
SELECT fx_mid('USD/EUR');
```

```sql
SELECT fx_convert(
    'USD 1000',
    'EUR',
    0.8512
);
```

```sql
SELECT *
FROM fx_create_quote(
    input => 'USD 1000',
    output_asset => 'EUR',
    customer_id => '...'
);
```

## pgrx project layout

I would structure it roughly as:

```text
pg-fx/
├── src/
│   ├── lib.rs
│   ├── pair.rs
│   ├── rate.rs
│   ├── quote.rs
│   ├── spread.rs
│   ├── conversion.rs
│   ├── source.rs
│   ├── rules.rs
│   ├── staleness.rs
│   └── errors.rs
│
├── sql/
│   ├── schema.sql
│   ├── indexes.sql
│   └── views.sql
│
└── tests/
    ├── pair.rs
    ├── rates.rs
    ├── inverse.rs
    ├── quoting.rs
    ├── spread.rs
    ├── expiration.rs
    └── money_crypto.rs
```

I would keep HTTP/network access out of the extension.

Your Rust exchange service should fetch:

```text
NBU
ECB
banks
crypto exchanges
market data providers
```

and write normalized rates into PostgreSQL.

`pg_fx` should be deterministic and database-local.

That is the same design principle already used by `pg_money`: conversion logic in PostgreSQL, external rate fetching outside PostgreSQL.

## The full stack then becomes

```text
External market feeds
        │
        ▼
Rust market-data service
        │
        ▼
      pg_fx
  rates / quotes
        │
        ├──────────────┐
        ▼              ▼
    pg_money       pg_cryptocurrency
      fiat           crypto
        │              │
        └──────┬───────┘
               ▼
           pg_ledger
       accounting truth
```

The clean rule I'd use is:

**`pg_money` knows amounts. `pg_cryptocurrency` knows crypto assets. `pg_fx` knows what one asset is worth in another. `pg_ledger` knows where assets moved.**

That separation gives you a very strong foundation for the exchange service.
