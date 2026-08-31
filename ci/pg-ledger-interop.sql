CREATE EXTENSION pg_ledger;
CREATE EXTENSION pg_fx;

SELECT ledger_create_account('customer:usd', 'USD', 'ANY') AS customer_usd \gset
SELECT ledger_create_account('liquidity:usd', 'USD', 'ANY') AS liquidity_usd \gset
SELECT ledger_create_account('fee:usd', 'USD', 'ANY') AS fee_usd \gset
SELECT ledger_create_account('liquidity:eur', 'EUR', 'ANY') AS liquidity_eur \gset
SELECT ledger_create_account('customer:eur', 'EUR', 'ANY') AS customer_eur \gset

SELECT fx_source_upsert('primary', 1, true, interval '1 minute');
SELECT fx_rate_insert('primary', 'USD/EUR', 0.8510, 0.8520);
SELECT fx_rule_create('USD/EUR', 'retail', 0, 10000, 50, 5, 0);
SELECT (fx_create_quote('USD/EUR', 'sell_base', 1000, 'retail')).id AS quote_id \gset

BEGIN;
SELECT ledger_post(
    ARRAY[
        ledger_posting(:'customer_usd'::uuid, '-1000 USD'),
        ledger_posting(:'liquidity_usd'::uuid, '995 USD'),
        ledger_posting(:'fee_usd'::uuid, '5 USD'),
        ledger_posting(:'liquidity_eur'::uuid, '-842.51 EUR'),
        ledger_posting(:'customer_eur'::uuid, '842.51 EUR')
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
    ) THEN
        RAISE EXCEPTION 'ledger transaction did not retain FX quote metadata';
    END IF;
    IF EXISTS (SELECT 1 FROM fx_quotes WHERE status <> 'executed') THEN
        RAISE EXCEPTION 'FX quote did not transition atomically with ledger posting';
    END IF;
    IF EXISTS (SELECT 1 FROM ledger_validate() WHERE status <> 'OK') THEN
        RAISE EXCEPTION 'ledger validation failed after FX posting';
    END IF;
END
$assertions$;
