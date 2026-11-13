// Remote app-config.json, shared with the iPad app (ConfigurationSync.swift):
// ListObjectsV2 on the exact environment/version prefix, then a conditional
// GetObject only when the listed validators changed. The bundled iPad JSON is
// the offline seed. No signing key is bundled on Android, matching iPad builds
// without `KoharuConfigSigningKey`.

use std::collections::HashSet;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use reqwest::Client;
use serde::Deserialize;

const BUNDLED: &str = include_str!("../../../ipad/Resources/app-config.json");
const BUCKET: &str = "https://kem-solution-public.s3.us-east-1.amazonaws.com";
const MAX_BYTES: usize = 2_097_152;

/// Provider IDs the configuration schema accepts (case-sensitive, as on iPad).
const KNOWN_PROVIDERS: [&str; 12] = [
    "backend", "local", "lmStudio", "openAI", "anthropic", "deepSeek", "qwen", "miniMax", "gemini", "grok", "openRouter", "deepL",
];

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ConfigError {
    #[error("invalid configuration target")]
    InvalidTarget,
    #[error("invalid app configuration (app-config.json)")]
    Invalid,
    #[error("invalid configuration listing")]
    InvalidListing,
    #[error("configuration object is missing")]
    Missing,
    #[error("configuration is too large")]
    Oversized,
    #[error("configuration changed during download")]
    ChangedDuringDownload,
    #[error("network error: {detail}")]
    Network { detail: String },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ProviderToggle {
    pub id: String,
    pub enable: bool,
}

/// The parts of app-config.json the Android app acts on. The full validated
/// JSON is cached unchanged, so later features read the same document.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AppConfig {
    pub providers: Vec<ProviderToggle>,
    pub default_provider: String,
    /// Normalized `https://host/`, or `None` when no Rawkuma site is configured.
    pub rawkuma_url: Option<String>,
    /// `none-safe`, `half-safe` or `full-safe`.
    pub content_safety_mode: String,
    pub blocked_genres: Vec<String>,
    /// Backend API is offered only while the server is active.
    pub server_active: bool,
    pub server_endpoint: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ConfigValidators {
    pub etag: String,
    pub last_modified: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct RemoteConfig {
    pub body: String,
    pub etag: String,
    pub last_modified: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderEntry {
    id: String,
    enable: bool,
}

#[derive(Deserialize)]
struct Defaults {
    provider: String,
}

#[derive(Deserialize)]
struct Rawkuma {
    url: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContentSafety {
    mode: String,
    blocked_genres: Vec<String>,
}

#[derive(Deserialize)]
struct Server {
    active: bool,
    endpoint: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Document {
    provider: Vec<ProviderEntry>,
    defaults: Defaults,
    rawkuma: Option<Rawkuma>,
    content_safety: ContentSafety,
    server: Server,
}

#[uniffi::export]
pub fn bundled_app_config() -> String {
    BUNDLED.to_owned()
}

/// Validates the provider catalog and default. Invalid JSON fails closed.
#[uniffi::export]
pub fn parse_app_config(json: String) -> Result<AppConfig, ConfigError> {
    if json.len() > MAX_BYTES {
        return Err(ConfigError::Oversized);
    }
    let document: Document = serde_json::from_str(&json).map_err(|_| ConfigError::Invalid)?;
    let mut seen = HashSet::new();
    for entry in &document.provider {
        if !KNOWN_PROVIDERS.contains(&entry.id.as_str()) || !seen.insert(entry.id.as_str()) {
            return Err(ConfigError::Invalid);
        }
    }
    let default_enabled = document.provider.iter().any(|p| p.id == document.defaults.provider && p.enable);
    if !default_enabled {
        return Err(ConfigError::Invalid);
    }
    let rawkuma_url = match document.rawkuma.and_then(|r| r.url).map(|u| u.trim().to_owned()).filter(|u| !u.is_empty()) {
        None => None,
        Some(url) => Some(crate::rawkuma::normalize_site(&url).ok_or(ConfigError::Invalid)?),
    };
    let safety = document.content_safety;
    let mut genres = HashSet::new();
    let genres_valid = safety.blocked_genres.len() <= 100
        && safety.blocked_genres.iter().all(|g| {
            !g.trim().is_empty() && g.chars().count() <= 80 && genres.insert(g.trim().to_lowercase())
        });
    if !matches!(safety.mode.as_str(), "none-safe" | "half-safe" | "full-safe") || !genres_valid {
        return Err(ConfigError::Invalid);
    }
    let endpoint = url::Url::parse(&document.server.endpoint).map_err(|_| ConfigError::Invalid)?;
    let plain = endpoint.scheme() == "https" && endpoint.host_str().is_some() && endpoint.username().is_empty()
        && endpoint.password().is_none() && endpoint.query().is_none() && endpoint.fragment().is_none()
        && matches!(endpoint.path(), "" | "/");
    if !plain {
        return Err(ConfigError::Invalid);
    }
    Ok(AppConfig {
        providers: document.provider.into_iter().map(|p| ProviderToggle { id: p.id, enable: p.enable }).collect(),
        default_provider: document.defaults.provider,
        rawkuma_url,
        content_safety_mode: safety.mode,
        blocked_genres: safety.blocked_genres,
        server_active: document.server.active,
        server_endpoint: document.server.endpoint.trim_end_matches('/').to_owned(),
    })
}

fn client() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        Client::builder()
            .timeout(Duration::from_secs(8))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("HTTP client configuration is valid")
    })
}

fn network(error: reqwest::Error) -> ConfigError {
    ConfigError::Network { detail: error.without_url().to_string() }
}

/// Text of the first `<tag>` element in `xml`, with XML entities decoded.
fn element<'a>(xml: &'a str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let start = xml.find(&open)? + open.len();
    let end = start + xml[start..].find(&format!("</{tag}>"))?;
    Some(
        xml[start..end]
            .replace("&quot;", "\"")
            .replace("&apos;", "'")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&"),
    )
}

struct Listed {
    etag: String,
    last_modified: String,
    size: usize,
}

async fn read(request: reqwest::RequestBuilder) -> Result<(reqwest::header::HeaderMap, Vec<u8>), ConfigError> {
    let mut response = request.header("Cache-Control", "no-cache").send().await.map_err(network)?;
    if response.status() != reqwest::StatusCode::OK {
        return Err(ConfigError::Missing);
    }
    if response.content_length().is_some_and(|l| l as usize > MAX_BYTES) {
        return Err(ConfigError::Oversized);
    }
    let headers = response.headers().clone();
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(network)? {
        if body.len() + chunk.len() > MAX_BYTES {
            return Err(ConfigError::Oversized);
        }
        body.extend_from_slice(&chunk);
    }
    Ok((headers, body))
}

/// Returns the new configuration, or `None` when the cached validators still
/// match the listing. The body is validated before it is returned.
#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_app_config(
    environment: String,
    version: String,
    cached: Option<ConfigValidators>,
) -> Result<Option<RemoteConfig>, ConfigError> {
    let semver = version.split('.').collect::<Vec<_>>();
    if !matches!(environment.as_str(), "staging" | "production")
        || semver.len() != 3
        || semver.iter().any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(ConfigError::InvalidTarget);
    }
    let prefix = format!("apps/aimangatranslator/env/{environment}/{version}/configs/");
    let key = format!("{prefix}app-config.json");
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut continuation: Option<String> = None;
    let mut seen = HashSet::new();
    for _ in 0..8 {
        let mut query = vec![("list-type", "2".to_string()), ("prefix", prefix.clone()), ("max-keys", "1000".into())];
        if let Some(token) = &continuation {
            query.push(("continuation-token", token.clone()));
        }
        let (_, body) = read(client().get(format!("{BUCKET}/")).query(&query)).await?;
        let xml = String::from_utf8(body).map_err(|_| ConfigError::InvalidListing)?;
        if !xml.contains("<ListBucketResult") {
            return Err(ConfigError::InvalidListing);
        }
        let listed = xml.split("<Contents>").skip(1).find_map(|item| {
            (element(item, "Key")? == key).then(|| {
                Some(Listed {
                    etag: element(item, "ETag").filter(|e| !e.is_empty())?,
                    last_modified: element(item, "LastModified")?,
                    size: element(item, "Size")?.parse().ok()?,
                })
            })
        });
        if let Some(object) = listed {
            let object = object.ok_or(ConfigError::InvalidListing)?;
            if object.size == 0 || object.size > MAX_BYTES {
                return Err(ConfigError::Oversized);
            }
            if cached.as_ref().is_some_and(|c| c.etag == object.etag && c.last_modified == object.last_modified) {
                return Ok(None);
            }
            if Instant::now() >= deadline {
                return Err(ConfigError::Network { detail: "timed out".into() });
            }
            // Either validator changing forces a body download; If-Match pins
            // the body to the listed object.
            let (headers, body) = read(client().get(format!("{BUCKET}/{key}")).header("If-Match", &object.etag)).await?;
            let etag = headers.get("etag").and_then(|v| v.to_str().ok());
            if body.len() != object.size || etag != Some(object.etag.as_str()) {
                return Err(ConfigError::ChangedDuringDownload);
            }
            let body = String::from_utf8(body).map_err(|_| ConfigError::Invalid)?;
            parse_app_config(body.clone())?;
            return Ok(Some(RemoteConfig { body, etag: object.etag, last_modified: object.last_modified }));
        }
        let next = element(&xml, "NextContinuationToken")
            .filter(|_| element(&xml, "IsTruncated").as_deref() == Some("true"))
            .ok_or(ConfigError::Missing)?;
        if !seen.insert(next.clone()) || Instant::now() >= deadline {
            return Err(ConfigError::InvalidListing);
        }
        continuation = Some(next);
    }
    Err(ConfigError::InvalidListing)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_seed_is_valid() {
        let config = parse_app_config(bundled_app_config()).unwrap();
        assert!(config.providers.iter().any(|p| p.id == "openAI"));
        assert_eq!(config.rawkuma_url.as_deref(), Some("https://rawkuma.net/"));
    }

    #[test]
    fn rejects_disabled_default_and_unknown_provider() {
        let safety = r#""contentSafety":{"mode":"none-safe","blockedGenres":[]},"server":{"active":true,"endpoint":"https://example.com"}"#;
        let disabled = format!(r#"{{"provider":[{{"id":"openAI","enable":false}}],"defaults":{{"provider":"openAI"}},{safety}}}"#);
        assert!(parse_app_config(disabled).is_err());
        let unknown = format!(r#"{{"provider":[{{"id":"nope","enable":true}}],"defaults":{{"provider":"nope"}},{safety}}}"#);
        assert!(parse_app_config(unknown).is_err());
    }

    #[test]
    fn listing_elements_decode_entities() {
        let xml = "<Contents><Key>a</Key><ETag>&quot;abc&quot;</ETag></Contents>";
        assert_eq!(element(xml, "ETag").as_deref(), Some("\"abc\""));
    }
}
