use pgrx::prelude::*;

#[pg_schema]
mod tests {
    use super::*;

    fn seed_usd_eur() {
        Spi::run(
            "SELECT fx_source_upsert('primary', 10, true, interval '30 seconds'); \
             SELECT fx_rate_insert('primary', 'USD/EUR', 0.8510, 0.8520, \
                                   clock_timestamp(), clock_timestamp());",
        )
        .unwrap();
    }

    #[pg_test]
    fn pairs_validate_and_canonicalize() {
        assert_eq!(
            Spi::get_one::<String>("SELECT 'usd/eur'::fx_pair::text").unwrap(),
            Some("USD/EUR".to_owned())
        );
        assert_eq!(
            Spi::get_one::<String>("SELECT fx_pair('USDC@Ethereum', 'usd')::text").unwrap(),
            Some("USDC@ethereum/USD".to_owned())
        );
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT fx_pair_valid('BTC/USD') AND NOT fx_pair_valid('USD/USD')"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test(error = "invalid input syntax for type fx_pair: base and quote assets must differ")]
    fn pairs_reject_identical_assets() {
        Spi::run("SELECT 'USD/USD'::fx_pair").unwrap();
    }

    #[pg_test]
    fn current_rate_uses_bid_ask_and_priority() {
        seed_usd_eur();
        Spi::run(
            "SELECT fx_source_upsert('fallback', 20, true, interval '30 seconds'); \
             SELECT fx_rate_insert('fallback', 'USD/EUR', 0.8500, 0.8530, \
                                   clock_timestamp(), clock_timestamp());",
        )
        .unwrap();
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT fx_bid('USD/EUR') = 0.8510 \
                        AND fx_ask('USD/EUR') = 0.8520 \
                        AND fx_mid('USD/EUR') = 0.8515 \
                        AND fx_best_bid('USD/EUR') = 0.8510 \
                        AND fx_best_ask('USD/EUR') = 0.8520"
            )
            .unwrap(),
            Some(true)
        );
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT (p).bid = 0.8510 AND (m).bid = 0.8500 \
                 FROM (SELECT fx_composite_rate('USD/EUR', 'priority') p, \
                              fx_composite_rate('USD/EUR', 'median') m) values"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test]
    fn stale_primary_falls_back_to_fresh_source() {
        Spi::run(
            "SELECT fx_source_upsert('primary', 10, true, interval '1 second'); \
             SELECT fx_source_upsert('fallback', 20, true, interval '1 minute'); \
             SELECT fx_rate_insert('primary', 'BTC/USD', 100, 101, \
                                   clock_timestamp() - interval '2 seconds'); \
             SELECT fx_rate_insert('fallback', 'BTC/USD', 99, 102, clock_timestamp());",
        )
        .unwrap();
        assert_eq!(
            Spi::get_one::<String>(
                "SELECT s.name FROM fx_rate_current('BTC/USD') r \
                 JOIN fx_sources s ON s.id = r.source_id"
            )
            .unwrap(),
            Some("fallback".to_owned())
        );
    }

