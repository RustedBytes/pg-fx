-- fx_pair's generated operator classes are available at finalization time.
CREATE INDEX fx_rates_pair_observed_idx
    ON fx_rates (pair, observed_at DESC, received_at DESC, id DESC);
CREATE INDEX fx_rates_source_pair_observed_idx
    ON fx_rates (source_id, pair, observed_at DESC, received_at DESC, id DESC);
CREATE INDEX fx_quotes_pair_created_idx ON fx_quotes (pair, created_at DESC);
CREATE INDEX fx_rules_lookup_idx
    ON fx_rules (pair, customer_segment, priority, min_amount, valid_from, valid_to);

CREATE VIEW fx_current_rates AS
SELECT DISTINCT ON (r.pair)
    r.id,
    s.name AS source,
    r.pair,
    r.bid,
    r.ask,
    (r.bid + r.ask) / 2 AS mid,
    r.observed_at,
    r.received_at,
    COALESCE(r.max_age, s.max_age) AS max_age,
    clock_timestamp() - r.observed_at AS age,
    r.metadata
FROM fx_rates r
JOIN fx_sources s ON s.id = r.source_id
WHERE s.enabled
  AND r.observed_at <= clock_timestamp()
  AND r.received_at <= clock_timestamp()
  AND clock_timestamp() - r.observed_at <= COALESCE(r.max_age, s.max_age)
ORDER BY r.pair, s.priority, r.observed_at DESC, r.received_at DESC, r.id DESC;

CREATE VIEW fx_quote_details AS
SELECT q.*, (q.status = 'open' AND clock_timestamp() < q.expires_at) AS is_valid,
       s.name AS source_name
FROM fx_quotes q
JOIN fx_rates r ON r.id = q.source_rate_id
JOIN fx_sources s ON s.id = r.source_id;

CREATE VIEW fx_active_rules AS
SELECT *
FROM fx_rules
WHERE statement_timestamp() >= valid_from AND statement_timestamp() < valid_to;

COMMENT ON VIEW fx_current_rates IS 'Fresh primary/fallback rate selected by source priority';
COMMENT ON VIEW fx_quote_details IS 'Quotes with live validity and source provenance';
GRANT SELECT ON fx_current_rates, fx_quote_details, fx_active_rules TO PUBLIC;

-- Pin every extension function to the installation schema.  This makes custom
-- schema installs reliable and prevents caller-controlled search_path entries
-- from redirecting table or helper-function references.
DO $configure_search_paths$
DECLARE
    function_record record;
BEGIN
    FOR function_record IN
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS arguments
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = '@extschema@' AND p.proname LIKE 'fx\_%' ESCAPE '\'
    LOOP
        EXECUTE format(
            'ALTER FUNCTION %I.%I(%s) SET search_path TO %I, pg_catalog',
            '@extschema@', function_record.proname, function_record.arguments, '@extschema@'
        );
    END LOOP;
END
$configure_search_paths$;
