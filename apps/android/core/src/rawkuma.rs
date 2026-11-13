// Rawkuma source support, ported from apps/ipad (RawkumaConfiguration.swift,
// RawkumaGenres.swift, SourceChapter in Document.swift). The website URL comes
// from app-config.json; page images are accepted only from cdn.rawkuma.com.

use std::collections::HashSet;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use futures::StreamExt;
use reqwest::Client;
use scraper::{ElementRef, Html, Node, Selector};
use serde::{Deserialize, Serialize};
use url::Url;

const IMAGE_HOST: &str = "cdn.rawkuma.com";
const MAX_PAGES: usize = 500;
const MAX_SERIES_BYTES: usize = 4 * 1024 * 1024;
const MAX_IMAGE_BYTES: usize = 40 * 1024 * 1024;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RawkumaError {
    #[error("open a Rawkuma chapter containing manga pages")]
    NotChapter,
    #[error("could not read the manga's series page")]
    SeriesUnavailable,
    #[error("could not download page {page}")]
    Download { page: u32 },
    #[error("could not save the chapter: {detail}")]
    Storage { detail: String },
}

/// Series description sent with chapter translation as reference data.
#[derive(Debug, Clone, PartialEq, Serialize, uniffi::Record)]
pub struct SeriesContext {
    pub title: String,
    pub alternative_titles: Vec<String>,
    pub genres: Vec<String>,
    pub synopsis: String,
}

#[derive(Debug, Clone, Deserialize, uniffi::Record)]
pub struct SourceChapter {
    pub url: String,
    pub title: String,
    pub images: Vec<String>,
}

/// Validates the configured site: HTTPS origin only, normalized to `https://host/`.
pub(crate) fn normalize_site(value: &str) -> Option<String> {
    let url = Url::parse(value.trim()).ok()?;
    let plain = url.scheme() == "https"
        && url.host_str().is_some_and(|h| !h.is_empty())
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "" | "/");
    if plain { url.host_str().map(|host| format!("https://{host}/")) } else { None }
}

fn parse_in(site: &str, value: &str) -> Option<Url> {
    let base = Url::parse(site).ok()?;
    let url = Url::parse(value).ok()?;
    let same = url.scheme() == base.scheme()
        && url.host_str() == base.host_str()
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none();
    same.then_some(url)
}

/// Whether `value` is on the configured site (navigation stays inside it).
#[uniffi::export]
pub fn rawkuma_contains(site: String, value: String) -> bool {
    parse_in(&site, &value).is_some()
}

/// Full address for a path typed after the fixed site origin.
#[uniffi::export]
pub fn rawkuma_address(site: String, path: String) -> Option<String> {
    let path = path.trim();
    if path.starts_with("//") || path.contains('\\') || path.chars().any(char::is_control) || path.contains("://") {
        return None;
    }
    let address = format!("{site}{}", path.strip_prefix('/').unwrap_or(path));
    parse_in(&site, &address).map(|u| u.to_string())
}

/// Path, query and fragment of an address on the site, without the leading slash.
#[uniffi::export]
pub fn rawkuma_path(site: String, value: String) -> Option<String> {
    let url = parse_in(&site, &value)?;
    let mut path = url.path().trim_start_matches('/').to_owned();
    if let Some(query) = url.query() {
        path += &format!("?{query}");
    }
    if let Some(fragment) = url.fragment() {
        path += &format!("#{fragment}");
    }
    Some(path)
}

fn is_image(value: &str) -> bool {
    Url::parse(value).is_ok_and(|u| {
        u.scheme() == "https"
            && u.host_str() == Some(IMAGE_HOST)
            && u.port().is_none()
            && u.username().is_empty()
            && u.password().is_none()
            && u.path() != "/"
    })
}

/// Validates the chapter the page script reported (`{url, title, images}`).
#[uniffi::export]
pub fn parse_source_chapter(site: String, json: String) -> Result<SourceChapter, RawkumaError> {
    let chapter: SourceChapter = serde_json::from_str(&json).map_err(|_| RawkumaError::NotChapter)?;
    let unique: HashSet<&String> = chapter.images.iter().collect();
    let valid = rawkuma_contains(site, chapter.url.clone())
        && !chapter.images.is_empty()
        && chapter.images.len() <= MAX_PAGES
        && unique.len() == chapter.images.len()
        && chapter.images.iter().all(|i| is_image(i));
    if valid { Ok(chapter) } else { Err(RawkumaError::NotChapter) }
}

/// `https://site/manga/<slug>/` for any address inside a series.
#[uniffi::export]
pub fn rawkuma_series_url(site: String, value: String) -> Option<String> {
    let url = parse_in(&site, &value)?;
    let mut parts = url.path_segments()?.filter(|p| !p.is_empty());
    (parts.next()? == "manga").then_some(())?;
    let slug = parts.next()?;
    Some(format!("https://{}/manga/{slug}/", url.host_str()?))
}

