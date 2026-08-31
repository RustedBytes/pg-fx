CREATE INDEX fx_quotes_open_expiry_idx ON fx_quotes (expires_at) WHERE status = 'open';
CREATE INDEX fx_quotes_customer_idx ON fx_quotes (customer_id, created_at DESC)
    WHERE customer_id IS NOT NULL;
