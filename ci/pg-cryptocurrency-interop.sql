\if :crypto_first
CREATE EXTENSION pg_cryptocurrency;
CREATE EXTENSION pg_fx;
\else
CREATE SCHEMA pricing;
CREATE SCHEMA assets;
CREATE EXTENSION pg_fx SCHEMA pricing;
CREATE EXTENSION pg_cryptocurrency SCHEMA assets;
SET search_path = pricing, assets, public;
SELECT fx_enable_pg_cryptocurrency();
\endif

DO $assertions$
BEGIN
    IF to_regprocedure(
        'fx_convert(crypto_amount,crypto_asset,numeric,fx_rounding_mode)'
    ) IS NULL THEN
        RAISE EXCEPTION 'typed pg_cryptocurrency conversion adapter is missing';
    END IF;
    IF to_regprocedure(
        'fx_create_quote(crypto_amount,crypto_asset,text,text,interval,fx_rounding_mode,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION 'typed pg_cryptocurrency quote adapter is missing';
    END IF;
END
$assertions$;

SELECT crypto_amount_asset('1 BTC'::crypto_amount)::text AS btc_asset,
       'ETH'::crypto_asset::text AS eth_asset
\gset

SELECT fx_source_upsert('crypto', 1, true, interval '1 minute');
SELECT fx_rate_insert(
    'crypto', fx_pair(:'btc_asset', :'eth_asset'), 20, 21,
    rate_volume => 10
);
SELECT (fx_create_quote(
    '1 BTC'::crypto_amount,
    'ETH'::crypto_asset,
    customer_id => 'crypto-customer'
)).id;

DO $assertions$
DECLARE
    converted crypto_amount;
BEGIN
    SELECT fx_convert('1 BTC'::crypto_amount, 'ETH'::crypto_asset, 20)
    INTO converted;

    IF crypto_amount_value(converted) <> 20
       OR crypto_amount_asset(converted) <> 'ETH'::crypto_asset THEN
        RAISE EXCEPTION 'typed crypto conversion did not retain exact target identity';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM fx_quotes
        WHERE pair = fx_pair(crypto_amount_asset('1 BTC'::crypto_amount)::text,
                             'ETH'::crypto_asset::text)
          AND input_asset = crypto_amount_asset('1 BTC'::crypto_amount)::text
          AND output_asset = 'ETH'::crypto_asset::text
          AND input_amount = 1
          AND output_amount = 20
          AND customer_id = 'crypto-customer'
    ) THEN
        RAISE EXCEPTION 'typed crypto quote did not retain canonical assets and amount';
    END IF;
END
$assertions$;
