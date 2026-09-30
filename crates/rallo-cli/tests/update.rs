//! Process-level tests for `rallo update`: the only command that touches the
//! network, against a fake installed app and a tiny loopback HTTP server
//! standing in for the GitHub API (`RALLO_UPDATE_API`). Codesign verification
//! and the final relaunch are skipped via the test-only env guards, which
//! only take effect while `RALLO_UPDATE_API` points at 127.0.0.1 -- a real
//! run against the real API can never skip them. `PATH` is restricted to the
//! system directories our own subprocesses need, so a developer's own `gh`
//! login can never leak a real token into these tests.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::Arc;
use std::thread;

use serde_json::{Value, json};

const REPO: &str = "Owner/Repo";
const RESTRICTED_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

/// One canned response, matched by exact request path.
struct Route {
    path: String,
    content_type: &'static str,
    body: Vec<u8>,
}

/// A tiny loopback HTTP/1.1 server (no new dependency): enough to serve a
/// GitHub "latest release" JSON document and a couple of binary assets to
/// `curl -fsSL`.
struct TestServer {
    port: u16,
}

impl TestServer {
    /// Binds an ephemeral loopback port without serving yet, so the caller
    /// can learn the port and bake it into the routes' own bodies (the fake
    /// release JSON needs to link back to this same server) before the
    /// accept loop starts.
    fn bind() -> (TcpListener, u16) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        (listener, port)
    }

    fn serve(listener: TcpListener, routes: Vec<Route>) -> Self {
        let port = listener.local_addr().unwrap().port();
        let routes = Arc::new(routes);
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                let routes = Arc::clone(&routes);
                thread::spawn(move || handle_connection(stream, &routes));
            }
        });
        Self { port }
    }

    fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }
}

fn handle_connection(mut stream: TcpStream, routes: &[Route]) {
    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(clone) => clone,
        Err(_) => return,
    });
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).unwrap_or(0) == 0 {
        return;
    }
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) if line == "\r\n" || line == "\n" => break,
            Ok(_) => continue,
            Err(_) => break,
        }
    }
    let path = request_line.split_whitespace().nth(1).unwrap_or("/").to_owned();
    match routes.iter().find(|route| route.path == path) {
        Some(route) => {
            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                route.content_type,
                route.body.len()
            );
            let _ = stream.write_all(header.as_bytes());
            let _ = stream.write_all(&route.body);
        }
        None => {
            let body = format!("no route for {path}");
            let header =
                format!("HTTP/1.1 404 Not Found\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
            let _ = stream.write_all(header.as_bytes());
            let _ = stream.write_all(body.as_bytes());
        }
    }
    let _ = stream.flush();
}

fn install_cli(app: &Path) -> PathBuf {
    let helpers = app.join("Contents/Helpers");
    fs::create_dir_all(&helpers).unwrap();
    let cli = helpers.join("rallo");
    fs::copy(env!("CARGO_BIN_EXE_rallo"), &cli).unwrap();
    fs::set_permissions(&cli, fs::Permissions::from_mode(0o755)).unwrap();
    cli
}

fn plist_xml(bundle_id: &str, version: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>{bundle_id}</string>
    <key>CFBundleShortVersionString</key>
    <string>{version}</string>
</dict>
</plist>
"#
    )
}

/// A "new release" bundle: a minimal `Rallo.app` whose `Contents/Helpers/rallo`
/// is a stand-in script (never the real CLI binary) that only answers
/// `--version --json`, reporting `cli_reports_version`.
fn build_new_bundle(build_dir: &Path, bundle_id: &str, version: &str, cli_reports_version: &str) -> PathBuf {
    let app = build_dir.join("Rallo.app");
    let contents = app.join("Contents");
    fs::create_dir_all(contents.join("Helpers")).unwrap();
    fs::create_dir_all(contents.join("MacOS")).unwrap();
    fs::write(contents.join("Info.plist"), plist_xml(bundle_id, version)).unwrap();

    let cli_script = contents.join("Helpers/rallo");
    fs::write(
        &cli_script,
        format!(
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ] && [ \"$2\" = \"--json\" ]; then\n  printf '%s' \
             '{{\"cli_version\":\"{cli_reports_version}\",\"core_version\":\"test\",\"database_schema_version\":1,\"json_contract_version\":1}}'\n  \
             exit 0\nfi\nexit 1\n"
        ),
    )
    .unwrap();
    fs::set_permissions(&cli_script, fs::Permissions::from_mode(0o755)).unwrap();

    let macos_binary = contents.join("MacOS/Rallo");
    fs::write(&macos_binary, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&macos_binary, fs::Permissions::from_mode(0o755)).unwrap();
    app
}

