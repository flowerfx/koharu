// Kuruby backend (Nakama) client, ported from apps/ipad NakamaAuthentication.swift,
// Credits.swift and BackendAI.swift. The server key and the development CA come
// from the git-ignored nakama-connection files at build time; the endpoint comes
// from app-config.json (`server`). Provider keys and model choice stay on the server.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const MAX_RESPONSE: usize = 1_048_576;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BackendError {
    #[error("the authentication backend has not been configured for this build")]
    NotConfigured,
    #[error("sign in to use Backend API")]
    SignedOut,
    #[error("backend authentication was rejected; sign in again")]
    Unauthorized,
    #[error("email sign-in failed")]
    EmailRejected,
    #[error("not enough credits")]
    NotEnoughCredits,
    #[error("the backend is unreachable: {detail}")]
    Network { detail: String },
    #[error("backend error HTTP {status}")]
    Http { status: u16 },
    #[error("the backend returned an invalid response")]
    InvalidResponse,
    #[error("AI request failed: {code}")]
    AiFailed { code: String },
    #[error("the AI request is too large or invalid")]
    TooLarge,
    #[error("the AI request is taking too long")]
    Timeout,
    #[error("stopped")]
    Cancelled,
}

type Result<T> = std::result::Result<T, BackendError>;

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct BackendSession {
    pub token: String,
    pub refresh_token: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BackendUser {
    pub id: String,
    pub username: String,
    pub email: Option<String>,
}

/// Credit profile and pricing returned by every `profile_*` command.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CreditStatus {
    pub credit: i64,
    /// `free` or `premium`.
    pub account_type: String,
    pub can_claim_daily: bool,
    pub daily_free_user: i64,
    pub daily_premium_user: i64,
    pub cost_translate_free: i64,
    pub cost_translate_premium: i64,
    pub cost_backend_surcharge: i64,
    /// Price of translating a saved chapter again through Backend API.
    pub cost_rerun_backend: i64,
}

impl CreditStatus {
    /// Price of one chapter translation through Backend API (iPad `CreditConfiguration.cost`).
    fn translate_cost(&self) -> i64 {
        let base = if self.account_type == "premium" { self.cost_translate_premium } else { self.cost_translate_free };
        base + self.cost_backend_surcharge
    }
}

#[uniffi::export]
pub fn backend_translate_cost(status: CreditStatus) -> i64 {
    status.translate_cost()
}

/// Enhanced translation runs Backend API twice: translate, then review (iPad `CreditConfiguration.cost`).
#[uniffi::export]
pub fn backend_enhanced_cost(status: CreditStatus) -> i64 {
    2 * status.translate_cost()
}

fn network(error: reqwest::Error) -> BackendError {
    BackendError::Network { detail: error.without_url().to_string() }
}

/// One signed-in (or signed-out) connection. Sessions refresh themselves on
/// 401; read `session()` after a call to persist the current tokens.
#[derive(uniffi::Object)]
pub struct BackendClient {
    endpoint: String,
    server_key: String,
    client: Client,
    session: Mutex<Option<BackendSession>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl BackendClient {
    /// `certificate_der` is the development CA trusted for this host in addition
    /// to public roots; hostname and validity checks stay enforced.
    #[uniffi::constructor]
    pub fn new(endpoint: String, server_key: String, certificate_der: Vec<u8>) -> Result<std::sync::Arc<Self>> {
        let url = url::Url::parse(&endpoint).map_err(|_| BackendError::NotConfigured)?;
        let plain = url.scheme() == "https" && url.host_str().is_some() && url.username().is_empty()
            && url.password().is_none() && url.query().is_none() && url.fragment().is_none()
            && matches!(url.path(), "" | "/");
        if !plain || server_key.is_empty() || server_key.len() > 256 {
            return Err(BackendError::NotConfigured);
        }
        let mut builder = Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::none());
        if !certificate_der.is_empty() {
            let certificate = reqwest::Certificate::from_der(&certificate_der).map_err(|_| BackendError::NotConfigured)?;
            builder = builder.add_root_certificate(certificate);
        }
        Ok(std::sync::Arc::new(Self {
            endpoint: endpoint.trim_end_matches('/').to_owned(),
            server_key,
            client: builder.build().map_err(|_| BackendError::NotConfigured)?,
            session: Mutex::new(None),
        }))
    }

