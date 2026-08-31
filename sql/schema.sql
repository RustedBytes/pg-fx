-- Core storage and deterministic pricing functions.  Market-data collection and
-- ledger posting intentionally remain outside this extension.

CREATE TABLE fx_sources (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE CHECK (
        name = lower(name) AND name ~ '^[a-z0-9][a-z0-9._-]{0,62}$'
    ),
    priority integer NOT NULL DEFAULT 100 CHECK (priority >= 0),
    enabled boolean NOT NULL DEFAULT true,
    max_age interval NOT NULL DEFAULT interval '30 seconds' CHECK (max_age > interval '0'),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp()
);

COMMENT ON TABLE fx_sources IS
    'Configured upstream market-data sources; the extension itself performs no network access';
COMMENT ON COLUMN fx_sources.priority IS 'Lower values are preferred';

CREATE FUNCTION fx_sources_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.updated_at := statement_timestamp();
    RETURN NEW;
END
$function$;

CREATE TRIGGER fx_sources_touch_updated_at
BEFORE UPDATE ON fx_sources
FOR EACH ROW EXECUTE FUNCTION fx_sources_touch_updated_at();

CREATE TABLE fx_rates (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_id bigint NOT NULL REFERENCES fx_sources(id),
    pair fx_pair NOT NULL,
    bid numeric NOT NULL CHECK (bid > 0),
    ask numeric NOT NULL CHECK (ask > 0),
    volume numeric CHECK (volume IS NULL OR volume > 0),
    observed_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    max_age interval CHECK (max_age IS NULL OR max_age > interval '0'),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    CHECK (bid <= ask)
);

COMMENT ON TABLE fx_rates IS 'Append-only normalized market observations with source provenance';
COMMENT ON COLUMN fx_rates.observed_at IS 'Time at which the upstream source says the rate applied';
COMMENT ON COLUMN fx_rates.received_at IS 'Time at which this database received the observation';
COMMENT ON COLUMN fx_rates.volume IS
    'Optional positive source volume used by weighted median and VWAP composites';

CREATE FUNCTION fx_rates_immutable_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'fx_rates rows are immutable'
        USING ERRCODE = '55000', HINT = 'Insert a new market observation.';
END
$function$;

CREATE TRIGGER fx_rates_immutable_update
BEFORE UPDATE OR DELETE ON fx_rates
FOR EACH ROW EXECUTE FUNCTION fx_rates_immutable_guard();

CREATE TABLE fx_rules (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pair fx_pair NOT NULL,
    customer_segment text NOT NULL DEFAULT 'retail' CHECK (
        customer_segment = lower(customer_segment)
        AND customer_segment ~ '^[a-z0-9][a-z0-9._-]{0,62}$'
    ),
    min_amount numeric NOT NULL DEFAULT 0 CHECK (min_amount >= 0),
    max_amount numeric CHECK (max_amount IS NULL OR max_amount > min_amount),
    markup_bps numeric NOT NULL DEFAULT 0 CHECK (markup_bps >= 0 AND markup_bps < 10000),
    fixed_fee numeric NOT NULL DEFAULT 0 CHECK (fixed_fee >= 0),
    percentage_fee numeric NOT NULL DEFAULT 0 CHECK (
        percentage_fee >= 0 AND percentage_fee < 100
    ),
    priority integer NOT NULL DEFAULT 100 CHECK (priority >= 0),
    valid_from timestamptz NOT NULL DEFAULT '-infinity',
    valid_to timestamptz NOT NULL DEFAULT 'infinity',
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    CHECK (valid_from < valid_to)
);

COMMENT ON TABLE fx_rules IS 'Data-driven customer markup and fee policy';
COMMENT ON COLUMN fx_rules.percentage_fee IS 'Percentage of input amount, where 0.5 means 0.5 percent';

CREATE SEQUENCE fx_quote_id_seq;

CREATE TABLE fx_quotes (
    id text PRIMARY KEY DEFAULT (
        'fxq_' || lpad(nextval('fx_quote_id_seq')::text, 20, '0')
    ) CHECK (id ~ '^fxq_[0-9]{20}$'),
    pair fx_pair NOT NULL,
    side fx_side NOT NULL,
    input_asset text NOT NULL,
    output_asset text NOT NULL,
    input_amount numeric NOT NULL CHECK (input_amount > 0),
    fee numeric NOT NULL DEFAULT 0 CHECK (fee >= 0 AND fee < input_amount),
    net_input_amount numeric NOT NULL CHECK (net_input_amount > 0),
    output_amount numeric NOT NULL CHECK (output_amount > 0),
    market_rate numeric NOT NULL CHECK (market_rate > 0),
    customer_rate numeric NOT NULL CHECK (customer_rate > 0),
    spread numeric NOT NULL DEFAULT 0 CHECK (spread >= 0),
    spread_bps numeric NOT NULL DEFAULT 0 CHECK (spread_bps >= 0),
    source_rate_id bigint NOT NULL REFERENCES fx_rates(id),
    rule_id bigint REFERENCES fx_rules(id),
    customer_id text,
    created_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    expires_at timestamptz NOT NULL,
    executed_at timestamptz,
    status_changed_at timestamptz,
    status fx_quote_status NOT NULL DEFAULT 'open',
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
    CHECK (expires_at > created_at),
    CHECK (status_changed_at IS NULL OR status_changed_at >= created_at),
    CHECK (executed_at IS NULL OR executed_at >= created_at),
    CHECK (net_input_amount = input_amount - fee),
    CHECK (
        (side = 'sell_base' AND input_asset = fx_pair_base(pair) AND output_asset = fx_pair_quote(pair))
        OR
        (side = 'buy_base' AND input_asset = fx_pair_quote(pair) AND output_asset = fx_pair_base(pair))
    ),
    CHECK (
        (status = 'executed' AND executed_at IS NOT NULL AND status_changed_at IS NOT NULL)
        OR
        (status IN ('expired', 'cancelled') AND executed_at IS NULL AND status_changed_at IS NOT NULL)
        OR
        (status = 'open' AND executed_at IS NULL AND status_changed_at IS NULL)
    )
);

COMMENT ON TABLE fx_quotes IS
    'Immutable pricing decisions; only one-way status transitions are permitted';

