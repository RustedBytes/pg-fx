# Security model

The extension is installable by a non-superuser when PostgreSQL permits trusted
extension installation. It is non-relocatable after installation and pins all
extension functions to the installation schema plus `pg_catalog`, preventing a
caller-controlled `search_path` from redirecting internal object references.

`fx_rates` and `fx_quotes` are append-only/immutable except for the guarded
quote status transition. Direct mutation privileges are revoked from `PUBLIC`;
all four core tables are publicly readable by default for parity with the other
RustedBytes extensions. Production installations should revoke those grants
when quotes or customer metadata are sensitive and grant access through
application roles or filtered views.

Configuration and ingestion functions are security-invoker functions. Calling
roles therefore need the corresponding table/sequence privileges; the
extension does not use `SECURITY DEFINER` to let arbitrary users configure
sources, rules, or prices. Grant the minimum privileges to a dedicated market
data role and a separate quote-service role.

The extension never performs HTTP, DNS, file, shell, or provider access. JSON
metadata is treated as data and must be an object. Rates, amounts, fees,
intervals, state transitions, and pair identities are constrained in the
database.

Because `fx_execute_quote` only changes quote status, callers must place it and
the associated `pg_ledger` posting in the same database transaction. Use the
quote ID as the ledger idempotency key to prevent duplicate execution.