    #[pg_test]
    fn latest_is_global_while_current_respects_source_priority() {
        Spi::run(
            "SELECT fx_source_upsert('primary', 1, true, interval '1 minute'); \
             SELECT fx_source_upsert('secondary', 2, true, interval '1 minute'); \
             SELECT fx_rate_insert('primary', 'USD/JPY', 145, 146, \
                                   clock_timestamp() - interval '10 seconds'); \
             SELECT fx_rate_insert('secondary', 'USD/JPY', 147, 148, \
                                   clock_timestamp() - interval '1 second');",
        )
        .unwrap();
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT current_source.name = 'primary' AND latest_source.name = 'secondary' \
                        AND (fx_composite_rate('USD/JPY', 'latest')).bid = 147 \
                 FROM fx_rate_current('USD/JPY') current_rate \
                 JOIN fx_sources current_source ON current_source.id = current_rate.source_id \
                 CROSS JOIN fx_rate_latest('USD/JPY') latest_rate \
                 JOIN fx_sources latest_source ON latest_source.id = latest_rate.source_id"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test]
    fn volume_weighted_and_trimmed_composites_are_available() {
        Spi::run(
            "SELECT fx_source_upsert('venue_a', 1, true, interval '1 minute'); \
             SELECT fx_source_upsert('venue_b', 2, true, interval '1 minute'); \
             SELECT fx_source_upsert('venue_c', 3, true, interval '1 minute'); \
             SELECT fx_rate_insert('venue_a', 'BTC/USD', 90, 92, rate_volume => 1); \
             SELECT fx_rate_insert('venue_b', 'BTC/USD', 100, 102, rate_volume => 8); \
             SELECT fx_rate_insert('venue_c', 'BTC/USD', 110, 112, rate_volume => 1);",
        )
        .unwrap();
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT (vwap).bid = 100 AND (vwap).ask = 102 \
                        AND (weighted).bid = 100 AND (weighted).ask = 102 \
                        AND (trimmed).bid = 100 AND (trimmed).ask = 102 \
                        AND (vwap).provenance->>'strategy' = 'vwap' \
                 FROM (SELECT fx_vwap('BTC/USD') AS vwap, \
                              fx_weighted_median('BTC/USD') AS weighted, \
                              fx_trimmed_mean('BTC/USD') AS trimmed) prices"
            )
            .unwrap(),
            Some(true)
        );

        Spi::run(
            "SELECT fx_source_upsert('trim_' || value, 100 + value, true, interval '1 minute') \
             FROM generate_series(1, 10) values(value); \
             SELECT fx_rate_insert( \
                 'trim_' || value, \
                 'EUR/JPY', \
                 CASE value WHEN 1 THEN 1 WHEN 10 THEN 100 ELSE 50 END, \
                 CASE value WHEN 1 THEN 2 WHEN 10 THEN 101 ELSE 51 END \
             ) \
             FROM generate_series(1, 10) values(value);",
        )
        .unwrap();
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT (trimmed).bid = 50 AND (trimmed).ask = 51 \
                 FROM (SELECT fx_trimmed_mean('EUR/JPY') AS trimmed) prices"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test(error = "FX rate stale")]
    fn stale_rates_are_rejected() {
        Spi::run(
            "SELECT fx_source_upsert('old', 10, true, interval '1 second'); \
             SELECT fx_rate_insert('old', 'BTC/USD', 100, 101, \
                                   clock_timestamp() - interval '2 seconds'); \
             SELECT fx_rate_current('BTC/USD');",
        )
        .unwrap();
    }