CREATE FUNCTION fx_quotes_immutable_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF ROW(
        NEW.id, NEW.pair::text, NEW.side::text, NEW.input_asset, NEW.output_asset,
        NEW.input_amount, NEW.fee, NEW.net_input_amount, NEW.output_amount,
        NEW.market_rate, NEW.customer_rate, NEW.spread, NEW.spread_bps,
        NEW.source_rate_id, NEW.rule_id, NEW.customer_id, NEW.created_at,
        NEW.expires_at, NEW.metadata
    ) IS DISTINCT FROM ROW(
        OLD.id, OLD.pair::text, OLD.side::text, OLD.input_asset, OLD.output_asset,
        OLD.input_amount, OLD.fee, OLD.net_input_amount, OLD.output_amount,
        OLD.market_rate, OLD.customer_rate, OLD.spread, OLD.spread_bps,
        OLD.source_rate_id, OLD.rule_id, OLD.customer_id, OLD.created_at,
        OLD.expires_at, OLD.metadata
    ) THEN
        RAISE EXCEPTION 'fx quote pricing and provenance are immutable'
            USING ERRCODE = '55000';
    END IF;

    IF OLD.status <> 'open' OR NEW.status NOT IN ('executed', 'expired', 'cancelled') THEN
        RAISE EXCEPTION 'invalid fx quote status transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = '22023';
    END IF;

    IF NEW.status_changed_at IS NULL THEN
        RAISE EXCEPTION 'status_changed_at is required for an fx quote transition'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.status = 'executed' AND NEW.executed_at IS NULL THEN
        RAISE EXCEPTION 'executed_at is required when executing an fx quote'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.status <> 'executed' AND NEW.executed_at IS NOT NULL THEN
        RAISE EXCEPTION 'executed_at is only valid for an executed fx quote'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;

CREATE TRIGGER fx_quotes_immutable_update
BEFORE UPDATE ON fx_quotes
FOR EACH ROW EXECUTE FUNCTION fx_quotes_immutable_guard();

CREATE FUNCTION fx_quotes_delete_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'fx_quotes rows are immutable'
        USING ERRCODE = '55000', HINT = 'Cancel or expire an open quote instead.';
END
$function$;

CREATE TRIGGER fx_quotes_immutable_delete
BEFORE DELETE ON fx_quotes
FOR EACH ROW EXECUTE FUNCTION fx_quotes_delete_guard();

CREATE TYPE fx_price_snapshot AS (
    pair fx_pair,
    bid numeric,
    ask numeric,
    observed_at timestamptz,
    received_at timestamptz,
    provenance jsonb
);