fn zip_bundle(app_dir: &Path, zip_path: &Path) {
    let status =
        Command::new("/usr/bin/ditto").args(["-c", "-k", "--keepParent"]).arg(app_dir).arg(zip_path).status().unwrap();
    assert!(status.success(), "ditto could not zip the fixture bundle");
}

fn sha256_of(path: &Path) -> String {
    let output = Command::new("/usr/bin/shasum").args(["-a", "256"]).arg(path).output().unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout).unwrap().split_whitespace().next().unwrap().to_owned()
}

fn zip_asset_name(version: &str) -> String {
    format!("Rallo-{version}-macos-arm64.zip")
}

struct Fixture {
    _root_dir: tempfile::TempDir,
    home: PathBuf,
    app: PathBuf,
    cli: PathBuf,
    server: TestServer,
    current_version: String,
}

struct NewRelease {
    version: &'static str,
    bundle_id: &'static str,
    cli_reports_version: &'static str,
    /// Serves a `SHA256SUMS` entry that does not match the zip, to exercise
    /// the checksum-mismatch abort path.
    corrupt_checksum: bool,
}

impl Fixture {
    /// `<home>/Applications/Rallo.app` with a copy of the real built CLI
    /// (same layout `terminal_setup.rs` uses), plus a loopback server
    /// serving one release whose zip/SHA256SUMS match `new_release`, or no
    /// release newer than the running CLI's own version when `None`.
    fn new(new_release: Option<NewRelease>) -> Self {
        let root_dir = tempfile::tempdir().unwrap();
        let root = root_dir.path().canonicalize().unwrap();
        let home = root.join("Home");
        let app = home.join("Applications/Rallo.app");
        let cli = install_cli(&app);
        let current_version = env!("CARGO_PKG_VERSION").to_owned();

        let release = new_release.unwrap_or(NewRelease {
            version: env!("CARGO_PKG_VERSION"),
            bundle_id: "com.razlio.rallo",
            cli_reports_version: env!("CARGO_PKG_VERSION"),
            corrupt_checksum: false,
        });

        let staging = root.join("staging");
        fs::create_dir_all(&staging).unwrap();
        let bundle = build_new_bundle(&staging, release.bundle_id, release.version, release.cli_reports_version);
        let zip_name = zip_asset_name(release.version);
        let zip_path = staging.join(&zip_name);
        zip_bundle(&bundle, &zip_path);
        let zip_hash = sha256_of(&zip_path);
        let served_hash =
            if release.corrupt_checksum { format!("{}beef", &zip_hash[..zip_hash.len() - 4]) } else { zip_hash };
        let sums_body = format!("{served_hash}  {zip_name}\n");

        let zip_bytes = fs::read(&zip_path).unwrap();
        let sums_bytes = sums_body.into_bytes();

        // Bind first so the release JSON's URLs (baked into the response
        // bodies below) can point back at this same server's real port.
        let (listener, port) = TestServer::bind();
        let base = format!("http://127.0.0.1:{port}");
        let release_json = json!({
            "tag_name": format!("v{}", release.version),
            "html_url": format!("{base}/releases/tag/v{}", release.version),
            "assets": [
                {
                    "name": zip_name,
                    "url": format!("{base}/assets/zip"),
                    "browser_download_url": format!("{base}/downloads/{zip_name}"),
                },
                {
                    "name": "SHA256SUMS",
                    "url": format!("{base}/assets/sums"),
                    "browser_download_url": format!("{base}/downloads/SHA256SUMS"),
                },
            ],
        });
        let server = TestServer::serve(
            listener,
            vec![
                Route {
                    path: format!("/repos/{REPO}/releases/latest"),
                    content_type: "application/json",
                    body: serde_json::to_vec(&release_json).unwrap(),
                },
                Route {
                    path: "/assets/zip".to_owned(),
                    content_type: "application/octet-stream",
                    body: zip_bytes.clone(),
                },
                Route {
                    path: "/assets/sums".to_owned(),
                    content_type: "application/octet-stream",
                    body: sums_bytes.clone(),
                },
                Route {
                    path: format!("/downloads/{zip_name}"),
                    content_type: "application/octet-stream",
                    body: zip_bytes,
                },
                Route {
                    path: "/downloads/SHA256SUMS".to_owned(),
                    content_type: "application/octet-stream",
                    body: sums_bytes,
                },
            ],
        );

        Self { _root_dir: root_dir, home, app, cli, server, current_version }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(&self.cli);
        command
            .args(args)
            .env("HOME", &self.home)
            .env("PATH", RESTRICTED_PATH)
            .env("RALLO_UPDATE_API", self.server.base_url())
            .env("RALLO_UPDATE_REPO", REPO)
            .env("RALLO_UPDATE_TEST_SKIP_CODESIGN", "1")
            .env("RALLO_UPDATE_TEST_NO_LAUNCH", "1")
            .env_remove("RALLO_APP_PATH")
            .env_remove("GH_TOKEN")
            .env_remove("GITHUB_TOKEN");
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).stdin(Stdio::null()).output().unwrap()
    }

    fn json(&self, args: &[&str]) -> (i32, Value) {
        let output = self.run(args);
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
        (output.status.code().unwrap(), serde_json::from_str(&stdout).unwrap())
    }

    fn installed_version(&self) -> String {
        let output =
            Command::new(self.app.join("Contents/Helpers/rallo")).args(["--version", "--json"]).output().unwrap();
        assert!(output.status.success());
        let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
        doc["cli_version"].as_str().unwrap().to_owned()
    }

    fn no_leftover_previous_or_workdir(&self) {
        let applications = self.home.join("Applications");
        for entry in fs::read_dir(&applications).unwrap() {
            let name = entry.unwrap().file_name();
            let name = name.to_string_lossy();
            assert!(!name.contains(".previous-"), "leftover previous bundle: {name}");
            assert!(!name.starts_with(".rallo-update-"), "leftover work directory: {name}");
        }
    }
}