    #[pg_test]
    fn inverse_swaps_bid_and_ask_correctly() {
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT (x).pair = 'USD/EUR'::fx_pair \
                        AND (x).bid = 0.8 \
                        AND (x).ask = 1 \
                 FROM (SELECT fx_inverse('EUR/USD', 1, 1.25) AS x) values"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test]
    fn cross_rates_retain_both_source_ids() {
        Spi::run(
            "SELECT fx_source_upsert('feed', 1, true, interval '1 minute'); \
             SELECT fx_rate_insert('feed', 'UAH/USD', 0.02, 0.021); \
             SELECT fx_rate_insert('feed', 'USD/EUR', 0.85, 0.86);",
        )
        .unwrap();
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT (x).bid = 0.017 AND (x).ask = 0.01806 \
                        AND jsonb_array_length((x).provenance->'source_rate_ids') = 2 \
                 FROM (SELECT fx_cross_rate('UAH/EUR', 'USD') AS x) values"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test]
    fn rounding_and_conversion_are_explicit() {
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT fx_round(1.245, 2, 'half_even') = 1.24 \
                        AND fx_round(1.255, 2, 'half_even') = 1.26 \
                        AND fx_convert(100, 'USD/EUR', 'sell_base', 0.851372941, 2) = 85.14 \
                        AND fx_convert('USD 100', 'EUR', 0.851372941, 2) = 'EUR 85.14'"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test]
    fn quotes_capture_rules_fees_spread_and_provenance() {
        seed_usd_eur();
        Spi::run("SELECT fx_rule_create('USD/EUR', 'retail', 0, 10000, 50, 5, 0);").unwrap();
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT input_asset = 'USD' AND output_asset = 'EUR' \
                        AND fee = 5 AND net_input_amount = 995 \
                        AND market_rate = 0.8510 \
                        AND customer_rate = 0.846745 \
                        AND output_amount = 842.51 \
                        AND spread_bps = 50 \
                        AND source_rate_id IS NOT NULL \
                        AND fx_quote_is_valid(id) \
                        AND fx_quote_ledger_metadata(id)->>'type' = 'fx_exchange' \
                 FROM fx_create_quote('USD/EUR', 'sell_base', 1000, 'retail')"
            )
            .unwrap(),
            Some(true)
        );
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT pair = 'USD/EUR'::fx_pair AND input_amount = 1000 \
                        AND customer_id = 'customer-2' \
                 FROM fx_create_quote(input => 'USD 1000', output_asset => 'EUR', \
                                      customer_id => 'customer-2')"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test]
    fn quote_state_transition_is_one_way() {
        seed_usd_eur();
        assert_eq!(
            Spi::get_one::<String>(
                "WITH q AS (SELECT (fx_create_quote('USD/EUR', 'sell_base', 100)).id AS id) \
                 SELECT (fx_execute_quote(id)).status::text FROM q"
            )
            .unwrap(),
            Some("executed".to_owned())
        );
    }

    #[pg_test]
    fn buy_base_quotes_use_ask_and_division() {
        Spi::run(
            "SELECT fx_source_upsert('crypto', 1, true, interval '1 minute'); \
             SELECT fx_rate_insert('crypto', 'BTC/USD', 99, 100); \
             SELECT fx_rule_create('BTC/USD', 'retail', 0, NULL, 100);",
        )
        .unwrap();
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT input_asset = 'USD' AND output_asset = 'BTC' \
                        AND market_rate = 100 AND customer_rate = 101 \
                        AND output_amount = 2 AND spread = 0.02 \
                 FROM fx_create_quote('BTC/USD', 'buy_base', 202, 'retail', \
                                      output_scale => 8)"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test]
    fn quotes_expire_at_the_boundary() {
        seed_usd_eur();
        Spi::run("SELECT fx_create_quote('USD/EUR', 'sell_base', 100, expires_in => interval '1 second')")
            .unwrap();
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT fx_expire_quote(id, expires_at) FROM fx_quotes ORDER BY created_at DESC LIMIT 1"
            )
            .unwrap(),
            Some(true)
        );
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT status = 'expired' AND NOT fx_quote_is_valid(id, expires_at) \
                 FROM fx_quotes ORDER BY created_at DESC LIMIT 1"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test]
    fn effective_status_and_bulk_expiry_do_not_leave_due_quotes_open() {
        seed_usd_eur();
        Spi::run(
            "SELECT fx_create_quote('USD/EUR', 'sell_base', 100, \
                                    expires_in => interval '1 second')",
        )
        .unwrap();
        assert_eq!(
            Spi::get_one::<i64>(
                "SELECT fx_expire_quotes(( \
                     SELECT expires_at FROM fx_quotes ORDER BY created_at DESC LIMIT 1 \
                 ))"
            )
            .unwrap(),
            Some(1)
        );
        assert_eq!(
            Spi::get_one::<bool>(
                "SELECT status = 'expired' \
                        AND fx_quote_effective_status(id, expires_at) = 'expired' \
                 FROM fx_quotes ORDER BY created_at DESC LIMIT 1"
            )
            .unwrap(),
            Some(true)
        );
    }

    #[pg_test(error = "fx quote pricing and provenance are immutable")]
    fn quote_prices_cannot_be_edited() {
        seed_usd_eur();
        Spi::run(
            "SELECT fx_create_quote('USD/EUR', 'sell_base', 100); \
             UPDATE fx_quotes SET output_amount = output_amount + 1;",
        )
        .unwrap();
    }
}
