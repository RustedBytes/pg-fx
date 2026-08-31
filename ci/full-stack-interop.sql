CREATE EXTENSION pg_cryptocurrency;
CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_fx;

SELECT ledger_create_account('customer:btc', 'BTC', 'ANY') AS customer_btc \gset
SELECT ledger_create_account('liquidity:btc', 'BTC', 'ANY') AS liquidity_btc \gset
SELECT ledger_create_account('liquidity:eth', 'ETH', 'ANY') AS liquidity_eth \gset
SELECT ledger_create_account('customer:eth', 'ETH', 'ANY') AS customer_eth \gset

SELECT fx_source_upsert('crypto', 1, true, interval '1 minute');
SELECT fx_rate_insert('crypto', 'BTC/ETH', 20, 21, rate_volume => 10);
SELECT (fx_create_quote(
    '1 BTC'::crypto_amount,
    'ETH'::crypto_asset,
    customer_id => 'customer-crypto'
)).id AS quote_id
\gset

BEGIN;
SELECT ledger_post(
    ARRAY[
        ledger_posting(:'customer_btc'::uuid, '-1 BTC'),
        ledger_posting(:'liquidity_btc'::uuid, '1 BTC'),
        ledger_posting(:'liquidity_eth'::uuid, '-20 ETH'),
        ledger_posting(:'customer_eth'::uuid, '20 ETH')
    ],
    reference => 'fx:' || :'quote_id',
    idempotency_key => 'fx:' || :'quote_id',
    metadata => fx_quote_ledger_metadata(:'quote_id')
);
SELECT fx_execute_quote(:'quote_id');
COMMIT;

DO $assertions$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM ledger_transactions
        WHERE reference = ('fx:' || (metadata->>'quote_id'))
          AND metadata->>'type' = 'fx_exchange'
          AND metadata->>'input_asset' = crypto_amount_asset('1 BTC'::crypto_amount)::text
          AND metadata->>'output_asset' = 'ETH'::crypto_asset::text
    ) THEN
        RAISE EXCEPTION 'full-stack ledger transaction lost typed FX provenance';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM fx_quotes
        WHERE customer_id = 'customer-crypto' AND status = 'executed'
          AND input_asset = crypto_amount_asset('1 BTC'::crypto_amount)::text
          AND output_asset = 'ETH'::crypto_asset::text
    ) THEN
        RAISE EXCEPTION 'typed FX quote was not executed atomically';
    END IF;
    IF EXISTS (SELECT 1 FROM ledger_validate() WHERE status <> 'OK') THEN
        RAISE EXCEPTION 'ledger validation failed after typed FX transaction';
    END IF;
END
$assertions$;
