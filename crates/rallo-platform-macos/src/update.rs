//! Mechanics for `rallo update` (distribution build, no Apple Developer ID):
//! GitHub Releases over the system `curl`, checksum/bundle/signature
//! verification, quitting the running app, an atomic bundle swap with
//! rollback, and a background relaunch identical to the CLI's ordinary app
//! launch. Every network and subprocess boundary lives here so `rallo-cli`
//! stays free of HTTP/TLS and shell-quoting concerns; `rallo-cli` resolves
//! the data directory and backs up the store (that needs `rallo-core`, which
//! this crate does not depend on).
//!
//! Nothing here runs unless `rallo update` is invoked directly: there is no
//! background check and no automatic updater.

use std::env;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

use crate::launch::{self, LaunchError};
use crate::terminal_command;

/// The GitHub repository releases are published to, unless overridden.
pub const DEFAULT_REPO: &str = "Eyakub/Rallo";
pub const DEFAULT_API_BASE: &str = "https://api.github.com";
/// Overrides the API base URL (tests point this at a local HTTP server).
pub const API_BASE_ENV: &str = "RALLO_UPDATE_API";
/// Overrides the repository slug (tests use their own fixture repo name).
pub const REPO_ENV: &str = "RALLO_UPDATE_REPO";
/// Only honoured when `RALLO_UPDATE_API` points at `http://127.0.0.1`: skips
/// `codesign --verify` for a fixture bundle that is never actually signed.
pub const TEST_SKIP_CODESIGN_ENV: &str = "RALLO_UPDATE_TEST_SKIP_CODESIGN";
/// Only honoured when `RALLO_UPDATE_API` points at `http://127.0.0.1`: skips
/// the final relaunch so tests never spawn a real app.
pub const TEST_NO_LAUNCH_ENV: &str = "RALLO_UPDATE_TEST_NO_LAUNCH";

/// How long to wait for a running Rallo to quit after `SIGTERM` before giving
/// up rather than escalating to `SIGKILL`.
const QUIT_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, thiserror::Error)]
pub enum UpdateError {
    #[error("{0}")]
    Check(String),
    #[error("{0}")]
    Download(String),
    #[error("{0}")]
    Verification(String),
    #[error(
        "Rallo is still running and did not quit within 5 seconds of being asked to; try again or quit it manually"
    )]
    AppBusy,
    #[error("{0}")]
    Install(String),
}

impl UpdateError {
    /// Stable machine-readable error code (part of the CLI JSON contract).
    pub fn code(&self) -> &'static str {
        match self {
            Self::Check(_) => "UPDATE_CHECK_FAILED",
            Self::Download(_) => "UPDATE_DOWNLOAD_FAILED",
            Self::Verification(_) => "UPDATE_VERIFICATION_FAILED",
            Self::AppBusy => "UPDATE_APP_BUSY",
            Self::Install(_) => "UPDATE_INSTALL_FAILED",
        }
    }
}

/// Resolved settings for one `rallo update` invocation: where to ask, which
/// repository, and how to authenticate.
pub struct Config {
    pub api_base: String,
    pub repo: String,
    pub token: Option<String>,
    pub user_agent: String,
}

impl Config {
    /// `RALLO_UPDATE_API`/`RALLO_UPDATE_REPO` override the defaults (tests);
    /// the token comes from `GH_TOKEN`/`GITHUB_TOKEN`, falling back to `gh
    /// auth token` when `gh` is on PATH (failure there is silently ignored --
    /// a public repo needs no token at all).
    pub fn from_env(current_version: &str) -> Self {
        let api_base = non_empty_env(API_BASE_ENV).unwrap_or_else(|| DEFAULT_API_BASE.to_owned());
        let repo = non_empty_env(REPO_ENV).unwrap_or_else(|| DEFAULT_REPO.to_owned());
        Self { api_base, repo, token: github_token(), user_agent: format!("rallo/{current_version}") }
    }

    /// Whether this run's API base is the loopback test server: the only
    /// context in which `TEST_SKIP_CODESIGN_ENV`/`TEST_NO_LAUNCH_ENV` (and a
    /// relaxed `--proto` restriction) are honoured, so a real run against
    /// the real GitHub API can never skip verification.
    fn is_local_test(&self) -> bool {
        self.api_base.starts_with("http://127.0.0.1")
    }
}

fn non_empty_env(key: &str) -> Option<String> {
    env::var(key).ok().filter(|value| !value.is_empty())
}

