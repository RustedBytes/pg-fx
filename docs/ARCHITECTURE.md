# Architecture

`pg_fx` owns prices and pricing decisions. It does not own balances, fetch
external data, or post accounting movements.

The PostgreSQL layer owns tables, constraints, indexes, source/rule selection,
staleness checks, quote transitions, and audit views. Rust/pgrx owns compact
validated base types and enums. Arbitrary-precision PostgreSQL `numeric` is
used for rates and calculations; floating point is never used.

External collectors normalize provider data into `fx_rates`. Each observation
is append-only and distinguishes upstream `observed_at` from local
`received_at`. Current-rate selection first chooses the latest fresh row from
each enabled source, then applies source priority. A stale primary can fall back
to a fresh secondary; no fresh source produces an error.

Observations may include positive volume. Median and trimmed-mean composites
work without it; weighted median and VWAP use volume-bearing observations. Raw
`fx_rate_latest` is deliberately global and unfiltered, while executable
pricing always uses staleness-aware functions.

Customer quotes are stored separately from market observations. A quote points
to the exact source row and optional pricing rule that produced it, making the
decision reproducible without reconstructing historical policy. Status is a
small one-way state machine; all pricing fields remain immutable.

`pg_money` and `pg_cryptocurrency` remain the exact amount/asset layers.
`pg_ledger` remains the accounting truth. The recommended service transaction
is:

1. Lock/read and validate the open FX quote.
2. Call `ledger_post` with per-asset-balanced postings, an idempotency key based
   on the quote ID, and `fx_quote_ledger_metadata(quote_id)`.
3. Call `fx_execute_quote(quote_id)`.
4. Commit both operations atomically.

This keeps the ledger concerned with what moved and the FX extension concerned
with why those amounts were chosen.

Core tables retain canonical asset identities as text so `pg_fx` has no hard
dependency on an amount extension and can price application-defined assets.
When companion extensions are present, typed quote overloads extract canonical
identities from native values, validate targets, and derive rounding precision
from companion metadata. This provides strict paths without weakening the
standalone installation model.
