use pgrx::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum fx_side {
    buy_base,
    sell_base,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum fx_rate_strategy {
    latest,
    priority,
    best_bid,
    best_ask,
    median,
    weighted_median,
    vwap,
    trimmed_mean,
}
