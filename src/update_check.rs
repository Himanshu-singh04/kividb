//! Asking kividb.io, once at startup, whether there is a newer release — and
//! showing whatever announcement it has.
//!
//! One HTTPS request, made from a thread of its own; what it finds is the
//! first thing the server prints, above the banner. Startup waits for it at
//! most `BANNER_WAIT`, and a slower reply is dropped, so a slow or absent
//! network delays startup by that much at worst and never touches a client.
//! What is sent is the running version, the OS, the architecture and
//! the build variant — nothing that identifies the machine or its data. Any
//! failure (no network, DNS, TLS, a timeout, a malformed reply) is logged at
//! debug level and otherwise ignored.
//!
//! The reply is JSON; every field is optional:
//!
//! ```text
//! {
//!   "latest":  "1.0.6",                       newest release; a notice is shown
//!                                             only if it is newer than this build
//!   "url":     "https://kividb.io/downloads", where to get it
//!   "message": "one or more lines of text",   shown as is, at most 5 lines
//!   "art":     "lines of ASCII art"           shown as is, at most 15 lines
//! }
//! ```
//!
//! Whatever comes back is printed to the operator's terminal or log, so it is
//! cleaned first: control characters — terminal escape sequences above all —
//! and bidirectional-text overrides are removed, and every line and the
//! number of lines are capped. The file can say what it likes; it cannot
//! move the cursor, recolour, rewrite or flood what the operator sees.
//!
//! Turned off by `update-check no` in the config file, `--update-check no`,
//! or `KIVIDB_NO_UPDATE_CHECK=1`; and never made by a debug build, or when
//! `CI` is set in the environment. docs/UPDATE_CHECK.md has the details.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

/// Where the check is made unless `update-check-url` says otherwise.
pub const DEFAULT_URL: &str = "https://kividb.io/api/release-check";

/// For each connection attempt, and each read and write after it.
const TIMEOUT: Duration = Duration::from_secs(4);
/// How long startup waits for the reply, at most, so the notice is the first
/// thing printed. The only time the check can hold up startup.
const BANNER_WAIT: Duration = Duration::from_millis(1500);
/// A reply larger than this is not an announcement.
const MAX_REPLY: usize = 64 * 1024;

const MESSAGE_LINES: usize = 5;
const ART_LINES: usize = 15;
const LINE_WIDTH: usize = 120;

/// What the server was told, and what it said back.
#[derive(Debug, Default, PartialEq)]
pub struct Announcement {
    pub latest: Option<String>,
    pub url: Option<String>,
    pub message: Vec<String>,
    pub art: Vec<String>,
}

/// Whether the check is to be made at all.
pub fn enabled(config: &crate::config::Config) -> bool {
    if cfg!(debug_assertions) || !config.update_check {
        return false;
    }
    let set = |name: &str| {
        std::env::var(name)
            .is_ok_and(|v| !v.is_empty() && v != "0" && !v.eq_ignore_ascii_case("false"))
    };
    !set("KIVIDB_NO_UPDATE_CHECK") && !set("CI")
}

/// A check under way: started early, shown by the banner.
pub struct Pending {
    reply: mpsc::Receiver<Result<Announcement, String>>,
    deadline: Instant,
}

/// Start the check on a thread of its own. `None` if it is turned off.
pub fn start(config: &crate::config::Config) -> Option<Pending> {
    if !enabled(config) {
        return None;
    }
    let url = config.update_check_url.clone();
    let (tx, reply) = mpsc::channel();
    std::thread::Builder::new()
        .name("update-check".into())
        .spawn(move || {
            let _ = tx.send(check(&url));
        })
        .ok()?;
    Some(Pending {
        reply,
        deadline: Instant::now() + BANNER_WAIT,
    })
}

/// Print what the check found, before the banner. Waits until `BANNER_WAIT`
/// after the check started; a reply later than that is dropped rather than
/// printed somewhere among the log lines.
pub fn show(pending: Pending) {
    let wait = pending.deadline.saturating_duration_since(Instant::now());
    let error = match pending.reply.recv_timeout(wait) {
        Ok(Ok(announcement)) => {
            let lines = render(env!("CARGO_PKG_VERSION"), &announcement);
            if !lines.is_empty() {
                for line in lines {
                    println!("{line}");
                }
                println!();
            }
            return;
        }
        Ok(Err(e)) => e,
        Err(_) => format!("no reply within {} ms", BANNER_WAIT.as_millis()),
    };
    log_debug!("update check: {error}");
}

/// The build's variant, as the release names it.
pub fn variant() -> &'static str {
    match (cfg!(feature = "lua"), cfg!(feature = "tls")) {
        (true, true) => "full",
        (true, false) => "lua",
        (false, true) => "tls",
        (false, false) => "default",
    }
}

