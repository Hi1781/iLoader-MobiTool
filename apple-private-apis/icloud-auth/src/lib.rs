pub mod anisette;
mod client;
use std::fmt::Display;

pub use client::{AppleAccount, LoginState, TrustedPhoneNumber, AuthenticationExtras, VerifyBody};
pub use omnisette::AnisetteConfiguration;

use thiserror::Error;
#[derive(Debug, Error)]
pub enum Error {
    #[error("Failed to parse the response")]
    Parse,
    #[error("Failed to authenticate.")]
    AuthSrp,
    #[error("Bad 2fa code.")]
    Bad2faCode,
    #[error("{1} ({0})")]
    AuthSrpWithMessage(i64, String),
    #[error("Please login to appleid.apple.com to fix this account")]
    ExtraStep(String),
    #[error("Failed to parse a plist {0}")]
    PlistError(#[from] plist::Error),
    #[error("Apple 返回了网页（HTTP {0}），多为账号被风控/受限、请求被拒或限流。请稍后再试，或更换网络/Apple ID：{1}")]
    AppleHtml(u16, String),
    #[error("Request failed {0}")]
    ReqwestError(#[from] reqwest::Error),
    #[error("Failed getting anisette data {0}")]
    ErrorGettingAnisette(#[from] omnisette::AnisetteError)
}