fn github_token() -> Option<String> {
    non_empty_env("GH_TOKEN").or_else(|| non_empty_env("GITHUB_TOKEN")).or_else(gh_auth_token)
}

/// `gh auth token`, if `gh` is on PATH and already logged in. Any failure
/// (missing binary, not logged in) is ignored -- a public repo needs no
/// token, and a private one without one simply fails later, clearly, when a
/// download is refused.
fn gh_auth_token() -> Option<String> {
    let output = Command::new("gh").args(["auth", "token"]).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let token = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    (!token.is_empty()).then_some(token)
}

fn test_skip_codesign(config: &Config) -> bool {
    config.is_local_test() && env::var(TEST_SKIP_CODESIGN_ENV).ok().as_deref() == Some("1")
}

fn test_skip_launch(config: &Config) -> bool {
    config.is_local_test() && env::var(TEST_NO_LAUNCH_ENV).ok().as_deref() == Some("1")
}

#[derive(Debug, Clone, Deserialize)]
pub struct ReleaseAsset {
    pub name: String,
    /// The GitHub API asset URL: works for both public and private repos
    /// with `Accept: application/octet-stream` and a token.
    pub url: String,
    /// Only usable without a token (a private repo's redirect requires
    /// auth this CLI does not attach to it).
    pub browser_download_url: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Release {
    pub tag_name: String,
    pub html_url: String,
    #[serde(default)]
    pub assets: Vec<ReleaseAsset>,
}

/// `{current, latest, update_available, release_url}` (the `--check` JSON
/// shape; also used to report "up to date" without `--check`).
#[derive(Debug, Clone)]
pub struct CheckResult {
    pub current: String,
    pub latest: String,
    pub update_available: bool,
    pub release_url: String,
}

/// Numeric `major.minor.patch`, ignoring a leading `v`. `None` for anything
/// else (a pre-release suffix, a malformed tag).
pub fn parse_semver(input: &str) -> Option<(u64, u64, u64)> {
    let stripped = input.trim().strip_prefix('v').unwrap_or(input.trim());
    let mut parts = stripped.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((major, minor, patch))
}

fn is_newer(current: &str, latest: &str) -> Result<bool, UpdateError> {
    let current_parsed =
        parse_semver(current).ok_or_else(|| UpdateError::Check(format!("could not parse this version: {current}")))?;
    let latest_parsed = parse_semver(latest)
        .ok_or_else(|| UpdateError::Check(format!("could not parse the released version: {latest}")))?;
    Ok(latest_parsed > current_parsed)
}

/// The zip asset name for a given (unprefixed) release version, per the
/// release contract: `Rallo-<version>-macos-arm64.zip`.
pub fn zip_asset_name(version: &str) -> String {
    format!("Rallo-{version}-macos-arm64.zip")
}

/// A hidden, same-volume-as-the-app temp directory for one update attempt
/// (downloads, the curl header config file, and the extracted bundle): the
/// final install swap is a same-volume rename, which needs the extracted
/// bundle to already be on that volume.
pub fn create_workdir(installed_app: &Path) -> Result<tempfile::TempDir, UpdateError> {
    let parent = installed_app
        .parent()
        .ok_or_else(|| UpdateError::Install("the installed app has no parent directory".to_owned()))?;
    tempfile::Builder::new()
        .prefix(".rallo-update-")
        .tempdir_in(parent)
        .map_err(|error| UpdateError::Install(format!("could not create a work directory next to the app: {error}")))
}

/// Fetches the repository's latest release and compares it against
/// `current_version`.
pub fn check_for_update(
    config: &Config,
    workdir: &Path,
    current_version: &str,
) -> Result<(CheckResult, Release), UpdateError> {
    let release = fetch_latest_release(config, workdir)?;
    let latest = release.tag_name.trim_start_matches('v').to_owned();
    let update_available = is_newer(current_version, &latest)?;
    let result = CheckResult {
        current: current_version.to_owned(),
        latest,
        update_available,
        release_url: release.html_url.clone(),
    };
    Ok((result, release))
}

fn fetch_latest_release(config: &Config, workdir: &Path) -> Result<Release, UpdateError> {
    let url = format!("{}/repos/{}/releases/latest", config.api_base.trim_end_matches('/'), config.repo);
    let body = execute_curl(config, &url, "application/vnd.github+json", true, None, workdir)
        .map_err(|error| UpdateError::Check(format!("could not reach {url}: {error}")))?;
    serde_json::from_slice(&body)
        .map_err(|error| UpdateError::Check(format!("could not parse the release response from {url}: {error}")))
}

/// Downloads the release's zip asset and `SHA256SUMS` into `workdir`.
/// Private repos need the API asset URL with a token; public ones use the
/// plain `browser_download_url` (no auth attached to it).
pub fn download_release(
    config: &Config,
    release: &Release,
    version: &str,
    workdir: &Path,
) -> Result<(PathBuf, PathBuf), UpdateError> {
    let zip_name = zip_asset_name(version);
    let zip_asset = asset_by_name(release, &zip_name)?;
    let sums_asset = asset_by_name(release, "SHA256SUMS")?;
    let zip_path = workdir.join(&zip_name);
    let sums_path = workdir.join("SHA256SUMS");
    download_asset(config, zip_asset, &zip_path, workdir)?;
    download_asset(config, sums_asset, &sums_path, workdir)?;
    Ok((zip_path, sums_path))
}

fn asset_by_name<'a>(release: &'a Release, name: &str) -> Result<&'a ReleaseAsset, UpdateError> {
    release
        .assets
        .iter()
        .find(|asset| asset.name == name)
        .ok_or_else(|| UpdateError::Download(format!("release {} has no asset named {name}", release.tag_name)))
}

