//! Now Playing for the island's player card. Reads MediaRemote through
//! `mediaremote-adapter` (BSD-3, ungive/mediaremote-adapter, bundled under
//! resources/mediaremote): a Perl script that dl-loads a helper framework —
//! `/usr/bin/perl` is entitled to MediaRemote, we are not (macOS 15.4+).
//! Private API by proxy: if a macOS update breaks it, `test` fails at
//! startup and the card simply never appears. Nothing else depends on this.

use log::{debug, info, warn};
use serde_json::{Map, Value};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tauri::{AppHandle, Manager};

struct Paths {
    script: PathBuf,
    framework: PathBuf,
    test_client: PathBuf,
}

static PATHS: OnceLock<Option<Paths>> = OnceLock::new();
/// Last full now-playing state (diffs merged in), for the card and for
/// callers that need e.g. the duration to seek.
static STATE: Mutex<Option<Map<String, Value>>> = Mutex::new(None);

fn paths(app: &AppHandle) -> Option<&'static Paths> {
    PATHS
        .get_or_init(|| {
            let res = |rel: &str| {
                app.path()
                    .resolve(rel, tauri::path::BaseDirectory::Resource)
                    .ok()
            };
            let p = Paths {
                script: res("resources/mediaremote/mediaremote-adapter.pl")?,
                framework: res("resources/mediaremote/MediaRemoteAdapter.framework")?,
                test_client: res("resources/mediaremote/MediaRemoteAdapterTestClient")?,
            };
            if !p.script.exists() || !p.framework.join("MediaRemoteAdapter").exists() {
                warn!("[media] adapter resources missing; Now Playing disabled");
                return None;
            }
            Some(p)
        })
        .as_ref()
}

fn perl(p: &Paths) -> Command {
    let mut c = Command::new("/usr/bin/perl");
    c.arg(&p.script).arg(&p.framework);
    c.stdin(Stdio::null());
    c
}

/// Does the adapter still work on this OS? Runs the bundled test client
/// (exit 0 = yes). Copies of resources may lose the executable bit; set it.
fn adapter_works(p: &Paths) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&p.test_client, std::fs::Permissions::from_mode(0o755));
    }
    match perl(p)
        .arg(&p.test_client)
        .arg("test")
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
    {
        Ok(o) if o.status.success() => true,
        Ok(o) => {
            warn!(
                "[media] adapter self-test failed: {}",
                String::from_utf8_lossy(&o.stderr).trim()
            );
            false
        }
        Err(e) => {
            warn!("[media] adapter self-test could not run: {e}");
            false
        }
    }
}

/// Start streaming now-playing updates to the island. Call once at startup;
/// the stream is restarted with backoff if the helper exits.
pub fn start(app: &AppHandle) {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        return;
    }
    #[cfg(target_os = "macos")]
    {
        let app = app.clone();
        // Everything off the setup path: the self-test alone is a perl start.
        std::thread::Builder::new()
            .name("now-playing".into())
            .spawn(move || {
                let Some(p) = paths(&app) else { return };
                if !adapter_works(p) {
                    info!("[media] Now Playing unavailable on this system");
                    return;
                }
                crate::native_notch::set_media_callback(on_island_media_action);
                let _ = APP.set(app.clone());
                let mut backoff = Duration::from_secs(1);
                loop {
                    match stream_once(p) {
                        Ok(()) => backoff = Duration::from_secs(1),
                        Err(e) => warn!("[media] stream ended: {e}"),
                    }
                    push(&Map::new());
                    std::thread::sleep(backoff);
                    backoff = (backoff * 2).min(Duration::from_secs(60));
                }
            })
            .ok();
    }
}

fn stream_once(p: &Paths) -> Result<(), String> {
    let mut child = perl(p)
        .arg("stream")
        .arg("--micros")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("spawn: {e}"))?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let mut state = Map::new();
    let mut artwork_key = 0u64;
    for line in BufReader::new(stdout).lines() {
        let line = line.map_err(|e| format!("read: {e}"))?;
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(payload) = msg.get("payload").and_then(|v| v.as_object()) else { continue };
        let diff = msg.get("diff").and_then(|v| v.as_bool()).unwrap_or(false);
        if diff {
            for (k, v) in payload {
                if v.is_null() {
                    state.remove(k);
                } else {
                    state.insert(k.clone(), v.clone());
                }
            }
        } else {
            state = payload.clone();
        }
        // Artwork is a few hundred KB of base64; only ship it when it changes.
        let key = state
            .get("artworkData")
            .and_then(|v| v.as_str())
            .map(|s| {
                use std::hash::{Hash, Hasher};
                let mut h = std::collections::hash_map::DefaultHasher::new();
                s.len().hash(&mut h);
                s.get(..64).unwrap_or(s).hash(&mut h);
                s.get(s.len().saturating_sub(64)..).unwrap_or("").hash(&mut h);
                // Keep it inside i64 so every JSON reader agrees on it.
                h.finish() >> 1
            })
            .unwrap_or(0);
        let mut out = state.clone();
        out.insert("artworkKey".into(), Value::from(key));
        if key == artwork_key {
            out.remove("artworkData");
        }
        artwork_key = key;
        *STATE.lock().unwrap_or_else(|e| e.into_inner()) = Some(state.clone());
        push(&out);
    }
    let status = child.wait().map_err(|e| format!("wait: {e}"))?;
    Err(format!("helper exited: {status}"))
}

fn push(state: &Map<String, Value>) {
    debug!(
        "[media] {} — {}",
        state.get("title").and_then(|v| v.as_str()).unwrap_or("(nothing)"),
        state.get("playing").and_then(|v| v.as_bool()).unwrap_or(false)
    );
    crate::native_notch::set_now_playing(&Value::Object(state.clone()).to_string());
}

/// MediaRemote command ids (see adapter README): 2 toggle, 4 next, 5 previous.
fn send(p: &Paths, args: &[String]) {
    let mut c = perl(p);
    c.args(args).stdout(Stdio::null()).stderr(Stdio::null());
    if let Err(e) = c.status() {
        warn!("[media] send {args:?} failed: {e}");
    }
}

#[cfg(target_os = "macos")]
static APP: OnceLock<AppHandle> = OnceLock::new();

/// Transport actions from the island's player card.
#[cfg(target_os = "macos")]
extern "C" fn on_island_media_action(action: i32, arg: i64) {
    let Some(app) = APP.get() else { return };
    let Some(p) = paths(app) else { return };
    let args: Vec<String> = match action {
        1 => vec!["send".into(), "2".into()],
        2 => vec!["send".into(), "4".into()],
        3 => vec!["send".into(), "5".into()],
        4 => vec!["seek".into(), arg.max(0).to_string()],
        _ => return,
    };
    // Off the AppKit thread: perl start-up is tens of milliseconds.
    std::thread::spawn(move || send(p, &args));
}
