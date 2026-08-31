mod conversion;
mod errors;
mod pair;
mod quote;
mod rate;

use pgrx::prelude::*;

pgrx::pg_module_magic!();

#[allow(unused_imports)]
use conversion::fx_rounding_mode;
#[allow(unused_imports)]
use pair::{fx_pair, fx_pair_base, fx_pair_quote, fx_pair_valid, fx_validate_pair};
#[allow(unused_imports)]
use quote::fx_quote_status;
#[allow(unused_imports)]
use rate::{fx_rate_strategy, fx_side};

extension_sql_file!(
    "../sql/schema.sql",
    name = "fx_schema",
    requires = [
        fx_pair,
        fx_pair_base,
        fx_pair_quote,
        fx_pair_valid,
        fx_validate_pair,
        fx_side,
        fx_quote_status,
        fx_rate_strategy,
        fx_rounding_mode
    ]
);

extension_sql_file!(
    "../sql/indexes.sql",
    name = "fx_indexes",
    requires = ["fx_schema"]
);

extension_sql_file!(
    "../sql/views.sql",
    name = "fx_views",
    requires = ["fx_indexes"],
    finalize
);

#[cfg(any(test, feature = "pg_test"))]
mod tests;

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