    pub fn session(&self) -> Option<BackendSession> {
        self.session.lock().unwrap().clone()
    }

    pub fn set_session(&self, session: Option<BackendSession>) {
        *self.session.lock().unwrap() = session;
    }

    /// Guest account bound to a random per-install device ID (iPad `signInDevice`).
    pub async fn sign_in_device(&self, device_id: String) -> Result<BackendUser> {
        let data = self.send("v2/account/authenticate/device?create=true", Some(json!({"id": device_id})), None).await?;
        self.publish(serde_json::from_value(data).map_err(|_| BackendError::InvalidResponse)?).await
    }

    /// Existing email account only; accounts are not created from the app.
    pub async fn sign_in_email(&self, email: String, password: String) -> Result<BackendUser> {
        let email = email.trim().to_lowercase();
        let valid = email.len() <= 254 && email.contains('@') && !email.contains(char::is_whitespace)
            && (8..=128).contains(&password.chars().count());
        if !valid {
            return Err(BackendError::EmailRejected);
        }
        let data = self
            .send("v2/account/authenticate/email?create=false", Some(json!({"email": email, "password": password})), None)
            .await
            .map_err(|e| match e {
                BackendError::Http { .. } | BackendError::Unauthorized => BackendError::EmailRejected,
                other => other,
            })?;
        self.publish(serde_json::from_value(data).map_err(|_| BackendError::InvalidResponse)?).await
    }

    /// Validates a saved session, refreshing it once if the token expired.
    pub async fn restore(&self) -> Result<BackendUser> {
        let session = self.session().ok_or(BackendError::SignedOut)?;
        match self.account(&session).await {
            Ok(user) => Ok(user),
            Err(BackendError::Unauthorized) => {
                let refreshed = self.refresh(&session).await?;
                self.publish(refreshed).await
            }
            Err(error) => Err(error),
        }
    }

    pub async fn sign_out(&self) {
        if let Some(session) = self.session() {
            let _ = self.send("v2/session/logout", Some(json!({"token": session.token, "refresh_token": session.refresh_token})), Some(&session.token)).await;
        }
        self.set_session(None);
    }

    pub async fn credits(&self) -> Result<CreditStatus> {
        self.profile("profile_load", json!({})).await
    }

    pub async fn claim_daily(&self) -> Result<CreditStatus> {
        self.profile("profile_daily", json!({"operation_id": uuid()})).await
    }
}

impl BackendClient {
    async fn send(&self, path: &str, body: Option<Value>, token: Option<&str>) -> Result<Value> {
        let url = format!("{}/{}", self.endpoint, path);
        let mut request = if body.is_some() { self.client.post(url) } else { self.client.get(url) };
        request = request.header("Accept", "application/json");
        request = match token {
            Some(token) => request.bearer_auth(token),
            None => request.basic_auth(&self.server_key, Some("")),
        };
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(network)?;
        match response.status() {
            s if s.is_success() => {}
            StatusCode::UNAUTHORIZED => return Err(BackendError::Unauthorized),
            s => return Err(BackendError::Http { status: s.as_u16() }),
        }
        let bytes = response.bytes().await.map_err(network)?;
        if bytes.len() > MAX_RESPONSE {
            return Err(BackendError::InvalidResponse);
        }
        if bytes.is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_slice(&bytes).map_err(|_| BackendError::InvalidResponse)
    }