fn check(url: &str) -> Result<Announcement, String> {
    let (host, path) = url
        .strip_prefix("https://")
        .map(|rest| {
            rest.split_once('/')
                .map_or((rest, "/".to_string()), |(h, p)| (h, format!("/{p}")))
        })
        .ok_or_else(|| format!("'{url}' is not an https:// URL"))?;
    let (host_name, port) = match host.rsplit_once(':') {
        Some((name, port)) => (
            name,
            port.parse::<u16>()
                .map_err(|_| format!("bad port in '{url}'"))?,
        ),
        None => (host, 443),
    };
    let separator = if path.contains('?') { '&' } else { '?' };
    let path = format!(
        "{path}{separator}version={}&os={}&arch={}&build={}",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH,
        variant()
    );

    let body = https_get(host_name, port, &path)?;
    parse(&body)
}

fn https_get(host: &str, port: u16, path: &str) -> Result<Vec<u8>, String> {
    let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let server_name = rustls::pki_types::ServerName::try_from(host.to_string())
        .map_err(|e| format!("bad host '{host}': {e}"))?;
    let connection = rustls::ClientConnection::new(Arc::new(config), server_name)
        .map_err(|e| format!("TLS: {e}"))?;

    let addrs = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("resolving {host}: {e}"))?;
    let mut last = format!("no address for {host}");
    let mut socket = None;
    for addr in addrs {
        match TcpStream::connect_timeout(&addr, TIMEOUT) {
            Ok(s) => {
                socket = Some(s);
                break;
            }
            Err(e) => last = format!("connecting to {addr}: {e}"),
        }
    }
    let socket = socket.ok_or(last)?;
    socket
        .set_read_timeout(Some(TIMEOUT))
        .map_err(|e| e.to_string())?;
    socket
        .set_write_timeout(Some(TIMEOUT))
        .map_err(|e| e.to_string())?;

    let mut tls = rustls::StreamOwned::new(connection, socket);
    // HTTP/1.0: the reply is the body to the end of the connection, never
    // chunked.
    let request = format!(
        "GET {path} HTTP/1.0\r\nHost: {host}\r\nUser-Agent: kividb/{}\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
        env!("CARGO_PKG_VERSION")
    );
    tls.write_all(request.as_bytes())
        .map_err(|e| format!("sending: {e}"))?;

    let mut reply = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match tls.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                reply.extend_from_slice(&chunk[..n]);
                if reply.len() > MAX_REPLY {
                    return Err("reply too large".into());
                }
            }
            // A server that closes without TLS's close_notify: what has
            // arrived is the reply.
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(format!("reading: {e}")),
        }
    }

    let head_end = reply
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("no HTTP header in the reply")?;
    let head = String::from_utf8_lossy(&reply[..head_end]);
    let status = head
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or("no HTTP status in the reply")?;
    if status != 200 {
        return Err(format!("HTTP {status}"));
    }
    Ok(reply[head_end + 4..].to_vec())
}

/// Read the reply. Fields that are missing, or of the wrong type, are
/// treated as not given.
pub fn parse(body: &[u8]) -> Result<Announcement, String> {
    let json: serde_json::Value =
        serde_json::from_slice(body).map_err(|e| format!("not JSON: {e}"))?;
    let text = |key: &str| json.get(key).and_then(|v| v.as_str()).map(str::to_string);
    let one_line = |value: Option<String>| {
        value
            .map(|v| clean_line(v.lines().next().unwrap_or_default()))
            .filter(|v| !v.is_empty())
    };
    Ok(Announcement {
        latest: one_line(text("latest")),
        url: one_line(text("url")),
        message: clean_block(
            text("message").as_deref().unwrap_or_default(),
            MESSAGE_LINES,
        ),
        art: clean_block(text("art").as_deref().unwrap_or_default(), ART_LINES),
    })
}

