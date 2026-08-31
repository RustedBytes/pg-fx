use pgrx::prelude::*;

#[allow(unreachable_code)]
pub(crate) fn fail_input(reason: &str) -> ! {
    ereport!(
        ERROR,
        PgSqlErrorCode::ERRCODE_INVALID_TEXT_REPRESENTATION,
        format!("invalid input syntax for type fx_pair: {reason}"),
        "Use BASE/QUOTE, for example USD/EUR or BTC/USD.".to_owned()
    );
    unreachable!()
}