    async fn account(&self, session: &BackendSession) -> Result<BackendUser> {
        let data = self.send("v2/account", None, Some(&session.token)).await?;
        let user = &data["user"];
        let id = user["id"].as_str().filter(|id| id.len() == 36).ok_or(BackendError::InvalidResponse)?;
        Ok(BackendUser {
            id: id.to_owned(),
            username: user["username"].as_str().unwrap_or_default().to_owned(),
            email: data["email"].as_str().filter(|e| !e.is_empty()).map(str::to_owned),
        })
    }

    async fn refresh(&self, session: &BackendSession) -> Result<BackendSession> {
        let data = self.send("v2/account/session/refresh", Some(json!({"token": session.refresh_token})), None).await?;
        serde_json::from_value(data).map_err(|_| BackendError::InvalidResponse)
    }

    async fn publish(&self, session: BackendSession) -> Result<BackendUser> {
        let user = self.account(&session).await?;
        self.set_session(Some(session));
        Ok(user)
    }

    /// One RPC with the current session, refreshing it once on 401. A lost
    /// response to an idempotent command is retried once with the same payload.
    pub(crate) async fn rpc(&self, name: &str, payload: &Value) -> Result<String> {
        let text = payload.to_string();
        let retry = name.starts_with("profile_") || name.starts_with("ai_");
        for refreshed in [false, true] {
            let session = self.session().ok_or(BackendError::SignedOut)?;
            let body = Value::String(text.clone());
            let mut result = self.send(&format!("v2/rpc/{name}"), Some(body.clone()), Some(&session.token)).await;
            if retry && matches!(result, Err(BackendError::Network { .. })) {
                result = self.send(&format!("v2/rpc/{name}"), Some(body), Some(&session.token)).await;
            }
            match result {
                Ok(value) => return value["payload"].as_str().map(str::to_owned).ok_or(BackendError::InvalidResponse),
                Err(BackendError::Unauthorized) if !refreshed => {
                    let renewed = self.refresh(&session).await.inspect_err(|_| self.set_session(None))?;
                    self.set_session(Some(renewed));
                }
                Err(BackendError::Unauthorized) => {
                    self.set_session(None);
                    return Err(BackendError::Unauthorized);
                }
                Err(error) => return Err(error),
            }
        }
        Err(BackendError::Unauthorized)
    }

    async fn profile_value(&self, name: &str, payload: Value) -> Result<Value> {
        let text = self.rpc(name, &payload).await.map_err(|e| match e {
            BackendError::Http { status: 400 | 409 } if name == "profile_reserve" => BackendError::NotEnoughCredits,
            other => other,
        })?;
        serde_json::from_str(&text).map_err(|_| BackendError::InvalidResponse)
    }

    async fn profile(&self, name: &str, payload: Value) -> Result<CreditStatus> {
        status(&self.profile_value(name, payload).await?)
    }

    /// Reserves the credits of one Backend API chapter translation: `translate`
    /// (a `rerun` of a saved chapter is priced separately) or `translateEnhanced`.
    pub(crate) async fn reserve_translation(&self, enhanced: bool, rerun: bool) -> Result<String> {
        let action = if enhanced { "translateEnhanced" } else { "translate" };
        let value = self
            .profile_value("profile_reserve", json!({"operation_id": uuid(), "action": action, "provider": "backend", "rerun": rerun && !enhanced}))
            .await?;
        value["reservation_id"].as_str().map(str::to_owned).ok_or(BackendError::InvalidResponse)
    }

    /// Settles a Backend API reservation; the server decides the charge from the request outcome.
    pub(crate) async fn finish(&self, reservation: &str) {
        let _ = self.rpc("ai_finish", &json!({"reservation_id": reservation.to_lowercase()})).await;
    }

