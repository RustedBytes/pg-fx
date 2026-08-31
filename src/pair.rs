use pgrx::StringInfo;
use pgrx::prelude::*;
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};
use std::ffi::CStr;
use std::fmt::{Display, Formatter};

use crate::errors::fail_input;

const MAX_ASSET_BYTES: usize = 512;

#[derive(
    Debug,
    Clone,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Hash,
    Serialize,
    PostgresType,
    PostgresEq,
    PostgresOrd,
    PostgresHash,
)]
#[inoutfuncs]
#[pg_binary_protocol]
#[allow(non_camel_case_types)]
pub struct fx_pair {
    base: String,
    quote: String,
}

impl<'de> Deserialize<'de> for fx_pair {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct WirePair {
            base: String,
            quote: String,
        }

        let wire = WirePair::deserialize(deserializer)?;
        Self::from_assets(&wire.base, &wire.quote).map_err(D::Error::custom)
    }
}

impl fx_pair {
    fn parse(input: &str) -> Result<Self, String> {
        let input = input.trim();
        if input.matches('/').count() != 1 {
            return Err("pair must contain exactly one '/' separator".to_owned());
        }
        let (base, quote) = input
            .split_once('/')
            .ok_or_else(|| "pair must use BASE/QUOTE syntax".to_owned())?;
        Self::from_assets(base, quote)
    }

    fn from_assets(base: &str, quote: &str) -> Result<Self, String> {
        let base = normalize_asset(base)?;
        let quote = normalize_asset(quote)?;
        if base == quote {
            return Err("base and quote assets must differ".to_owned());
        }
        Ok(Self { base, quote })
    }

    fn canonical(&self) -> String {
        format!("{}/{}", self.base, self.quote)
    }
}

fn normalize_asset(input: &str) -> Result<String, String> {
    let value = input.trim();
    if value.is_empty() || value.len() > MAX_ASSET_BYTES {
        return Err(format!(
            "asset identity must contain between 1 and {MAX_ASSET_BYTES} bytes"
        ));
    }
    if !value.is_ascii()
        || !value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'@' | b':' | b'|')
        })
    {
        return Err(
            "asset identities may contain ASCII letters, digits, '.', '_', '-', '@', ':', and '|'"
                .to_owned(),
        );
    }

    if value.starts_with("v1|") {
        return Ok(value.to_owned());
    }
    if let Some((symbol, namespace)) = value.rsplit_once('@') {
        if symbol.is_empty() || namespace.is_empty() {
            return Err("namespaced assets must use SYMBOL@namespace".to_owned());
        }
        return Ok(format!(
            "{}@{}",
            symbol.to_ascii_uppercase(),
            namespace.to_ascii_lowercase()
        ));
    }
    Ok(value.to_ascii_uppercase())
}

impl Display for fx_pair {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.canonical())
    }
}

impl InOutFuncs for fx_pair {
    fn input(input: &CStr) -> Self {
        let text = input
            .to_str()
            .unwrap_or_else(|_| fail_input("input is not valid UTF-8"));
        Self::parse(text).unwrap_or_else(|error| fail_input(&error))
    }

    fn output(&self, buffer: &mut StringInfo) {
        buffer.push_str(&self.canonical());
    }
}

#[pg_extern(name = "fx_pair", immutable, parallel_safe)]
fn make_fx_pair(base: &str, quote: &str) -> fx_pair {
    fx_pair::from_assets(base, quote).unwrap_or_else(|error| fail_input(&error))
}

#[pg_extern(immutable, parallel_safe)]
pub fn fx_pair_base(pair: fx_pair) -> String {
    pair.base
}

#[pg_extern(immutable, parallel_safe)]
pub fn fx_pair_quote(pair: fx_pair) -> String {
    pair.quote
}

#[pg_extern(immutable, parallel_safe)]
pub fn fx_pair_valid(input: &str) -> bool {
    fx_pair::parse(input).is_ok()
}

#[pg_extern(name = "fx_validate", immutable, parallel_safe)]
#[allow(
    clippy::needless_pass_by_value,
    reason = "pgrx SQL functions receive owned decoded datums"
)]
pub fn fx_validate_pair(pair: fx_pair) -> bool {
    pair.base != pair.quote
        && normalize_asset(&pair.base).is_ok()
        && normalize_asset(&pair.quote).is_ok()
}