fn download_asset(
    config: &Config,
    asset: &ReleaseAsset,
    destination: &Path,
    workdir: &Path,
) -> Result<(), UpdateError> {
    let (url, send_auth): (&str, bool) =
        if config.token.is_some() { (&asset.url, true) } else { (&asset.browser_download_url, false) };
    execute_curl(config, url, "application/octet-stream", send_auth, Some(destination), workdir)
        .map(|_| ())
        .map_err(|error| UpdateError::Download(format!("could not download {}: {error}", asset.name)))
}

/// Builds the `curl` invocation: headers (including a bearer token, when
/// sent) go into a `0600` config file in `workdir`, never into argv, so the
/// token is never visible to `ps`. Returns the command and that file's path
/// so the caller can remove it afterward.
fn build_curl_command(
    config: &Config,
    url: &str,
    accept: &str,
    send_auth: bool,
    output: Option<&Path>,
    workdir: &Path,
) -> io::Result<(Command, PathBuf)> {
    let mut headers =
        vec![("Accept".to_owned(), accept.to_owned()), ("User-Agent".to_owned(), config.user_agent.clone())];
    if send_auth && let Some(token) = &config.token {
        headers.push(("Authorization".to_owned(), format!("Bearer {token}")));
    }
    let config_path = write_curl_config(workdir, &headers)?;

    let mut command = Command::new("/usr/bin/curl");
    command.arg("-fsSL");
    // The real GitHub API is always https; the loopback test server is
    // plain http and would be rejected by this restriction.
    if !url.starts_with("http://127.0.0.1") {
        command.args(["--proto", "=https"]);
    }
    command.arg("-K").arg(&config_path);
    if let Some(path) = output {
        command.arg("-o").arg(path);
    }
    command.arg(url).stdin(Stdio::null());
    Ok((command, config_path))
}

fn write_curl_config(workdir: &Path, headers: &[(String, String)]) -> io::Result<PathBuf> {
    let path = workdir.join(format!(".curl-{}.cfg", Uuid::new_v4()));
    let mut body = String::new();
    for (name, value) in headers {
        body.push_str(&format!("header = \"{}: {}\"\n", name, escape_curl_config(value)));
    }
    let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
    file.write_all(body.as_bytes())?;
    Ok(path)
}

