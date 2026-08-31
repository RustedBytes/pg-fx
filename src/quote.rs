use pgrx::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, PostgresEnum)]
#[allow(non_camel_case_types)]
pub enum fx_quote_status {
    open,
    executed,
    expired,
    cancelled,
}
