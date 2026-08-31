\set source_no random(1, 32)
SELECT (fx_rate_insert(
    'load_' || :source_no,
    'USD/EUR',
    0.84 + :source_no / 100000.0,
    0.85 + :source_no / 100000.0,
    rate_volume => 1000
)).id;
SELECT (fx_vwap('USD/EUR')).bid;
