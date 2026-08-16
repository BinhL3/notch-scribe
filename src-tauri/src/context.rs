//! Where the user was when they spoke: the frontmost app and, in a browser,
//! the page. Captured at the start of a gesture — that is the ground truth;
//! by the time a transcript arrives focus may have moved. Notes carry this so
//! "buy the blue one" still means something next week, and so an agent
//! reading the notes folder gets the situation, not just the words.

use serde::{Deserialize, Serialize};
use specta::Type;
use std::sync::Mutex;

#[derive(Debug, Clone, Default, Serialize, Deserialize, Type, PartialEq)]
pub struct Situation {
    /// Localised app name, e.g. "Safari".
    pub app: Option<String>,
    pub bundle_id: Option<String>,
    /// Page title, browsers only (for now).
    pub title: Option<String>,
    /// Page URL, browsers only.
    pub url: Option<String>,
}

impl Situation {
    /// "Safari · github.com" / "Xcode" — one line for lists.
    pub fn label(&self) -> Option<String> {
        let app = self.app.clone()?;
        match self.url.as_deref().and_then(host) {
            Some(h) => Some(format!("{app} · {h}")),
            None => Some(app),
        }
    }
}

fn host(url: &str) -> Option<String> {
    let rest = url.split("://").nth(1)?;
    let h = rest.split(['/', '?', '#']).next()?;
    let h = h.strip_prefix("www.").unwrap_or(h);
    (!h.is_empty()).then(|| h.to_string())
}

/// The situation captured at the start of the current gesture.
static CURRENT: Mutex<Option<Situation>> = Mutex::new(None);

/// Call on key-down. Cheap on the calling thread (frontmost app is a single
/// AppKit query); the browser page is fetched on a background thread and
/// merged in when it lands, so a slow AppleScript never delays recording.
pub fn snapshot() {
    #[cfg(target_os = "macos")]
    {
        let base = frontmost();
        *CURRENT.lock().unwrap_or_else(|e| e.into_inner()) = Some(base.clone());
        if let Some(bid) = base.bundle_id.clone() {
            if let Some(script) = browser_script(&bid) {
                std::thread::spawn(move || {
                    let (title, url) = run_browser_script(script);
                    if title.is_none() && url.is_none() {
                        return;
                    }
                    let mut slot = CURRENT.lock().unwrap_or_else(|e| e.into_inner());
                    // Only merge into the same gesture's snapshot.
                    if let Some(s) = slot.as_mut() {
                        if s.bundle_id.as_deref() == Some(bid.as_str()) {
                            s.title = title;
                            s.url = url;
                        }
                    }
                });
            }
        }
    }
}

/// The last snapshot, if any. Not cleared: a note always gets the situation
/// of the gesture that produced it, and the next key-down overwrites it.
pub fn current() -> Option<Situation> {
    CURRENT.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

#[cfg(target_os = "macos")]
fn frontmost() -> Situation {
    use objc2_app_kit::NSWorkspace;
    let ws = NSWorkspace::sharedWorkspace();
    let Some(app) = ws.frontmostApplication() else {
        return Situation::default();
    };
    Situation {
        app: app.localizedName().map(|s| s.to_string()),
        bundle_id: app.bundleIdentifier().map(|s| s.to_string()),
        title: None,
        url: None,
    }
}

/// AppleScript that prints "title\nurl" for the front tab of known browsers.
/// First use per browser triggers macOS's one-time Automation prompt.
#[cfg(target_os = "macos")]
fn browser_script(bundle_id: &str) -> Option<&'static str> {
    Some(match bundle_id {
        "com.apple.Safari" | "com.apple.SafariTechnologyPreview" => {
            r#"tell application "Safari" to return (name of front document) & linefeed & (URL of front document)"#
        }
        "com.google.Chrome" => {
            r#"tell application "Google Chrome" to return (title of active tab of front window) & linefeed & (URL of active tab of front window)"#
        }
        "company.thebrowser.Browser" => {
            r#"tell application "Arc" to return (title of active tab of front window) & linefeed & (URL of active tab of front window)"#
        }
        "com.brave.Browser" => {
            r#"tell application "Brave Browser" to return (title of active tab of front window) & linefeed & (URL of active tab of front window)"#
        }
        "com.microsoft.edgemac" => {
            r#"tell application "Microsoft Edge" to return (title of active tab of front window) & linefeed & (URL of active tab of front window)"#
        }
        _ => return None,
    })
}

#[cfg(target_os = "macos")]
fn run_browser_script(script: &str) -> (Option<String>, Option<String>) {
    let out = match std::process::Command::new("osascript")
        .args(["-e", script])
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
        Ok(o) => {
            log::debug!(
                "[context] osascript failed: {}",
                String::from_utf8_lossy(&o.stderr).trim()
            );
            return (None, None);
        }
        Err(e) => {
            log::debug!("[context] osascript unavailable: {e}");
            return (None, None);
        }
    };
    let mut lines = out.lines();
    let title = lines.next().map(str::trim).filter(|s| !s.is_empty()).map(String::from);
    let url = lines.next().map(str::trim).filter(|s| !s.is_empty()).map(String::from);
    (title, url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        let s = Situation {
            app: Some("Safari".into()),
            url: Some("https://www.github.com/BinhL3/noi?x=1".into()),
            ..Default::default()
        };
        assert_eq!(s.label().as_deref(), Some("Safari · github.com"));
        let s = Situation { app: Some("Xcode".into()), ..Default::default() };
        assert_eq!(s.label().as_deref(), Some("Xcode"));
        assert_eq!(Situation::default().label(), None);
    }
}