CREATE FUNCTION fx_source_upsert(
    source_name text,
    source_priority integer DEFAULT 100,
    source_enabled boolean DEFAULT true,
    source_max_age interval DEFAULT interval '30 seconds',
    source_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS fx_sources
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    result fx_sources;
BEGIN
    source_name := lower(btrim(source_name));
    INSERT INTO fx_sources(name, priority, enabled, max_age, metadata)
    VALUES (source_name, source_priority, source_enabled, source_max_age, source_metadata)
    ON CONFLICT (name) DO UPDATE SET
        priority = EXCLUDED.priority,
        enabled = EXCLUDED.enabled,
        max_age = EXCLUDED.max_age,
        metadata = EXCLUDED.metadata
    RETURNING * INTO result;
    RETURN result;
END
$function$;

CREATE FUNCTION fx_rate_insert(
    source text,
    rate_pair fx_pair,
    rate_bid numeric,
    rate_ask numeric,
    rate_observed_at timestamptz DEFAULT clock_timestamp(),
    rate_received_at timestamptz DEFAULT clock_timestamp(),
    rate_max_age interval DEFAULT NULL,
    rate_metadata jsonb DEFAULT '{}'::jsonb,
    rate_volume numeric DEFAULT NULL
)
RETURNS fx_rates
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    source_key bigint;
    result fx_rates;
BEGIN
    SELECT id INTO source_key FROM fx_sources WHERE name = lower(btrim(source)) AND enabled;
    IF source_key IS NULL THEN
        RAISE EXCEPTION 'unknown or disabled FX source: %', source
            USING ERRCODE = '22023', HINT = 'Register it with fx_source_upsert().';
    END IF;

    INSERT INTO fx_rates(
        source_id, pair, bid, ask, volume, observed_at, received_at, max_age, metadata
    )
    VALUES (
        source_key, rate_pair, rate_bid, rate_ask, rate_volume, rate_observed_at,
        rate_received_at, rate_max_age, rate_metadata
    )
    RETURNING * INTO result;
    RETURN result;
END
$function$;

CREATE FUNCTION fx_rate_latest(rate_pair fx_pair)
RETURNS fx_rates
LANGUAGE sql
STABLE
AS $function$
    SELECT r
    FROM fx_rates r
    JOIN fx_sources s ON s.id = r.source_id
    WHERE r.pair = rate_pair AND s.enabled
    ORDER BY r.observed_at DESC, r.received_at DESC, r.id DESC
    LIMIT 1
$function$;

CREATE FUNCTION fx_rate_current(rate_pair fx_pair, as_of timestamptz DEFAULT clock_timestamp())
RETURNS fx_rates
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    result fx_rates;
    newest fx_rates;
    newest_age interval;
    newest_max_age interval;
BEGIN
    SELECT (candidate).*
    INTO result
    FROM (
        SELECT DISTINCT ON (r.source_id) r AS candidate, s.priority
        FROM fx_rates r
        JOIN fx_sources s ON s.id = r.source_id
        WHERE r.pair = rate_pair
          AND s.enabled
          AND r.observed_at <= as_of
          AND r.received_at <= as_of
          AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
        ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
    ) fresh
    ORDER BY priority, (candidate).source_id
    LIMIT 1;

    IF result.id IS NOT NULL THEN
        RETURN result;
    END IF;

    SELECT r.*
    INTO newest
    FROM fx_rates r
    JOIN fx_sources s ON s.id = r.source_id
    WHERE r.pair = rate_pair AND s.enabled
      AND r.observed_at <= as_of AND r.received_at <= as_of
    ORDER BY r.observed_at DESC, r.received_at DESC, r.id DESC
    LIMIT 1;

    IF newest.id IS NULL THEN
        RAISE EXCEPTION 'no current FX rate for pair %', rate_pair
            USING ERRCODE = 'P0002';
    END IF;
    newest_age := as_of - newest.observed_at;
    SELECT COALESCE(newest.max_age, s.max_age) INTO newest_max_age
    FROM fx_sources s WHERE s.id = newest.source_id;
    RAISE EXCEPTION 'FX rate stale'
        USING ERRCODE = '55000',
              DETAIL = format('pair: %s, age: %s, maximum_age: %s',
                              rate_pair, newest_age, newest_max_age);
END
$function$;

CREATE FUNCTION fx_bid(rate_pair fx_pair, as_of timestamptz DEFAULT clock_timestamp())
RETURNS numeric LANGUAGE sql STABLE
AS 'SELECT (fx_rate_current(rate_pair, as_of)).bid';

CREATE FUNCTION fx_ask(rate_pair fx_pair, as_of timestamptz DEFAULT clock_timestamp())
RETURNS numeric LANGUAGE sql STABLE
AS 'SELECT (fx_rate_current(rate_pair, as_of)).ask';

CREATE FUNCTION fx_mid(rate_pair fx_pair, as_of timestamptz DEFAULT clock_timestamp())
RETURNS numeric LANGUAGE sql STABLE
AS 'SELECT ((fx_rate_current(rate_pair, as_of)).bid + (fx_rate_current(rate_pair, as_of)).ask) / 2';

CREATE FUNCTION fx_best_bid(rate_pair fx_pair, as_of timestamptz DEFAULT clock_timestamp())
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
    SELECT max(latest.bid)
    FROM (
        SELECT DISTINCT ON (r.source_id) r.bid
        FROM fx_rates r JOIN fx_sources s ON s.id = r.source_id
        WHERE r.pair = rate_pair AND s.enabled AND r.observed_at <= as_of
          AND r.received_at <= as_of
          AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
        ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
    ) latest
$function$;

CREATE FUNCTION fx_best_ask(rate_pair fx_pair, as_of timestamptz DEFAULT clock_timestamp())
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
    SELECT min(latest.ask)
    FROM (
        SELECT DISTINCT ON (r.source_id) r.ask
        FROM fx_rates r JOIN fx_sources s ON s.id = r.source_id
        WHERE r.pair = rate_pair AND s.enabled AND r.observed_at <= as_of
          AND r.received_at <= as_of
          AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
        ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
    ) latest
$function$;

CREATE FUNCTION fx_composite_rate(
    rate_pair fx_pair,
    strategy fx_rate_strategy DEFAULT 'priority',
    as_of timestamptz DEFAULT clock_timestamp()
)
RETURNS fx_price_snapshot
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    selected fx_rates;
    result fx_price_snapshot;
BEGIN
    IF strategy = 'latest' THEN
        SELECT candidates.* INTO selected
        FROM (
            SELECT DISTINCT ON (r.source_id) r.*
            FROM fx_rates r JOIN fx_sources s ON s.id = r.source_id
            WHERE r.pair = rate_pair AND s.enabled AND r.observed_at <= as_of
              AND r.received_at <= as_of
              AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
            ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
        ) candidates
        ORDER BY candidates.observed_at DESC, candidates.received_at DESC, candidates.id DESC
        LIMIT 1;
    ELSIF strategy = 'priority' THEN
        selected := fx_rate_current(rate_pair, as_of);
    ELSIF strategy = 'best_bid' THEN
        SELECT candidates.* INTO selected
        FROM (
            SELECT DISTINCT ON (r.source_id) r.*
            FROM fx_rates r JOIN fx_sources s ON s.id = r.source_id
            WHERE r.pair = rate_pair AND s.enabled AND r.observed_at <= as_of
              AND r.received_at <= as_of
              AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
            ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
        ) candidates
        ORDER BY candidates.bid DESC, candidates.ask, candidates.id
        LIMIT 1;
    ELSIF strategy = 'best_ask' THEN
        SELECT candidates.* INTO selected
        FROM (
            SELECT DISTINCT ON (r.source_id) r.*
            FROM fx_rates r JOIN fx_sources s ON s.id = r.source_id
            WHERE r.pair = rate_pair AND s.enabled AND r.observed_at <= as_of
              AND r.received_at <= as_of
              AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
            ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
        ) candidates
        ORDER BY candidates.ask, candidates.bid DESC, candidates.id
        LIMIT 1;
    ELSIF strategy = 'median' THEN
        SELECT
            percentile_disc(0.5) WITHIN GROUP (ORDER BY candidates.bid),
            percentile_disc(0.5) WITHIN GROUP (ORDER BY candidates.ask),
            min(candidates.observed_at),
            max(candidates.received_at),
            jsonb_build_object(
                'strategy', 'median',
                'source_rate_ids', jsonb_agg(candidates.id ORDER BY candidates.id)
            )
        INTO result.bid, result.ask, result.observed_at, result.received_at, result.provenance
        FROM (
            SELECT DISTINCT ON (r.source_id) r.*
            FROM fx_rates r JOIN fx_sources s ON s.id = r.source_id
            WHERE r.pair = rate_pair AND s.enabled AND r.observed_at <= as_of
              AND r.received_at <= as_of
              AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
            ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
        ) candidates;
        IF result.bid IS NULL THEN
            PERFORM fx_rate_current(rate_pair, as_of);
        END IF;
        result.pair := rate_pair;
        RETURN result;
    ELSIF strategy = 'weighted_median' THEN
        WITH candidates AS MATERIALIZED (
            SELECT DISTINCT ON (r.source_id) r.*
            FROM fx_rates r JOIN fx_sources s ON s.id = r.source_id
            WHERE r.pair = rate_pair AND s.enabled AND r.observed_at <= as_of
              AND r.received_at <= as_of
              AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
              AND r.volume IS NOT NULL
            ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
        ), weighted_bid AS (
            SELECT bid
            FROM (
                SELECT bid, id,
                       sum(volume) OVER (ORDER BY bid, id) AS cumulative,
                       sum(volume) OVER () AS total
                FROM candidates
            ) weighted
            WHERE cumulative >= total / 2
            ORDER BY bid, id
            LIMIT 1
        ), weighted_ask AS (
            SELECT ask
            FROM (
                SELECT ask, id,
                       sum(volume) OVER (ORDER BY ask, id) AS cumulative,
                       sum(volume) OVER () AS total
                FROM candidates
            ) weighted
            WHERE cumulative >= total / 2
            ORDER BY ask, id
            LIMIT 1
        )
        SELECT weighted_bid.bid, weighted_ask.ask,
               min(candidates.observed_at), max(candidates.received_at),
               jsonb_build_object(
                   'strategy', 'weighted_median',
                   'weight', 'volume',
                   'source_rate_ids', jsonb_agg(candidates.id ORDER BY candidates.id)
               )
        INTO result.bid, result.ask, result.observed_at, result.received_at, result.provenance
        FROM candidates CROSS JOIN weighted_bid CROSS JOIN weighted_ask
        GROUP BY weighted_bid.bid, weighted_ask.ask;
        IF result.bid IS NULL THEN
            RAISE EXCEPTION 'weighted median requires a fresh rate with volume for pair %', rate_pair
                USING ERRCODE = 'P0002';
        END IF;
        result.pair := rate_pair;
        RETURN result;
    ELSIF strategy = 'vwap' THEN
        SELECT
            sum(candidates.bid * candidates.volume) / sum(candidates.volume),
            sum(candidates.ask * candidates.volume) / sum(candidates.volume),
            min(candidates.observed_at),
            max(candidates.received_at),
            jsonb_build_object(
                'strategy', 'vwap',
                'weight', 'volume',
                'total_volume', sum(candidates.volume),
                'source_rate_ids', jsonb_agg(candidates.id ORDER BY candidates.id)
            )
        INTO result.bid, result.ask, result.observed_at, result.received_at, result.provenance
        FROM (
            SELECT DISTINCT ON (r.source_id) r.*
            FROM fx_rates r JOIN fx_sources s ON s.id = r.source_id
            WHERE r.pair = rate_pair AND s.enabled AND r.observed_at <= as_of
              AND r.received_at <= as_of
              AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
              AND r.volume IS NOT NULL
            ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
        ) candidates;
        IF result.bid IS NULL THEN
            RAISE EXCEPTION 'VWAP requires a fresh rate with volume for pair %', rate_pair
                USING ERRCODE = 'P0002';
        END IF;
        result.pair := rate_pair;
        RETURN result;
    ELSIF strategy = 'trimmed_mean' THEN
        WITH candidates AS MATERIALIZED (
            SELECT DISTINCT ON (r.source_id) r.*
            FROM fx_rates r JOIN fx_sources s ON s.id = r.source_id
            WHERE r.pair = rate_pair AND s.enabled AND r.observed_at <= as_of
              AND r.received_at <= as_of
              AND as_of - r.observed_at <= COALESCE(r.max_age, s.max_age)
            ORDER BY r.source_id, r.observed_at DESC, r.received_at DESC, r.id DESC
        ), ranked AS (
            SELECT candidates.*,
                   row_number() OVER (ORDER BY (bid + ask) / 2, id) AS rank,
                   count(*) OVER () AS candidate_count
            FROM candidates
        ), included AS (
            SELECT *
            FROM ranked
            WHERE rank > floor(candidate_count * 0.1)
              AND rank <= candidate_count - floor(candidate_count * 0.1)
        )
        SELECT avg(included.bid), avg(included.ask),
               min(included.observed_at), max(included.received_at),
               jsonb_build_object(
                   'strategy', 'trimmed_mean',
                   'trim_fraction', 0.1,
                   'source_rate_ids', jsonb_agg(included.id ORDER BY included.id)
               )
        INTO result.bid, result.ask, result.observed_at, result.received_at, result.provenance
        FROM included;
        IF result.bid IS NULL THEN
            PERFORM fx_rate_current(rate_pair, as_of);
        END IF;
        result.pair := rate_pair;
        RETURN result;
    ELSE
        RAISE EXCEPTION 'unsupported FX rate strategy: %', strategy USING ERRCODE = '22023';
    END IF;

    IF selected.id IS NULL THEN
        PERFORM fx_rate_current(rate_pair, as_of);
    END IF;
    result.pair := rate_pair;
    result.bid := selected.bid;
    result.ask := selected.ask;
    result.observed_at := selected.observed_at;
    result.received_at := selected.received_at;
    result.provenance := jsonb_build_object(
        'strategy', strategy::text,
        'source_rate_ids', jsonb_build_array(selected.id)
    );
    RETURN result;
END
$function$;

CREATE FUNCTION fx_weighted_median(
    rate_pair fx_pair,
    as_of timestamptz DEFAULT clock_timestamp()
)
RETURNS fx_price_snapshot
LANGUAGE sql
STABLE
AS 'SELECT fx_composite_rate(rate_pair, ''weighted_median'', as_of)';

CREATE FUNCTION fx_vwap(
    rate_pair fx_pair,
    as_of timestamptz DEFAULT clock_timestamp()
)
RETURNS fx_price_snapshot
LANGUAGE sql
STABLE
AS 'SELECT fx_composite_rate(rate_pair, ''vwap'', as_of)';

CREATE FUNCTION fx_trimmed_mean(
    rate_pair fx_pair,
    as_of timestamptz DEFAULT clock_timestamp()
)
RETURNS fx_price_snapshot
LANGUAGE sql
STABLE
AS 'SELECT fx_composite_rate(rate_pair, ''trimmed_mean'', as_of)';

CREATE FUNCTION fx_inverse(rate_pair fx_pair, rate_bid numeric, rate_ask numeric)
RETURNS fx_price_snapshot
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $function$
DECLARE
    result fx_price_snapshot;
BEGIN
    IF rate_bid <= 0 OR rate_ask <= 0 OR rate_bid > rate_ask THEN
        RAISE EXCEPTION 'inverse requires positive bid <= ask' USING ERRCODE = '22023';
    END IF;
    result.pair := fx_pair(fx_pair_quote(rate_pair), fx_pair_base(rate_pair));
    result.bid := 1 / rate_ask;
    result.ask := 1 / rate_bid;
    result.provenance := jsonb_build_object('derived', 'inverse', 'input_pair', rate_pair::text);
    RETURN result;
END
$function$;

CREATE FUNCTION fx_inverse(rate_pair fx_pair, as_of timestamptz DEFAULT clock_timestamp())
RETURNS fx_price_snapshot
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    source_rate fx_rates;
    result fx_price_snapshot;
BEGIN
    source_rate := fx_rate_current(rate_pair, as_of);
    result := fx_inverse(rate_pair, source_rate.bid, source_rate.ask);
    result.observed_at := source_rate.observed_at;
    result.received_at := source_rate.received_at;
    result.provenance := result.provenance || jsonb_build_object('source_rate_id', source_rate.id);
    RETURN result;
END
$function$;

CREATE FUNCTION fx_cross_rate(
    target_pair fx_pair,
    via text,
    as_of timestamptz DEFAULT clock_timestamp()
)
RETURNS fx_price_snapshot
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    first_pair fx_pair;
    second_pair fx_pair;
    first_rate fx_rates;
    second_rate fx_rates;
    result fx_price_snapshot;
BEGIN
    first_pair := fx_pair(fx_pair_base(target_pair), via);
    second_pair := fx_pair(via, fx_pair_quote(target_pair));
    first_rate := fx_rate_current(first_pair, as_of);
    second_rate := fx_rate_current(second_pair, as_of);

    result.pair := target_pair;
    result.bid := first_rate.bid * second_rate.bid;
    result.ask := first_rate.ask * second_rate.ask;
    result.observed_at := LEAST(first_rate.observed_at, second_rate.observed_at);
    result.received_at := GREATEST(first_rate.received_at, second_rate.received_at);
    result.provenance := jsonb_build_object(
        'derived', 'cross', 'via', via,
        'source_rate_ids', jsonb_build_array(first_rate.id, second_rate.id)
    );
    RETURN result;
END
$function$;

CREATE FUNCTION fx_spread_bps(rate_bid numeric, rate_ask numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $function$
BEGIN
    IF rate_bid <= 0 OR rate_ask <= 0 OR rate_bid > rate_ask THEN
        RAISE EXCEPTION 'spread requires positive bid <= ask' USING ERRCODE = '22023';
    END IF;
    RETURN (rate_ask - rate_bid) / ((rate_bid + rate_ask) / 2) * 10000;
END
$function$;

CREATE FUNCTION fx_spread_bps(rate_pair fx_pair, as_of timestamptz DEFAULT clock_timestamp())
RETURNS numeric LANGUAGE sql STABLE
AS 'SELECT fx_spread_bps((fx_rate_current(rate_pair, as_of)).bid, (fx_rate_current(rate_pair, as_of)).ask)';

CREATE FUNCTION fx_round(value numeric, scale integer, mode fx_rounding_mode DEFAULT 'half_even')
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $function$
DECLARE
    factor numeric;
    magnitude numeric;
    lower_value numeric;
    fraction numeric;
    rounded numeric;
BEGIN
    IF scale < 0 OR scale > 255 THEN
        RAISE EXCEPTION 'rounding scale must be between 0 and 255' USING ERRCODE = '22023';
    END IF;
    factor := power(10::numeric, scale);
    magnitude := abs(value) * factor;
    lower_value := trunc(magnitude);
    fraction := magnitude - lower_value;

    CASE mode
        WHEN 'down' THEN rounded := lower_value;
        WHEN 'up' THEN rounded := CASE WHEN fraction = 0 THEN lower_value ELSE lower_value + 1 END;
        WHEN 'half_up' THEN rounded := CASE WHEN fraction >= 0.5 THEN lower_value + 1 ELSE lower_value END;
        WHEN 'half_even' THEN
            rounded := CASE
                WHEN fraction > 0.5 OR (fraction = 0.5 AND mod(lower_value, 2) = 1)
                    THEN lower_value + 1
                ELSE lower_value
            END;
    END CASE;
    RETURN sign(value) * rounded / factor;
END
$function$;

CREATE FUNCTION fx_convert(
    amount numeric,
    rate_pair fx_pair,
    side fx_side,
    rate numeric,
    output_scale integer DEFAULT 2,
    rounding fx_rounding_mode DEFAULT 'half_even'
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $function$
BEGIN
    IF amount < 0 THEN
        RAISE EXCEPTION 'conversion amount cannot be negative' USING ERRCODE = '22023';
    END IF;
    IF rate <= 0 THEN
        RAISE EXCEPTION 'conversion rate must be positive' USING ERRCODE = '22023';
    END IF;
    IF side = 'sell_base' THEN
        RETURN fx_round(amount * rate, output_scale, rounding);
    END IF;
    RETURN fx_round(amount / rate, output_scale, rounding);
END
$function$;

CREATE FUNCTION fx_convert(
    input text,
    output_asset text,
    rate numeric,
    output_scale integer DEFAULT 2,
    rounding fx_rounding_mode DEFAULT 'half_even'
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $function$
DECLARE
    pieces text[];
    input_asset text;
    amount numeric;
    result numeric;
BEGIN
    pieces := regexp_match(btrim(input), '^([A-Za-z0-9._@:-]+)[[:space:]]+([+]?[0-9]+(?:[.][0-9]+)?)$');
    IF pieces IS NULL THEN
        pieces := regexp_match(btrim(input), '^([+]?[0-9]+(?:[.][0-9]+)?)[[:space:]]+([A-Za-z0-9._@:-]+)$');
        IF pieces IS NULL THEN
            RAISE EXCEPTION 'input amount must use ASSET 100 or 100 ASSET syntax' USING ERRCODE = '22023';
        END IF;
        amount := pieces[1]::numeric;
        input_asset := pieces[2];
    ELSE
        input_asset := pieces[1];
        amount := pieces[2]::numeric;
    END IF;
    result := fx_convert(amount, fx_pair(input_asset, output_asset), 'sell_base', rate,
                         output_scale, rounding);
    RETURN fx_pair_quote(fx_pair(input_asset, output_asset)) || ' ' || trim_scale(result)::text;
END
$function$;

CREATE FUNCTION fx_rule_create(
    rule_pair fx_pair,
    segment text DEFAULT 'retail',
    minimum numeric DEFAULT 0,
    maximum numeric DEFAULT NULL,
    markup numeric DEFAULT 0,
    fixed numeric DEFAULT 0,
    percentage numeric DEFAULT 0,
    rule_priority integer DEFAULT 100,
    starts_at timestamptz DEFAULT '-infinity',
    ends_at timestamptz DEFAULT 'infinity',
    rule_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS fx_rules
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    result fx_rules;
BEGIN
    INSERT INTO fx_rules(
        pair, customer_segment, min_amount, max_amount, markup_bps,
        fixed_fee, percentage_fee, priority, valid_from, valid_to, metadata
    ) VALUES (
        rule_pair, lower(btrim(segment)), minimum, maximum, markup,
        fixed, percentage, rule_priority, starts_at, ends_at, rule_metadata
    ) RETURNING * INTO result;
    RETURN result;
END
$function$;

CREATE FUNCTION fx_create_quote(
    rate_pair fx_pair,
    quote_side fx_side,
    amount numeric,
    customer_segment text DEFAULT 'retail',
    customer_id text DEFAULT NULL,
    expires_in interval DEFAULT interval '30 seconds',
    output_scale integer DEFAULT 2,
    rounding fx_rounding_mode DEFAULT 'half_even',
    quote_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS fx_quotes
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    chosen_rate fx_rates;
    chosen_rule fx_rules;
    market numeric;
    customer numeric;
    charged_fee numeric;
    net_input numeric;
    market_output numeric;
    customer_output numeric;
    result fx_quotes;
BEGIN
    IF amount <= 0 THEN
        RAISE EXCEPTION 'quote input amount must be positive' USING ERRCODE = '22023';
    END IF;
    IF expires_in <= interval '0' THEN
        RAISE EXCEPTION 'quote expiry interval must be positive' USING ERRCODE = '22023';
    END IF;

    chosen_rate := fx_rate_current(rate_pair);
    SELECT r.* INTO chosen_rule
    FROM fx_rules r
    WHERE r.pair = rate_pair
      AND r.customer_segment = lower(btrim($4))
      AND amount >= r.min_amount
      AND (r.max_amount IS NULL OR amount < r.max_amount)
      AND statement_timestamp() >= r.valid_from
      AND statement_timestamp() < r.valid_to
    ORDER BY r.priority, r.min_amount DESC, r.id DESC
    LIMIT 1;

    charged_fee := COALESCE(chosen_rule.fixed_fee, 0)
        + amount * COALESCE(chosen_rule.percentage_fee, 0) / 100;
    net_input := amount - charged_fee;
    IF net_input <= 0 THEN
        RAISE EXCEPTION 'pricing rule fees consume the entire input amount' USING ERRCODE = '22023';
    END IF;

    IF quote_side = 'sell_base' THEN
        market := chosen_rate.bid;
        customer := market * (1 - COALESCE(chosen_rule.markup_bps, 0) / 10000);
        market_output := net_input * market;
        customer_output := fx_round(net_input * customer, output_scale, rounding);
    ELSE
        market := chosen_rate.ask;
        customer := market * (1 + COALESCE(chosen_rule.markup_bps, 0) / 10000);
        market_output := net_input / market;
        customer_output := fx_round(net_input / customer, output_scale, rounding);
    END IF;
    IF customer <= 0 OR customer_output <= 0 THEN
        RAISE EXCEPTION 'pricing rule produces a non-positive customer quote' USING ERRCODE = '22023';
    END IF;

    INSERT INTO fx_quotes(
        pair, side, input_asset, output_asset, input_amount, fee,
        net_input_amount, output_amount, market_rate, customer_rate,
        spread, spread_bps, source_rate_id, rule_id, customer_id,
        expires_at, metadata
    ) VALUES (
        rate_pair, quote_side,
        CASE WHEN quote_side = 'sell_base' THEN fx_pair_base(rate_pair) ELSE fx_pair_quote(rate_pair) END,
        CASE WHEN quote_side = 'sell_base' THEN fx_pair_quote(rate_pair) ELSE fx_pair_base(rate_pair) END,
        amount, charged_fee, net_input, customer_output, market, customer,
        GREATEST(market_output - customer_output, 0),
        COALESCE(chosen_rule.markup_bps, 0), chosen_rate.id, chosen_rule.id,
        customer_id, statement_timestamp() + expires_in, quote_metadata
    ) RETURNING * INTO result;
    RETURN result;
END
$function$;

CREATE FUNCTION fx_create_quote(
    input text,
    output_asset text,
    customer_id text DEFAULT NULL,
    customer_segment text DEFAULT 'retail',
    expires_in interval DEFAULT interval '30 seconds',
    output_scale integer DEFAULT 2,
    rounding fx_rounding_mode DEFAULT 'half_even',
    quote_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS fx_quotes
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    pieces text[];
    input_asset text;
    amount numeric;
BEGIN
    pieces := regexp_match(
        btrim(input),
        '^([A-Za-z0-9._@:-]+)[[:space:]]+([+]?[0-9]+(?:[.][0-9]+)?)$'
    );
    IF pieces IS NULL THEN
        pieces := regexp_match(
            btrim(input),
            '^([+]?[0-9]+(?:[.][0-9]+)?)[[:space:]]+([A-Za-z0-9._@:-]+)$'
        );
        IF pieces IS NULL THEN
            RAISE EXCEPTION 'input amount must use ASSET 100 or 100 ASSET syntax'
                USING ERRCODE = '22023';
        END IF;
        amount := pieces[1]::numeric;
        input_asset := pieces[2];
    ELSE
        input_asset := pieces[1];
        amount := pieces[2]::numeric;
    END IF;

    RETURN fx_create_quote(
        fx_pair(input_asset, output_asset),
        'sell_base',
        amount,
        customer_segment,
        customer_id,
        expires_in,
        output_scale,
        rounding,
        quote_metadata
    );
END
$function$;

CREATE FUNCTION fx_get_quote(quote_id text)
RETURNS fx_quotes
LANGUAGE sql
STABLE
AS 'SELECT q FROM fx_quotes q WHERE q.id = quote_id';

CREATE FUNCTION fx_quote_is_valid(quote_id text, as_of timestamptz DEFAULT clock_timestamp())
RETURNS boolean
LANGUAGE sql
VOLATILE
AS 'SELECT COALESCE((SELECT status = ''open'' AND as_of < expires_at FROM fx_quotes WHERE id = quote_id), false)';

CREATE FUNCTION fx_quote_effective_status(
    quote_id text,
    as_of timestamptz DEFAULT clock_timestamp()
)
RETURNS fx_quote_status
LANGUAGE sql
VOLATILE
AS $function$
    SELECT CASE
        WHEN status = 'open' AND as_of >= expires_at THEN 'expired'::fx_quote_status
        ELSE status
    END
    FROM fx_quotes
    WHERE id = quote_id
$function$;

CREATE FUNCTION fx_expire_quote(quote_id text, as_of timestamptz DEFAULT clock_timestamp())
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $function$
BEGIN
    UPDATE fx_quotes
    SET status = 'expired', status_changed_at = as_of
    WHERE id = quote_id AND status = 'open' AND expires_at <= as_of;
    RETURN FOUND;
END
$function$;

CREATE FUNCTION fx_expire_quotes(as_of timestamptz DEFAULT clock_timestamp())
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    expired_count bigint;
BEGIN
    UPDATE fx_quotes
    SET status = 'expired', status_changed_at = as_of
    WHERE status = 'open' AND expires_at <= as_of;
    GET DIAGNOSTICS expired_count = ROW_COUNT;
    RETURN expired_count;
END
$function$;

CREATE FUNCTION fx_execute_quote(quote_id text, executed_time timestamptz DEFAULT clock_timestamp())
RETURNS fx_quotes
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    result fx_quotes;
BEGIN
    UPDATE fx_quotes
    SET status = 'executed', executed_at = executed_time, status_changed_at = executed_time
    WHERE id = quote_id AND status = 'open' AND executed_time < expires_at
    RETURNING * INTO result;
    IF result.id IS NULL THEN
        IF EXISTS (SELECT 1 FROM fx_quotes WHERE id = quote_id AND status = 'open' AND executed_time >= expires_at) THEN
            RAISE EXCEPTION 'FX quote % has expired', quote_id USING ERRCODE = '55000';
        END IF;
        RAISE EXCEPTION 'FX quote % is missing or not open', quote_id USING ERRCODE = '55000';
    END IF;
    RETURN result;
END
$function$;

CREATE FUNCTION fx_cancel_quote(quote_id text, cancelled_time timestamptz DEFAULT clock_timestamp())
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $function$
BEGIN
    UPDATE fx_quotes
    SET status = 'expired', status_changed_at = cancelled_time
    WHERE id = quote_id AND status = 'open' AND expires_at <= cancelled_time;
    IF FOUND THEN
        RETURN false;
    END IF;

    UPDATE fx_quotes
    SET status = 'cancelled', status_changed_at = cancelled_time
    WHERE id = quote_id AND status = 'open' AND cancelled_time < expires_at;
    RETURN FOUND;
END
$function$;

CREATE FUNCTION fx_quote_ledger_metadata(quote_id text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'type', 'fx_exchange',
        'quote_id', q.id,
        'pair', q.pair::text,
        'side', q.side::text,
        'input_asset', q.input_asset,
        'input_amount', q.input_amount,
        'output_asset', q.output_asset,
        'output_amount', q.output_amount,
        'fee', q.fee,
        'market_rate', q.market_rate,
        'customer_rate', q.customer_rate,
        'spread', q.spread,
        'spread_bps', q.spread_bps,
        'source', s.name,
        'source_rate_id', r.id,
        'rate_observed_at', r.observed_at,
        'quote_created_at', q.created_at,
        'quote_expires_at', q.expires_at
    ) INTO result
    FROM fx_quotes q
    JOIN fx_rates r ON r.id = q.source_rate_id
    JOIN fx_sources s ON s.id = r.source_id
    WHERE q.id = quote_id;

    IF result IS NULL THEN
        RAISE EXCEPTION 'unknown FX quote: %', quote_id USING ERRCODE = 'P0002';
    END IF;
    RETURN result;
END
$function$;

CREATE FUNCTION fx_validate()
RETURNS TABLE(check_name text, valid boolean, details jsonb)
LANGUAGE sql
STABLE
AS $function$
    SELECT 'market_spreads', count(*) = 0,
           jsonb_build_object('invalid_rows', count(*))
    FROM fx_rates WHERE bid <= 0 OR ask <= 0 OR bid > ask
    UNION ALL
    SELECT 'market_volumes', count(*) = 0,
           jsonb_build_object('invalid_rows', count(*))
    FROM fx_rates WHERE volume IS NOT NULL AND volume <= 0
    UNION ALL
    SELECT 'quote_provenance', count(*) = 0,
           jsonb_build_object('invalid_rows', count(*))
    FROM fx_quotes q LEFT JOIN fx_rates r ON r.id = q.source_rate_id
    WHERE r.id IS NULL
    UNION ALL
    SELECT 'quote_amounts', count(*) = 0,
           jsonb_build_object('invalid_rows', count(*))
    FROM fx_quotes
    WHERE input_amount <= 0 OR output_amount <= 0 OR fee < 0
$function$;

CREATE FUNCTION fx_enable_cross_asset_quotes()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    fx_schema name;
    money_schema name;
    crypto_schema name;
BEGIN
    SELECT n.nspname INTO fx_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_fx';
    SELECT n.nspname INTO money_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_money';
    SELECT n.nspname INTO crypto_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_cryptocurrency';

    IF fx_schema IS NULL OR money_schema IS NULL OR crypto_schema IS NULL
       OR to_regtype(format('%I.money_with_currency', money_schema)) IS NULL
       OR to_regtype(format('%I.crypto_amount', crypto_schema)) IS NULL
       OR to_regtype(format('%I.crypto_asset', crypto_schema)) IS NULL
       OR to_regprocedure(format(
              '%I.money_amount(%I.money_with_currency)', money_schema, money_schema
          )) IS NULL
       OR to_regprocedure(format(
              '%I.money_currency(%I.money_with_currency)', money_schema, money_schema
          )) IS NULL
       OR to_regprocedure(format('%I.money_make(numeric,text)', money_schema)) IS NULL
       OR to_regprocedure(format('%I.money_currency_info(text)', money_schema)) IS NULL
       OR to_regprocedure(format(
              '%I.crypto_amount_value(%I.crypto_amount)', crypto_schema, crypto_schema
          )) IS NULL
       OR to_regprocedure(format(
              '%I.crypto_amount_asset(%I.crypto_amount)', crypto_schema, crypto_schema
          )) IS NULL
       OR to_regprocedure(format(
              '%I.crypto_asset_decimals(%I.crypto_asset)', crypto_schema, crypto_schema
          )) IS NULL THEN
        RETURN false;
    END IF;

    EXECUTE format(
        $adapter$
        CREATE OR REPLACE FUNCTION %1$I.fx_create_quote(
            input %2$I.money_with_currency,
            output_asset %3$I.crypto_asset,
            customer_id text DEFAULT NULL,
            customer_segment text DEFAULT 'retail',
            expires_in interval DEFAULT interval '30 seconds',
            rounding %1$I.fx_rounding_mode DEFAULT 'half_even',
            quote_metadata jsonb DEFAULT '{}'::jsonb
        ) RETURNS %1$I.fx_quotes
        LANGUAGE plpgsql VOLATILE
        SET search_path = %1$I, %2$I, %3$I, pg_catalog
        AS $body$
        BEGIN
            RETURN %1$I.fx_create_quote(
                %1$I.fx_pair(%2$I.money_currency(input), output_asset::text),
                'sell_base'::%1$I.fx_side,
                %2$I.money_amount(input),
                customer_segment,
                customer_id,
                expires_in,
                %3$I.crypto_asset_decimals(output_asset),
                rounding,
                quote_metadata
            );
        END
        $body$
        $adapter$,
        fx_schema, money_schema, crypto_schema
    );

    EXECUTE format(
        $adapter$
        CREATE OR REPLACE FUNCTION %1$I.fx_create_quote(
            input %3$I.crypto_amount,
            output_currency text,
            customer_id text DEFAULT NULL,
            customer_segment text DEFAULT 'retail',
            expires_in interval DEFAULT interval '30 seconds',
            rounding %1$I.fx_rounding_mode DEFAULT 'half_even',
            quote_metadata jsonb DEFAULT '{}'::jsonb
        ) RETURNS %1$I.fx_quotes
        LANGUAGE plpgsql VOLATILE
        SET search_path = %1$I, %2$I, %3$I, pg_catalog
        AS $body$
        DECLARE
            canonical_output text;
            output_scale integer;
        BEGIN
            canonical_output := %2$I.money_currency(%2$I.money_make(0, output_currency));
            output_scale := (%2$I.money_currency_info(canonical_output)->>'exponent')::integer;
            RETURN %1$I.fx_create_quote(
                %1$I.fx_pair(%3$I.crypto_amount_asset(input)::text, canonical_output),
                'sell_base'::%1$I.fx_side,
                %3$I.crypto_amount_value(input),
                customer_segment,
                customer_id,
                expires_in,
                output_scale,
                rounding,
                quote_metadata
            );
        END
        $body$
        $adapter$,
        fx_schema, money_schema, crypto_schema
    );
    RETURN true;
END
$function$;

CREATE FUNCTION fx_enable_pg_money()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    fx_schema name;
    money_schema name;
BEGIN
    SELECT n.nspname INTO fx_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_fx';
    SELECT n.nspname INTO money_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_money';

    IF fx_schema IS NULL OR money_schema IS NULL
       OR to_regtype(format('%I.money_with_currency', money_schema)) IS NULL
       OR to_regprocedure(format(
              '%I.money_exchange(%I.money_with_currency,text,numeric)',
              money_schema, money_schema
          )) IS NULL
       OR to_regprocedure(format(
              '%I.money_amount(%I.money_with_currency)', money_schema, money_schema
          )) IS NULL
       OR to_regprocedure(format(
              '%I.money_currency(%I.money_with_currency)', money_schema, money_schema
          )) IS NULL
       OR to_regprocedure(format('%I.money_make(numeric,text)', money_schema)) IS NULL
       OR to_regprocedure(format('%I.money_currency_info(text)', money_schema)) IS NULL THEN
        RETURN false;
    END IF;

    EXECUTE format(
        $adapter$
        CREATE OR REPLACE FUNCTION %I.fx_convert(
            value %I.money_with_currency,
            output_currency text,
            rate numeric
        ) RETURNS %I.money_with_currency
        LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
        SET search_path = %I, %I, pg_catalog
        AS 'SELECT %I.money_exchange($1, $2, $3)'
        $adapter$,
        fx_schema, money_schema, money_schema,
        fx_schema, money_schema, money_schema
    );
    EXECUTE format(
        $adapter$
        CREATE OR REPLACE FUNCTION %1$I.fx_create_quote(
            input %2$I.money_with_currency,
            output_currency text,
            customer_id text DEFAULT NULL,
            customer_segment text DEFAULT 'retail',
            expires_in interval DEFAULT interval '30 seconds',
            rounding %1$I.fx_rounding_mode DEFAULT 'half_even',
            quote_metadata jsonb DEFAULT '{}'::jsonb
        ) RETURNS %1$I.fx_quotes
        LANGUAGE plpgsql VOLATILE
        SET search_path = %1$I, %2$I, pg_catalog
        AS $body$
        DECLARE
            canonical_output text;
            output_scale integer;
        BEGIN
            canonical_output := %2$I.money_currency(%2$I.money_make(0, output_currency));
            output_scale := (%2$I.money_currency_info(canonical_output)->>'exponent')::integer;
            RETURN %1$I.fx_create_quote(
                %1$I.fx_pair(%2$I.money_currency(input), canonical_output),
                'sell_base'::%1$I.fx_side,
                %2$I.money_amount(input),
                customer_segment,
                customer_id,
                expires_in,
                output_scale,
                rounding,
                quote_metadata
            );
        END
        $body$
        $adapter$,
        fx_schema, money_schema
    );
    PERFORM fx_enable_cross_asset_quotes();
    RETURN true;
END
$function$;

CREATE FUNCTION fx_enable_pg_cryptocurrency()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    fx_schema name;
    crypto_schema name;
BEGIN
    SELECT n.nspname INTO fx_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_fx';
    SELECT n.nspname INTO crypto_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_cryptocurrency';

    IF fx_schema IS NULL OR crypto_schema IS NULL
       OR to_regtype(format('%I.crypto_amount', crypto_schema)) IS NULL
       OR to_regtype(format('%I.crypto_asset', crypto_schema)) IS NULL
       OR to_regprocedure(format('%I.crypto_make(numeric,text)', crypto_schema)) IS NULL
       OR to_regprocedure(format(
              '%I.crypto_amount_value(%I.crypto_amount)', crypto_schema, crypto_schema
          )) IS NULL
       OR to_regprocedure(format(
              '%I.crypto_amount_asset(%I.crypto_amount)', crypto_schema, crypto_schema
          )) IS NULL
       OR to_regprocedure(format(
              '%I.crypto_asset_decimals(%I.crypto_asset)', crypto_schema, crypto_schema
          )) IS NULL THEN
        RETURN false;
    END IF;

    EXECUTE format(
        $adapter$
        CREATE OR REPLACE FUNCTION %I.fx_convert(
            value %I.crypto_amount,
            output_asset text,
            rate numeric,
            rounding %I.fx_rounding_mode DEFAULT 'half_even'
        ) RETURNS %I.crypto_amount
        LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
        SET search_path = %I, %I, pg_catalog
        AS 'SELECT %I.crypto_make(
                %I.fx_round(
                    %I.crypto_amount_value($1) * $3,
                    %I.crypto_asset_decimals($2::%I.crypto_asset),
                    $4
                ),
                $2
            )'
        $adapter$,
        fx_schema, crypto_schema, fx_schema, crypto_schema,
        fx_schema, crypto_schema,
        crypto_schema, fx_schema, crypto_schema,
        crypto_schema, crypto_schema
    );
    EXECUTE format(
        $adapter$
        CREATE OR REPLACE FUNCTION %1$I.fx_convert(
            value %2$I.crypto_amount,
            output_asset %2$I.crypto_asset,
            rate numeric,
            rounding %1$I.fx_rounding_mode DEFAULT 'half_even'
        ) RETURNS %2$I.crypto_amount
        LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
        SET search_path = %1$I, %2$I, pg_catalog
        AS 'SELECT %1$I.fx_convert($1, $2::text, $3, $4)'
        $adapter$,
        fx_schema, crypto_schema
    );
    EXECUTE format(
        $adapter$
        CREATE OR REPLACE FUNCTION %1$I.fx_create_quote(
            input %2$I.crypto_amount,
            output_asset %2$I.crypto_asset,
            customer_id text DEFAULT NULL,
            customer_segment text DEFAULT 'retail',
            expires_in interval DEFAULT interval '30 seconds',
            rounding %1$I.fx_rounding_mode DEFAULT 'half_even',
            quote_metadata jsonb DEFAULT '{}'::jsonb
        ) RETURNS %1$I.fx_quotes
        LANGUAGE plpgsql VOLATILE
        SET search_path = %1$I, %2$I, pg_catalog
        AS $body$
        BEGIN
            RETURN %1$I.fx_create_quote(
                %1$I.fx_pair(%2$I.crypto_amount_asset(input)::text, output_asset::text),
                'sell_base'::%1$I.fx_side,
                %2$I.crypto_amount_value(input),
                customer_segment,
                customer_id,
                expires_in,
                %2$I.crypto_asset_decimals(output_asset),
                rounding,
                quote_metadata
            );
        END
        $body$
        $adapter$,
        fx_schema, crypto_schema
    );
    PERFORM fx_enable_cross_asset_quotes();
    RETURN true;
END
$function$;

SELECT fx_enable_pg_money();
SELECT fx_enable_pg_cryptocurrency();

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON fx_rates, fx_quotes FROM PUBLIC;
GRANT SELECT ON fx_sources, fx_rates, fx_rules, fx_quotes TO PUBLIC;