fn escape_curl_config(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn execute_curl(
    config: &Config,
    url: &str,
    accept: &str,
    send_auth: bool,
    output: Option<&Path>,
    workdir: &Path,
) -> Result<Vec<u8>, String> {
    let (mut command, config_path) =
        build_curl_command(config, url, accept, send_auth, output, workdir).map_err(|error| error.to_string())?;
    let result = command.output().map_err(|error| error.to_string());
    let _ = fs::remove_file(&config_path);
    let result = result?;
    if !result.status.success() {
        return Err(format!("{} ({})", String::from_utf8_lossy(&result.stderr).trim(), result.status));
    }
    Ok(result.stdout)
}

fn compute_sha256(path: &Path) -> Result<String, UpdateError> {
    let output = Command::new("/usr/bin/shasum")
        .args(["-a", "256"])
        .arg(path)
        .output()
        .map_err(|error| UpdateError::Verification(format!("could not run shasum: {error}")))?;
    if !output.status.success() {
        return Err(UpdateError::Verification("shasum could not hash the downloaded archive".to_owned()));
    }
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .next()
        .map(str::to_owned)
        .ok_or_else(|| UpdateError::Verification("shasum produced no output".to_owned()))
}

/// Verifies the zip's sha256 against the matching line in `SHA256SUMS`
/// (`shasum -a 256` format: `<hex>  <name>`). Any mismatch, or a missing
/// entry, aborts before the installed app is touched.
pub fn verify_checksum(zip_path: &Path, sums_path: &Path) -> Result<(), UpdateError> {
    let file_name = zip_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| UpdateError::Verification("the downloaded archive path is not valid UTF-8".to_owned()))?;
    let sums = fs::read_to_string(sums_path)
        .map_err(|error| UpdateError::Verification(format!("could not read SHA256SUMS: {error}")))?;
    let expected = sums
        .lines()
        .find_map(|line| {
            let mut parts = line.splitn(2, char::is_whitespace);
            let hash = parts.next()?;
            let name = parts.next()?.trim_start_matches('*').trim();
            (name == file_name).then(|| hash.to_owned())
        })
        .ok_or_else(|| UpdateError::Verification(format!("SHA256SUMS has no entry for {file_name}")))?;
    let actual = compute_sha256(zip_path)?;
    if !actual.eq_ignore_ascii_case(&expected) {
        return Err(UpdateError::Verification(format!("checksum mismatch for {file_name}")));
    }
    Ok(())
}

/// Extracts the downloaded zip into `destination` with `ditto -x -k`, which
/// preserves the zip's own root entry (`Rallo.app`, per the release
/// contract).
pub fn extract_zip(zip_path: &Path, destination: &Path) -> Result<(), UpdateError> {
    fs::create_dir_all(destination)
        .map_err(|error| UpdateError::Verification(format!("could not create the extraction directory: {error}")))?;
    let status = Command::new("/usr/bin/ditto")
        .args(["-x", "-k"])
        .arg(zip_path)
        .arg(destination)
        .status()
        .map_err(|error| UpdateError::Verification(format!("could not run ditto: {error}")))?;
    if !status.success() {
        return Err(UpdateError::Verification("ditto could not extract the downloaded archive".to_owned()));
    }
    Ok(())
}

fn find_single_app(dir: &Path) -> Result<PathBuf, UpdateError> {
    let entries = fs::read_dir(dir)
        .map_err(|error| UpdateError::Verification(format!("could not read the extracted update: {error}")))?;
    let mut apps = Vec::new();
    for entry in entries {
        let entry = entry
            .map_err(|error| UpdateError::Verification(format!("could not read the extracted update: {error}")))?;
        if entry.file_name() == "Rallo.app" {
            apps.push(entry.path());
        }
    }
    match apps.len() {
        1 => Ok(apps.remove(0)),
        0 => Err(UpdateError::Verification("the downloaded update does not contain Rallo.app".to_owned())),
        _ => Err(UpdateError::Verification("the downloaded update contains more than one Rallo.app".to_owned())),
    }
}

