\if :companions_first
CREATE EXTENSION pg_money;
CREATE EXTENSION pg_cryptocurrency;
CREATE EXTENSION pg_fx;
\else
CREATE EXTENSION pg_fx;
CREATE EXTENSION pg_money;
CREATE EXTENSION pg_cryptocurrency;
SELECT fx_enable_pg_money();
SELECT fx_enable_pg_cryptocurrency();
\endif

DO $assertions$
BEGIN
    IF to_regprocedure(
        'fx_create_quote(money_with_currency,text,text,text,interval,fx_rounding_mode,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION 'typed pg_money quote adapter is missing';
    END IF;
    IF to_regprocedure(
        'fx_create_quote(money_with_currency,crypto_asset,text,text,interval,fx_rounding_mode,jsonb)'
    ) IS NULL OR to_regprocedure(
        'fx_create_quote(crypto_amount,text,text,text,interval,fx_rounding_mode,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION 'typed fiat/crypto quote adapters are missing';
    END IF;
END
$assertions$;

SELECT crypto_amount_asset('1 BTC'::crypto_amount)::text AS btc_asset
\gset

SELECT fx_source_upsert('mixed', 1, true, interval '1 minute');
SELECT fx_rate_insert('mixed', 'USD/EUR', 0.85, 0.86);
SELECT fx_rate_insert('mixed', fx_pair('USD', :'btc_asset'), 0.00001, 0.000011);
SELECT fx_rate_insert('mixed', fx_pair(:'btc_asset', 'USD'), 100000, 101000);

SELECT fx_create_quote('USD 100'::money_with_currency, 'EUR');
SELECT fx_create_quote('USD 100'::money_with_currency, 'BTC'::crypto_asset);
SELECT fx_create_quote('1 BTC'::crypto_amount, 'USD');

DO $assertions$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM fx_quotes
        WHERE input_asset = 'USD' AND output_asset = 'EUR'
          AND input_amount = 100 AND output_amount = 85
    ) THEN
        RAISE EXCEPTION 'typed fiat quote failed';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM fx_quotes
        WHERE input_asset = 'USD'
          AND output_asset = crypto_amount_asset('1 BTC'::crypto_amount)::text
          AND input_amount = 100 AND output_amount = 0.001
    ) THEN
        RAISE EXCEPTION 'typed fiat-to-crypto quote failed';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM fx_quotes
        WHERE input_asset = crypto_amount_asset('1 BTC'::crypto_amount)::text
          AND output_asset = 'USD'
          AND input_amount = 1 AND output_amount = 100000
    ) THEN
        RAISE EXCEPTION 'typed crypto-to-fiat quote failed';
    END IF;
END
$assertions$;