    /// Submits one structured-output job and polls it (iPad `BackendAI.generate`).
    /// With `review_system`, the server translates and then reviews the draft
    /// against the source (`translateEnhanced`).
    pub(crate) async fn generate(
        &self,
        reservation: &str,
        system: &str,
        user: &str,
        count: usize,
        review_system: Option<&str>,
    ) -> Result<Value> {
        if system.is_empty() || user.is_empty() || system.encode_utf16().count() > 8192
            || user.encode_utf16().count() > 196_608 || !(1..=2000).contains(&count)
            || review_system.is_some_and(|r| r.is_empty() || r.encode_utf16().count() > 8192)
        {
            return Err(BackendError::TooLarge);
        }
        let request_id = uuid();
        let reservation = reservation.to_lowercase();
        let task = if review_system.is_some() { "translateEnhanced" } else { "translate" };
        let mut payload = json!({"request_id": request_id, "reservation_id": reservation, "task": task,
                                 "system": system, "user": user, "count": count});
        if let Some(review) = review_system {
            payload["review_system"] = json!(review);
        }
        if payload.to_string().len() > 245_000 {
            return Err(BackendError::TooLarge);
        }
        let outcome = async {
            let mut response = self.rpc("ai_generate", &payload).await?;
            let deadline = Instant::now() + Duration::from_secs(3660);
            loop {
                let job: Value = serde_json::from_str(&response).map_err(|_| BackendError::InvalidResponse)?;
                if job["request_id"] != request_id.as_str() || job["reservation_id"] != reservation.as_str() {
                    return Err(BackendError::InvalidResponse);
                }
                match job["status"].as_str() {
                    Some("succeeded") => {
                        let result = &job["result"];
                        if result["model"].as_str().is_none_or(str::is_empty) || !result["output"].is_object() {
                            return Err(BackendError::InvalidResponse);
                        }
                        return Ok(result["output"].clone());
                    }
                    Some("failed") => {
                        return Err(BackendError::AiFailed { code: job["error"].as_str().unwrap_or("unknown").to_owned() });
                    }
                    Some("cancelled") => return Err(BackendError::Cancelled),
                    Some("queued" | "running") => {}
                    _ => return Err(BackendError::InvalidResponse),
                }
                if Instant::now() >= deadline {
                    return Err(BackendError::Timeout);
                }
                tokio::time::sleep(Duration::from_secs(1)).await;
                response = self.rpc("ai_result", &json!({"request_id": request_id})).await?;
            }
        }
        .await;
        if outcome.is_err() {
            // Also clean up queued work after a lost or malformed response.
            let _ = self.rpc("ai_cancel", &json!({"request_id": request_id})).await;
        }
        outcome
    }
}

fn status(value: &Value) -> Result<CreditStatus> {
    let profile = &value["profile"];
    let policy = &value["policy"];
    let int = |v: &Value| v.as_i64().ok_or(BackendError::InvalidResponse);
    Ok(CreditStatus {
        credit: int(&profile["credit"])?,
        account_type: profile["account_type"].as_str().ok_or(BackendError::InvalidResponse)?.to_owned(),
        can_claim_daily: value["can_claim_daily"].as_bool().unwrap_or(false),
        daily_free_user: int(&policy["daily_free_user"])?,
        daily_premium_user: int(&policy["daily_premium_user"])?,
        cost_translate_free: int(&policy["cost_translate_free"])?,
        cost_translate_premium: int(&policy["cost_translate_premium"])?,
        cost_backend_surcharge: int(&policy["cost_backend_surcharge"])?,
        cost_rerun_backend: int(&policy["cost_rerun_backend"])?,
    })
}

fn uuid() -> String {
    let mut bytes = [0u8; 16];
    getrandom(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32])
}

fn getrandom(buffer: &mut [u8]) {
    use std::io::Read;
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(buffer)).expect("system random source is available");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_is_v4_shaped() {
        let id = uuid();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
    }

    #[test]
    fn credit_status_parses_profile_response() {
        let value = json!({"profile": {"credit": 7, "account_type": "free"}, "can_claim_daily": true,
            "policy": {"daily_free_user": 10, "daily_premium_user": 100, "cost_translate_free": 1,
                       "cost_translate_premium": 0, "cost_backend_surcharge": 1, "cost_rerun_backend": 1}});
        let status = status(&value).unwrap();
        assert_eq!(status.translate_cost(), 2);
        assert!(status.can_claim_daily);
    }
}