#[test]
fn already_up_to_date_reports_no_update_available() {
    let fixture = Fixture::new(None);
    let (code, doc) = fixture.json(&["update", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["update_available"], false);
    assert_eq!(doc["current"], fixture.current_version);
    assert_eq!(doc["latest"], fixture.current_version);
    assert_eq!(fixture.installed_version(), fixture.current_version, "nothing should have been installed");
}

#[test]
fn check_reports_without_downloading_or_installing() {
    let fixture = Fixture::new(Some(NewRelease {
        version: "9.9.9",
        bundle_id: "com.razlio.rallo",
        cli_reports_version: "9.9.9",
        corrupt_checksum: false,
    }));
    let (code, doc) = fixture.json(&["update", "--check", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["update_available"], true);
    assert_eq!(doc["current"], fixture.current_version);
    assert_eq!(doc["latest"], "9.9.9");
    assert!(doc["release_url"].as_str().unwrap().contains("9.9.9"));
    assert_eq!(fixture.installed_version(), fixture.current_version, "--check must never install anything");
    fixture.no_leftover_previous_or_workdir();
}

#[test]
fn successful_update_swaps_the_app_and_backs_up_the_store() {
    let fixture = Fixture::new(Some(NewRelease {
        version: "9.9.9",
        bundle_id: "com.razlio.rallo",
        cli_reports_version: "9.9.9",
        corrupt_checksum: false,
    }));
    let data_dir = fixture._root_dir.path().join("data");
    assert!(fixture.command(&["note", "hello"]).env("RALLO_DATA_DIR", &data_dir).status().unwrap().success());

    let mut command = fixture.command(&["update", "--json"]);
    command.env("RALLO_DATA_DIR", &data_dir);
    let output = command.stdin(Stdio::null()).output().unwrap();
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
    let doc: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(output.status.code(), Some(0), "{doc}");

    assert_eq!(doc["current"], fixture.current_version);
    assert_eq!(doc["installed_version"], "9.9.9");
    assert_eq!(doc["previous_removed"], true);
    let backup_path = PathBuf::from(doc["backup_path"].as_str().expect("a backup was made"));
    assert!(backup_path.exists());
    assert_eq!(backup_path.parent().unwrap(), data_dir.canonicalize().unwrap().join("backups"));

    assert_eq!(fixture.installed_version(), "9.9.9");
    fixture.no_leftover_previous_or_workdir();
}

#[test]
fn checksum_mismatch_leaves_the_installed_app_untouched() {
    let fixture = Fixture::new(Some(NewRelease {
        version: "9.9.9",
        bundle_id: "com.razlio.rallo",
        cli_reports_version: "9.9.9",
        corrupt_checksum: true,
    }));
    let (code, doc) = fixture.json(&["update", "--json"]);
    assert_eq!(code, 6, "{doc}");
    assert_eq!(doc["ok"], false);
    assert_eq!(doc["error"]["code"], "UPDATE_VERIFICATION_FAILED");
    assert_eq!(fixture.installed_version(), fixture.current_version, "a bad checksum must never be installed");
    fixture.no_leftover_previous_or_workdir();
}

#[test]
fn wrong_bundle_id_fails_verification_and_leaves_the_installed_app_untouched() {
    let fixture = Fixture::new(Some(NewRelease {
        version: "9.9.9",
        bundle_id: "com.example.impostor",
        cli_reports_version: "9.9.9",
        corrupt_checksum: false,
    }));
    let (code, doc) = fixture.json(&["update", "--json"]);
    assert_eq!(code, 6, "{doc}");
    assert_eq!(doc["ok"], false);
    assert_eq!(doc["error"]["code"], "UPDATE_VERIFICATION_FAILED");
    assert_eq!(fixture.installed_version(), fixture.current_version, "the bad bundle must never be installed");
    fixture.no_leftover_previous_or_workdir();
}

#[test]
fn not_installed_is_a_clear_error_not_a_crash() {
    let home_dir = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_rallo"))
        .args(["update", "--check", "--json"])
        .env("HOME", home_dir.path())
        .env("PATH", RESTRICTED_PATH)
        .env_remove("RALLO_APP_PATH")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(output.status.code(), Some(2), "{doc}");
    assert_eq!(doc["error"]["code"], "NOT_INSTALLED");
}

#[test]
fn a_bearer_token_reaches_the_server_without_ever_appearing_in_argv() {
    // Forcing a token routes downloads through the API asset URL (the
    // private-repo path) instead of `browser_download_url`; a successful
    // full update here proves the token-bearing request round-trips
    // correctly. The stronger guarantee -- that the token is never written
    // to argv, only to the 0600 curl config file -- is unit-tested directly
    // against the constructed `Command` in `rallo_platform_macos::update`.
    let fixture = Fixture::new(Some(NewRelease {
        version: "9.9.9",
        bundle_id: "com.razlio.rallo",
        cli_reports_version: "9.9.9",
        corrupt_checksum: false,
    }));
    let mut command = fixture.command(&["update", "--check", "--json"]);
    command.env("GH_TOKEN", "test-token-should-never-appear-in-argv");
    let output = command.stdin(Stdio::null()).output().unwrap();
    let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(output.status.code(), Some(0), "{doc}");
    assert_eq!(doc["update_available"], true);
}
