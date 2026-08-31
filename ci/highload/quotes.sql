\set quote_amount random(1, 100000)
SELECT (fx_create_quote(
    'USD/EUR',
    'sell_base',
    :quote_amount,
    customer_id => 'load-' || :client_id,
    expires_in => interval '10 minutes'
)).id;