fn normalized(text: &str) -> String {
    text.trim().to_lowercase()
}

/// Configured blocked genres present in `genres` (case-insensitive).
#[uniffi::export]
pub fn blocked_genre_matches(genres: Vec<String>, blocked: Vec<String>) -> Vec<String> {
    let names: HashSet<String> = genres.iter().map(|g| normalized(g)).collect();
    blocked.into_iter().filter(|b| names.contains(&normalized(b))).collect()
}

fn client() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        Client::builder()
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(15))
            .user_agent("KoharuPad/1.0")
            .build()
            .expect("HTTP client configuration is valid")
    })
}

fn clean(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn japanese(text: &str) -> bool {
    text.chars().any(|c| matches!(c, '\u{3040}'..='\u{30ff}' | '\u{3400}'..='\u{9fff}'))
}

/// Text of an element with `<br>` and `<hr>` turned into line breaks.
fn lines(element: ElementRef) -> Vec<String> {
    let mut text = String::new();
    for node in element.descendants() {
        match node.value() {
            Node::Text(t) => text.push_str(t),
            Node::Element(e) if matches!(e.name(), "br" | "hr") => text.push('\n'),
            _ => {}
        }
    }
    text.split('\n').map(clean).filter(|l| !l.is_empty()).collect()
}

/// Reads the series description panel only, excluding recommendations and
/// navigation. The text is untrusted reference data, never instructions.
pub(crate) fn parse_series(html: &str, site: &str) -> Option<SeriesContext> {
    let document = Html::parse_document(html);
    let panel = document.select(&Selector::parse("#tabpanel-description").ok()?).next()?;
    let genre_path = |href: &str| {
        parse_in(site, href).is_some_and(|u| {
            let parts: Vec<&str> = u.path().split('/').collect();
            parts.len() == 4 && parts[1] == "genre" && !parts[2].is_empty() && parts[3].is_empty()
        })
    };
    let genres: Vec<String> = panel
        .select(&Selector::parse(r#"a[itemprop="genre"]"#).ok()?)
        .filter(|a| a.value().attr("href").is_some_and(genre_path))
        .map(|a| clean(&a.text().collect::<String>()))
        .filter(|g| !g.is_empty() && g.chars().count() <= 80)
        .take(30)
        .collect();
    let name = document.select(&Selector::parse(r#"h1[itemprop="name"]"#).ok()?).next();
    let title = name.map(|n| clean(&n.text().collect::<String>())).unwrap_or_default();
    let alternatives = name
        .and_then(|n| n.next_siblings().find_map(ElementRef::wrap))
        .map(|sibling| {
            sibling
                .text()
                .collect::<String>()
                .split([',', '、'])
                .map(clean)
                .filter(|s| !s.is_empty() && *s != title && japanese(s))
                .take(5)
                .map(|s| s.chars().take(200).collect())
                .collect()
        })
        .unwrap_or_default();
    // The longest description is the expanded one; <hr> separates its language versions.
    let full = panel
        .select(&Selector::parse(r#"[itemprop="description"]"#).ok()?)
        .max_by_key(|d| d.text().map(str::len).sum::<usize>());
    let parts = full.map(lines).unwrap_or_default();
    let native: Vec<&String> = parts.iter().filter(|p| japanese(p)).collect();
    let synopsis = if native.is_empty() { parts.join("\n") } else { native.iter().map(|s| s.as_str()).collect::<Vec<_>>().join("\n") };
    Some(SeriesContext {
        title: title.chars().take(200).collect(),
        alternative_titles: alternatives,
        genres,
        synopsis: synopsis.chars().take(3000).collect(),
    })
}

/// Fetches the series page of a chapter (genres for half-safe mode, and
/// translation reference data in every mode).
#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_series(site: String, chapter_url: String) -> Result<SeriesContext, RawkumaError> {
    let url = rawkuma_series_url(site.clone(), chapter_url).ok_or(RawkumaError::SeriesUnavailable)?;
    let response = client().get(&url).send().await.map_err(|_| RawkumaError::SeriesUnavailable)?;
    let final_url = response.url().to_string();
    if response.status() != reqwest::StatusCode::OK || rawkuma_series_url(site.clone(), final_url).as_deref() != Some(url.as_str()) {
        return Err(RawkumaError::SeriesUnavailable);
    }
    let body = response.bytes().await.map_err(|_| RawkumaError::SeriesUnavailable)?;
    if body.len() > MAX_SERIES_BYTES {
        return Err(RawkumaError::SeriesUnavailable);
    }
    let html = String::from_utf8_lossy(&body);
    parse_series(&html, &site).ok_or(RawkumaError::SeriesUnavailable)
}

#[uniffi::export(callback_interface)]
pub trait DownloadProgress: Send + Sync {
    fn on_page(&self, done: u32, total: u32);
}

fn extension(url: &str, content_type: Option<&str>) -> &'static str {
    match content_type.unwrap_or_default() {
        t if t.contains("png") => "png",
        t if t.contains("webp") => "webp",
        t if t.contains("gif") => "gif",
        t if t.contains("jpeg") || t.contains("jpg") => "jpg",
        _ => match url.rsplit('.').next().map(|e| e.to_ascii_lowercase()).as_deref() {
            Some("png") => "png",
            Some("webp") => "webp",
            Some("gif") => "gif",
            _ => "jpg",
        },
    }
}

/// Downloads chapter pages into `directory` as `page-001.<ext>`…, in order.
/// Returns the file names. A failed page aborts the whole chapter.
#[uniffi::export(async_runtime = "tokio")]
pub async fn download_pages(
    site: String,
    chapter: SourceChapter,
    directory: String,
    progress: Box<dyn DownloadProgress>,
) -> Result<Vec<String>, RawkumaError> {
    let chapter = parse_source_chapter(site.clone(), serde_json::json!({
        "url": chapter.url, "title": chapter.title, "images": chapter.images,
    }).to_string())?;
    let progress: Arc<dyn DownloadProgress> = Arc::from(progress);
    let total = chapter.images.len() as u32;
    let done = Arc::new(std::sync::atomic::AtomicU32::new(0));
    // A few pages in flight at once; results keep page order.
    // Each page future owns its inputs so the stream is `Send` for every lifetime.
    let names: Vec<String> = futures::stream::iter(chapter.images.into_iter().enumerate())
        .map(|(index, image)| {
            let (site, directory, progress, done) = (site.clone(), directory.clone(), progress.clone(), done.clone());
            async move {
                let page = index as u32 + 1;
                let failed = || RawkumaError::Download { page };
                let response = client().get(&image).header("Referer", site.as_str()).send().await.map_err(|_| failed())?;
                if !response.status().is_success() || response.content_length().is_some_and(|l| l as usize > MAX_IMAGE_BYTES) {
                    return Err(failed());
                }
                let ext = extension(&image, response.headers().get("content-type").and_then(|v| v.to_str().ok()));
                let body = response.bytes().await.map_err(|_| failed())?;
                if body.is_empty() || body.len() > MAX_IMAGE_BYTES {
                    return Err(failed());
                }
                let name = format!("page-{page:03}.{ext}");
                std::fs::write(format!("{directory}/{name}"), &body).map_err(|e| RawkumaError::Storage { detail: e.to_string() })?;
                let finished = done.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                progress.on_page(finished, total);
                Ok(name)
            }
        })
        .buffered(4)
        .collect::<Vec<Result<String, RawkumaError>>>()
        .await
        .into_iter()
        .collect::<Result<_, _>>()?;
    Ok(names)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SITE: &str = "https://rawkuma.net/";

    #[test]
    fn site_paths_stay_on_origin() {
        assert_eq!(normalize_site("https://rawkuma.net").as_deref(), Some(SITE));
        assert!(normalize_site("http://rawkuma.net/").is_none());
        assert_eq!(rawkuma_address(SITE.into(), "/manga/x/".into()).as_deref(), Some("https://rawkuma.net/manga/x/"));
        assert!(rawkuma_address(SITE.into(), "//evil.example/".into()).is_none());
        assert_eq!(rawkuma_path(SITE.into(), "https://rawkuma.net/manga/x/?a=1".into()).as_deref(), Some("manga/x/?a=1"));
        assert_eq!(
            rawkuma_series_url(SITE.into(), "https://rawkuma.net/manga/x/chapter-1.42/".into()).as_deref(),
            Some("https://rawkuma.net/manga/x/"),
        );
    }

    #[test]
    fn chapter_images_must_come_from_cdn() {
        let ok = r#"{"url":"https://rawkuma.net/manga/x/chapter-1/","title":"t","images":["https://cdn.rawkuma.com/a/1.jpg"]}"#;
        assert!(parse_source_chapter(SITE.into(), ok.into()).is_ok());
        let bad = r#"{"url":"https://rawkuma.net/manga/x/chapter-1/","title":"t","images":["https://evil.example/1.jpg"]}"#;
        assert!(parse_source_chapter(SITE.into(), bad.into()).is_err());
    }

    #[test]
    fn series_panel_is_parsed() {
        let html = r#"<h1 itemprop="name">Title</h1><div>Alt, 日本語タイトル</div>
            <div id="tabpanel-description"><a itemprop="genre" href="https://rawkuma.net/genre/fantasy/">Fantasy</a>
            <a itemprop="genre" href="https://other.example/genre/x/">X</a>
            <div itemprop="description">English line<hr>日本語のあらすじ</div></div>"#;
        let series = parse_series(html, SITE).unwrap();
        assert_eq!(series.genres, vec!["Fantasy"]);
        assert_eq!(series.alternative_titles, vec!["日本語タイトル"]);
        assert_eq!(series.synopsis, "日本語のあらすじ");
        assert_eq!(blocked_genre_matches(series.genres, vec!["fantasy".into()]), vec!["fantasy"]);
    }
}
