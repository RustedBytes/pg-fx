CREATE EXTENSION pg_fx;

SELECT 'usd/eur'::fx_pair = 'USD/EUR'::fx_pair;
SELECT fx_pair_base('BTC/USD'), fx_pair_quote('BTC/USD');

SELECT fx_source_upsert('primary', 10, true, interval '30 seconds');
SELECT fx_source_upsert('fallback', 20, true, interval '2 minutes');
SELECT fx_rate_insert('primary', 'USD/EUR', 0.8510, 0.8520);
SELECT fx_rate_insert('fallback', 'USD/EUR', 0.8500, 0.8530);

DO $assertions$
BEGIN
    IF fx_bid('USD/EUR') <> 0.8510 OR fx_ask('USD/EUR') <> 0.8520
       OR fx_mid('USD/EUR') <> 0.8515 THEN
        RAISE EXCEPTION 'primary rate selection failed';
    END IF;
    IF (fx_inverse('EUR/USD', 1, 1.25)).bid <> 0.8
       OR (fx_inverse('EUR/USD', 1, 1.25)).ask <> 1 THEN
        RAISE EXCEPTION 'inverse bid/ask calculation failed';
    END IF;
    IF fx_convert(100, 'USD/EUR', 'sell_base', 0.851372941, 2) <> 85.14 THEN
        RAISE EXCEPTION 'explicit conversion rounding failed';
    END IF;
END
$assertions$;

SELECT fx_rule_create('USD/EUR', 'retail', 0, 10000, 50, 5, 0);
SELECT (fx_create_quote(
    'USD/EUR', 'sell_base', 1000, 'retail', 'customer-1', interval '30 seconds'
)).id AS quote_id;

DO $assertions$
DECLARE
    quote_id text;
BEGIN
    SELECT id INTO quote_id FROM fx_quotes ORDER BY created_at DESC LIMIT 1;
    IF NOT fx_quote_is_valid(quote_id) THEN
        RAISE EXCEPTION 'new quote is not valid';
    END IF;
    IF fx_quote_ledger_metadata(quote_id)->>'type' <> 'fx_exchange' THEN
        RAISE EXCEPTION 'ledger metadata does not identify an FX exchange';
    END IF;
    IF (fx_execute_quote(quote_id)).status <> 'executed' THEN
        RAISE EXCEPTION 'quote execution transition failed';
    END IF;
    IF EXISTS (SELECT 1 FROM fx_validate() WHERE NOT valid) THEN
        RAISE EXCEPTION 'fx_validate reported an invariant failure';
    END IF;
END
$assertions$;

CREATE SCHEMA isolated;
DROP EXTENSION pg_fx CASCADE;
CREATE EXTENSION pg_fx SCHEMA isolated;
SET search_path = pg_catalog;

SELECT isolated.fx_source_upsert('custom', 1, true, interval '1 minute');
SELECT isolated.fx_rate_insert('custom', 'USD/EUR'::isolated.fx_pair, 0.85, 0.86);
SELECT isolated.fx_mid('USD/EUR'::isolated.fx_pair) = 0.855;