fn plist_string(app: &Path, key: &str) -> Result<String, UpdateError> {
    let plist = app.join("Contents/Info.plist");
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", key, "raw", "-o", "-"])
        .arg(&plist)
        .output()
        .map_err(|error| UpdateError::Verification(format!("could not read {key} from Info.plist: {error}")))?;
    if !output.status.success() {
        return Err(UpdateError::Verification(format!(
            "could not read {key} from Info.plist: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn verify_codesign(app: &Path) -> Result<(), UpdateError> {
    let status = Command::new("/usr/bin/codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(app)
        .status()
        .map_err(|error| UpdateError::Verification(format!("could not run codesign: {error}")))?;
    if !status.success() {
        return Err(UpdateError::Verification("codesign could not verify the downloaded update".to_owned()));
    }
    Ok(())
}

fn verify_embedded_cli(app: &Path, expected_version: &str) -> Result<(), UpdateError> {
    let cli = terminal_command::cli_path(app);
    let output = Command::new(&cli)
        .args(["--version", "--json"])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| UpdateError::Verification(format!("could not run the embedded CLI: {error}")))?;
    if !output.status.success() {
        return Err(UpdateError::Verification("the embedded CLI did not run successfully".to_owned()));
    }
    let doc: Value = serde_json::from_slice(&output.stdout).map_err(|error| {
        UpdateError::Verification(format!("the embedded CLI's --version output was not valid JSON: {error}"))
    })?;
    let version = doc.get("cli_version").and_then(Value::as_str).ok_or_else(|| {
        UpdateError::Verification("the embedded CLI's --version output has no cli_version".to_owned())
    })?;
    if version != expected_version {
        return Err(UpdateError::Verification(format!(
            "the embedded CLI reports version {version}, expected {expected_version}"
        )));
    }
    Ok(())
}

/// Verifies the extracted bundle before anything installed is touched:
/// exactly one `Rallo.app`, the expected bundle identifier and version,
/// `codesign --verify --deep --strict`, and that its embedded CLI runs and
/// reports the same version. Returns the verified app's path.
pub fn verify_bundle(extracted_dir: &Path, expected_version: &str, config: &Config) -> Result<PathBuf, UpdateError> {
    let app = find_single_app(extracted_dir)?;
    let bundle_id = plist_string(&app, "CFBundleIdentifier")?;
    if bundle_id != launch::BUNDLE_IDENTIFIER {
        return Err(UpdateError::Verification(format!(
            "unexpected bundle identifier {bundle_id:?}, expected {:?}",
            launch::BUNDLE_IDENTIFIER
        )));
    }
    let version = plist_string(&app, "CFBundleShortVersionString")?;
    if version != expected_version {
        return Err(UpdateError::Verification(format!(
            "the update's bundle version ({version}) does not match the release ({expected_version})"
        )));
    }
    if !test_skip_codesign(config) {
        verify_codesign(&app)?;
    }
    verify_embedded_cli(&app, expected_version)?;
    Ok(app)
}

fn find_running_pids(exe: &Path) -> Result<Vec<u32>, UpdateError> {
    let output = Command::new("/bin/ps")
        .args(["-axo", "pid=,comm="])
        .output()
        .map_err(|error| UpdateError::Install(format!("could not list running processes: {error}")))?;
    let text = String::from_utf8_lossy(&output.stdout);
    let mut pids = Vec::new();
    for line in text.lines() {
        let line = line.trim_start();
        let Some((pid, comm)) = line.split_once(char::is_whitespace) else { continue };
        if Path::new(comm.trim()) == exe
            && let Ok(pid) = pid.trim().parse()
        {
            pids.push(pid);
        }
    }
    Ok(pids)
}

/// Quits a running installed Rallo by sending `SIGTERM` (the app treats it
/// as a normal quit, same as `scripts/build-macos.sh --install`) to every
/// process whose executable is exactly `<app>/Contents/MacOS/Rallo`, and
/// waits up to 5 seconds. Never escalates to `SIGKILL`: a still-running app
/// after the timeout is reported as busy instead.
pub fn quit_running_app(app: &Path) -> Result<(), UpdateError> {
    let exe = app.join("Contents/MacOS/Rallo");
    if find_running_pids(&exe)?.is_empty() {
        return Ok(());
    }
    for pid in find_running_pids(&exe)? {
        let _ = Command::new("/bin/kill").arg("-TERM").arg(pid.to_string()).status();
    }
    let deadline = Instant::now() + QUIT_TIMEOUT;
    loop {
        if find_running_pids(&exe)?.is_empty() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(UpdateError::AppBusy);
        }
        thread::sleep(Duration::from_millis(100));
    }
}

/// Renames the installed app aside (`Rallo.app.previous-<ts>`) and the
/// verified new bundle into its place. If the second rename fails, the first
/// is undone so the installed app is left exactly as it was. Both bundles
/// must already be on the same volume (see `create_workdir`) for these
/// renames to be atomic and for a partial failure to be recoverable at all.
pub fn swap_bundle(installed_app: &Path, new_app: &Path) -> Result<PathBuf, UpdateError> {
    let parent = installed_app
        .parent()
        .ok_or_else(|| UpdateError::Install("the installed app has no parent directory".to_owned()))?;
    let name = installed_app
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| UpdateError::Install("the installed app's path is not valid UTF-8".to_owned()))?;
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    let previous = parent.join(format!("{name}.previous-{stamp}"));

    fs::rename(installed_app, &previous)
        .map_err(|error| UpdateError::Install(format!("could not move the installed app aside: {error}")))?;
    if let Err(error) = fs::rename(new_app, installed_app) {
        let _ = fs::rename(&previous, installed_app);
        return Err(UpdateError::Install(format!(
            "could not install the update ({error}); the previous version was restored"
        )));
    }
    Ok(previous)
}

/// Best effort: downloads made by `curl` are not quarantined in the first
/// place, so this is normally a no-op; a missing attribute is not an error.
pub fn remove_quarantine(app: &Path) {
    let _ = Command::new("/usr/bin/xattr").args(["-dr", "com.apple.quarantine"]).arg(app).status();
}

const LSREGISTER: &str =
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";

/// Best effort, same as `scripts/build-macos.sh --install`.
pub fn register_launch_services(app: &Path) {
    let _ = Command::new(LSREGISTER).arg("-f").arg(app).status();
}

/// Removes the renamed-aside previous bundle after a successful swap.
/// Returns whether it was actually removed, for the command's
/// `previous_removed` field.
pub fn cleanup_previous(previous: &Path) -> bool {
    fs::remove_dir_all(previous).is_ok()
}

/// Relaunches exactly as the CLI already launches the app in the background
/// (`open -g -n -a <app> --args --background --data-dir <dir>`), so pet
/// visibility and everything else the app reads at startup is unaffected.
/// Skipped under the loopback test guard so tests never spawn a real app.
pub fn relaunch(config: &Config, app: &Path, data_dir: &Path) -> Result<(), LaunchError> {
    if test_skip_launch(config) {
        return Ok(());
    }
    launch::launch(app, launch::LaunchMode::Background, data_dir)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn semver_parses_major_minor_patch_and_ignores_a_leading_v() {
        assert_eq!(parse_semver("1.2.3"), Some((1, 2, 3)));
        assert_eq!(parse_semver("v1.2.3"), Some((1, 2, 3)));
        assert_eq!(parse_semver("1.2"), None);
        assert_eq!(parse_semver("1.2.3.4"), None);
        assert_eq!(parse_semver("1.2.3-beta"), None);
        assert_eq!(parse_semver("not-a-version"), None);
    }

    #[test]
    fn is_newer_compares_numerically_not_lexically() {
        assert!(is_newer("0.9.0", "0.10.0").unwrap());
        assert!(!is_newer("0.2.0", "0.2.0").unwrap());
        assert!(!is_newer("0.2.1", "0.2.0").unwrap());
        assert!(is_newer("v0.1.0", "v0.2.0").unwrap());
    }

    /// The whole point of the curl config file: a bearer token must never
    /// land in argv (visible to `ps`), only in the 0600 header file.
    #[test]
    fn bearer_token_never_appears_in_curl_argv() {
        let workdir = tempfile::tempdir().unwrap();
        let config = Config {
            api_base: DEFAULT_API_BASE.to_owned(),
            repo: DEFAULT_REPO.to_owned(),
            token: Some("super-secret-token-xyz".to_owned()),
            user_agent: "rallo/0.0.0-test".to_owned(),
        };
        let (command, config_path) = build_curl_command(
            &config,
            "https://api.github.com/repos/Eyakub/Rallo/releases/latest",
            "application/vnd.github+json",
            true,
            None,
            workdir.path(),
        )
        .unwrap();

        let args: Vec<String> = command.get_args().map(|arg| arg.to_string_lossy().into_owned()).collect();
        assert!(
            !args.iter().any(|arg| arg.contains("super-secret-token-xyz")),
            "token leaked into curl argv: {args:?}"
        );

        let config_body = fs::read_to_string(&config_path).unwrap();
        assert!(config_body.contains("Authorization: Bearer super-secret-token-xyz"), "{config_body}");

        let mode = fs::metadata(&config_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn checksum_line_is_matched_by_exact_file_name() {
        let dir = tempfile::tempdir().unwrap();
        let zip_path = dir.path().join("Rallo-0.2.0-macos-arm64.zip");
        fs::write(&zip_path, b"fake zip contents").unwrap();
        let hash = compute_sha256(&zip_path).unwrap();
        let sums_path = dir.path().join("SHA256SUMS");
        fs::write(&sums_path, format!("{hash}  Rallo-0.2.0-macos-arm64.zip\n")).unwrap();

        verify_checksum(&zip_path, &sums_path).unwrap();

        fs::write(&sums_path, format!("{hash}deadbeef  Rallo-0.2.0-macos-arm64.zip\n")).unwrap();
        assert!(verify_checksum(&zip_path, &sums_path).is_err());
    }
}