/// A line as it may be shown: no control characters (so no terminal escape
/// sequences), no bidirectional-text overrides, tabs as spaces, trailing
/// spaces removed, at most `LINE_WIDTH` characters.
fn clean_line(line: &str) -> String {
    let cleaned: String = line
        .chars()
        .map(|c| if c == '\t' { ' ' } else { c })
        .filter(|c| {
            !c.is_control()
                && !matches!(*c, '\u{200E}' | '\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
        })
        .take(LINE_WIDTH)
        .collect();
    cleaned.trim_end().to_string()
}

fn clean_block(text: &str, max_lines: usize) -> Vec<String> {
    let mut lines: Vec<String> = text.lines().take(max_lines).map(clean_line).collect();
    while lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    lines
}

/// A version as numbers, and whether it is a pre-release (`1.0.5-rc1`).
fn version_key(version: &str) -> Option<(Vec<u64>, bool, String)> {
    let version = version.trim().trim_start_matches('v');
    let (core, pre) = match version.split_once('-') {
        Some((core, pre)) => (core, pre.to_string()),
        None => (version, String::new()),
    };
    let numbers = core
        .split('.')
        .map(|n| n.parse::<u64>().ok())
        .collect::<Option<Vec<_>>>()?;
    Some((numbers, !pre.is_empty(), pre))
}

/// Whether `latest` is a newer release than `running`. A release is newer
/// than its own release candidates; two release candidates of one version
/// are compared by their suffix. Anything that cannot be read as a version
/// is not newer.
pub fn is_newer(latest: &str, running: &str) -> bool {
    let (Some(latest), Some(running)) = (version_key(latest), version_key(running)) else {
        return false;
    };
    let width = latest.0.len().max(running.0.len());
    let pad = |mut v: Vec<u64>| {
        v.resize(width, 0);
        v
    };
    match pad(latest.0).cmp(&pad(running.0)) {
        std::cmp::Ordering::Greater => true,
        std::cmp::Ordering::Less => false,
        std::cmp::Ordering::Equal => match (latest.1, running.1) {
            (false, true) => true,
            (true, true) => latest.2 > running.2,
            _ => false,
        },
    }
}

/// What is printed, line by line; nothing if there is nothing to say.
pub fn render(running: &str, announcement: &Announcement) -> Vec<String> {
    let mut body: Vec<String> = Vec::new();
    if let Some(latest) = announcement
        .latest
        .as_deref()
        .filter(|l| is_newer(l, running))
    {
        body.push(format!(
            "A new KiviDB release is available: {latest} (you are running {running})."
        ));
        match announcement.url.as_deref() {
            Some(url) => body.push(format!("Download it from {url}")),
            None => body.push("Download it from https://kividb.io/downloads".to_string()),
        }
    }
    if !announcement.message.is_empty() {
        if !body.is_empty() {
            body.push(String::new());
        }
        body.extend(announcement.message.iter().cloned());
    }
    let mut out = Vec::new();
    if body.is_empty() && announcement.art.is_empty() {
        return out;
    }
    out.push(String::new());
    out.extend(announcement.art.iter().map(|l| format!("  {l}")));
    if !body.is_empty() {
        let width = body.iter().map(|l| l.chars().count()).max().unwrap_or(0);
        out.push(format!("  +{}+", "-".repeat(width + 2)));
        for line in &body {
            let pad = width - line.chars().count();
            out.push(format!("  | {line}{} |", " ".repeat(pad)));
        }
        out.push(format!("  +{}+", "-".repeat(width + 2)));
    }
    out.push(String::new());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_as_releases_do() {
        assert!(is_newer("1.0.6", "1.0.5"));
        assert!(is_newer("1.1.0", "1.0.9"));
        assert!(is_newer("1.0.10", "1.0.9"));
        assert!(is_newer("v2.0.0", "1.9.9"));
        assert!(is_newer("1.0.5", "1.0.5-rc1"));
        assert!(is_newer("1.0.5-rc2", "1.0.5-rc1"));
        assert!(!is_newer("1.0.5", "1.0.5"));
        assert!(!is_newer("1.0.4", "1.0.5"));
        assert!(!is_newer("1.0.5-rc1", "1.0.5"));
        assert!(!is_newer("nonsense", "1.0.5"));
        assert!(!is_newer("1.0.6", "nonsense"));
    }

    #[test]
    fn what_comes_back_cannot_reach_the_terminal() {
        let body = br#"{
            "latest": "1.0.6\u001b[2J",
            "url": "https://kividb.io/downloads\nsecond line",
            "message": "Hello\u001b[31m red\u0007\nline two\tend   \n\u202eevil",
            "art": "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np\nq"
        }"#;
        let a = parse(body).unwrap();
        assert_eq!(a.latest.as_deref(), Some("1.0.6[2J"));
        assert_eq!(a.url.as_deref(), Some("https://kividb.io/downloads"));
        assert_eq!(a.message, ["Hello[31m red", "line two end", "evil"]);
        assert_eq!(a.art.len(), ART_LINES);
        for line in render("1.0.5", &a) {
            assert!(!line.chars().any(|c| c.is_control()), "{line:?}");
        }
        let long = format!(r#"{{"message": "{}"}}"#, "x".repeat(500));
        assert_eq!(parse(long.as_bytes()).unwrap().message[0].len(), LINE_WIDTH);
    }

    #[test]
    fn nothing_is_shown_when_there_is_nothing_to_say() {
        let current = parse(br#"{"latest": "1.0.5"}"#).unwrap();
        assert!(render("1.0.5", &current).is_empty());
        assert!(render("1.0.5", &parse(b"{}").unwrap()).is_empty());
        assert!(parse(b"<html>").is_err());
        // Wrong types are as if not given.
        assert_eq!(
            parse(br#"{"latest": 7, "message": ["x"]}"#).unwrap(),
            Announcement::default()
        );
    }

    #[test]
    fn a_newer_release_is_announced_with_the_message() {
        let a =
            parse(br#"{"latest":"1.0.6","url":"https://kividb.io/d","message":"Try the cloud"}"#)
                .unwrap();
        let shown = render("1.0.5", &a).join("\n");
        assert!(
            shown.contains("A new KiviDB release is available: 1.0.6 (you are running 1.0.5)."),
            "{shown}"
        );
        assert!(
            shown.contains("Download it from https://kividb.io/d"),
            "{shown}"
        );
        assert!(shown.contains("Try the cloud"), "{shown}");
        // A message alone, with the build up to date, is still shown.
        let only = parse(br#"{"latest":"1.0.5","message":"Try the cloud"}"#).unwrap();
        let shown = render("1.0.5", &only).join("\n");
        assert!(
            shown.contains("Try the cloud") && !shown.contains("new KiviDB release"),
            "{shown}"
        );
    }
}
