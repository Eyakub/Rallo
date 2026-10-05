//! `rallo uninstall [--purge] [--yes]`: removes the installed app and
//! everything Rallo put outside it (terminal link, agent hooks and skill,
//! Open at Login, scheduled reminders, the ClickUp token). Notes are kept
//! unless `--purge`, which first saves a final JSON export to `~/Downloads`.
//! Nothing is removed until every step that can fail safely has succeeded:
//! confirmation, the export, quitting the app, and the app-owned cleanup.

use std::fs;
use std::io::{self, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use rallo_core::storage::paths;
use rallo_core::transfer::ExportFormat;
use rallo_core::{Store, StoreOptions};
use rallo_platform_macos::terminal_command;
use rallo_platform_macos::update;
use serde_json::{Value, json};

use crate::commands::CommandResult;
use crate::local_time::file_stamp;
use crate::output::{Exit, Failure, Output};
use crate::skill::{self, Agent, State};

/// Test-only: runs the app's `--prepare-uninstall` even with an explicit
/// data directory (normally skipped, because notifications, Login Items and
/// the Keychain belong to the bundle ID, not the data directory, so a test
/// run against a scratch data dir must never wipe the real ones).
pub const TEST_PREPARE_ENV: &str = "RALLO_UNINSTALL_TEST_PREPARE";

const PREPARE_TIMEOUT: Duration = Duration::from_secs(60);

fn not_installed() -> Failure {
    Failure::new(
        Exit::InvalidInput,
        "NOT_INSTALLED",
        "could not resolve this CLI's location inside an installed Rallo.app; `rallo uninstall` only runs from an \
         installed copy in /Applications or ~/Applications (or use the install script's --uninstall)",
    )
}

/// `/Users/x/foo` as `~/foo`.
fn tilde(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}

fn confirm(app: &Path, purge: bool) -> Result<(), Failure> {
    if !io::stdin().is_terminal() {
        return Err(Failure::new(
            Exit::InvalidInput,
            "CONFIRMATION_REQUIRED",
            "pass --yes to uninstall without a prompt; nothing was removed",
        ));
    }
    let consequence = if purge {
        "This also DELETES your notes, after saving an export to ~/Downloads."
    } else {
        "Your notes are kept."
    };
    eprint!("Uninstall Rallo from {}? {consequence} [y/N] ", app.display());
    let _ = io::stderr().flush();
    let mut answer = String::new();
    let _ = io::stdin().read_line(&mut answer);
    if matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes") {
        Ok(())
    } else {
        Err(Failure::new(Exit::InvalidInput, "CANCELLED", "Nothing was removed."))
    }
}

fn export_failed(detail: impl std::fmt::Display) -> Failure {
    Failure::new(
        Exit::Storage,
        "UNINSTALL_EXPORT_FAILED",
        format!("couldn't save a final export, so nothing was removed: {detail}"),
    )
}

fn save_final_export(data_dir: &Path, home: &Path) -> Result<PathBuf, Failure> {
    let store = Store::open(StoreOptions::new(data_dir.to_path_buf())).map_err(export_failed)?;
    let downloads = home.join("Downloads");
    fs::create_dir_all(&downloads).map_err(export_failed)?;
    let path = downloads.join(format!("rallo-export-{}.json", file_stamp(store.now_ms())));
    store.export_to_file(&path, ExportFormat::Json, false).map_err(export_failed)?;
    Ok(path)
}

fn prepare_failed() -> Failure {
    Failure::new(
        Exit::Platform,
        "UNINSTALL_PREPARE_FAILED",
        "Rallo couldn't cancel its scheduled reminders and Open at Login, so nothing was removed. Try again, or \
         remove it anyway with the install script's --uninstall.",
    )
}

/// Runs the app's own cleanup (`--prepare-uninstall`) and parses its report.
fn prepare(app: &Path) -> Result<Value, Failure> {
    let mut child = Command::new(app.join("Contents/MacOS/Rallo"))
        .arg("--prepare-uninstall")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| prepare_failed())?;
    let deadline = Instant::now() + PREPARE_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(prepare_failed());
            }
        }
    };
    let mut stdout = String::new();
    if let Some(mut pipe) = child.stdout.take() {
        let _ = pipe.read_to_string(&mut stdout);
    }
    let report: Value = serde_json::from_str(&stdout).map_err(|_| prepare_failed())?;
    if !status.success() || !report.is_object() {
        return Err(prepare_failed());
    }
    Ok(report)
}

/// Removes Rallo's own skill and rules files (never a foreign one).
fn remove_skills(home: &Path) -> Vec<PathBuf> {
    let mut removed = Vec::new();
    for agent in Agent::ALL {
        let path = skill::skill_path(agent, home);
        if matches!(skill::inspect_skill(&path), State::Current | State::Outdated) && fs::remove_file(&path).is_ok() {
            if let Some(parent) = path.parent() {
                let _ = fs::remove_dir(parent);
            }
            removed.push(path);
        }
    }
    let rules = skill::rules_path(home);
    if matches!(skill::inspect_rules(&rules, &skill::rules_content(home)), State::Current | State::Outdated)
        && fs::remove_file(&rules).is_ok()
    {
        removed.push(rules);
    }
    removed
}

/// `rallo uninstall [--purge] [--yes] [--json]`.
pub fn run(out: &Output, data_dir_arg: Option<&Path>, purge: bool, yes: bool) -> CommandResult {
    let home = terminal_command::home_dir()
        .ok_or_else(|| Failure::new(Exit::InvalidInput, "INVALID_INPUT", "$HOME is not set"))?;
    let app = terminal_command::locate_running_app().map_err(|_| not_installed())?;
    if !terminal_command::is_installed(&app, &home) {
        return Err(not_installed());
    }
    if !yes {
        confirm(&app, purge)?;
    }

    let data_dir = paths::resolve_data_dir(data_dir_arg)?;
    let export_path = if purge && data_dir.is_dir() { Some(save_final_export(&data_dir, &home)?) } else { None };

    update::quit_running_app(&app)?;

    let mut warnings = Vec::new();
    let run_prepare = data_dir_arg.is_none() || std::env::var(TEST_PREPARE_ENV).ok().as_deref() == Some("1");
    let prepared = if run_prepare { Some(prepare(&app)?) } else { None };
    if prepared.is_none() {
        warnings.push(
            "left Open at Login, scheduled reminders, the ClickUp token and voice API keys alone: they belong to the \
             app, not to --data-dir"
                .to_owned(),
        );
    }
    if let Some(report) = &prepared {
        if report["login_item"] == "failed" {
            warnings.push("Remove Rallo under System Settings → General → Login Items.".to_owned());
        }
        if report["clickup_token"] == "failed" {
            warnings.push("Delete “Rallo: ClickUp API token” in Keychain Access.".to_owned());
        }
        if report["voice_api_keys"] == "failed" {
            warnings.push("Delete the “Rallo: … API key” items in Keychain Access.".to_owned());
        }
    }

    let mut hook_values = Vec::new();
    let mut hook_lines = Vec::new();
    for agent in Agent::ALL {
        match crate::hooks::apply(&home, vec![agent], true, None) {
            Ok((results, _)) => {
                for (value, line) in results {
                    if value["status"] == "removed" {
                        hook_lines.push(line);
                    }
                    hook_values.push(value);
                }
            }
            Err(failure) => warnings.push(format!("left {}'s hooks alone: {}", agent.json_name(), failure.message)),
        }
    }
    let skills_removed = remove_skills(&home);
    let links_removed = terminal_command::remove_links(&home)
        .map_err(|error| Failure::new(Exit::Platform, "UNINSTALL_FAILED", error.to_string()))?;
    let path_line = terminal_command::profile_with_marker(&home);

    update::unregister_launch_services(&app);
    fs::remove_dir_all(&app).map_err(|error| {
        Failure::new(Exit::Platform, "UNINSTALL_FAILED", format!("couldn't remove {}: {error}", app.display()))
    })?;

    let purged = purge && data_dir.exists();
    if purged {
        fs::remove_dir_all(&data_dir).map_err(|error| {
            Failure::new(Exit::Platform, "UNINSTALL_FAILED", format!("couldn't delete {}: {error}", data_dir.display()))
        })?;
        // The app's settings (UserDefaults) live outside the data dir. Never under an explicit or
        // overridden data dir (tests, scratch): that domain is the real user's.
        if data_dir_arg.is_none() && std::env::var_os(paths::DATA_DIR_ENV).is_none() {
            let _ = Command::new("/usr/bin/defaults")
                .args(["delete", "com.razlio.rallo"])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
    }

    let fields = json!({ "uninstall": {
        "app": app,
        "links_removed": links_removed,
        "hooks": hook_values,
        "skills_removed": skills_removed,
        "prepared": prepared,
        "export_path": export_path,
        "data": if purge { "deleted" } else { "kept" },
        "data_dir": data_dir,
        "path_line_kept": path_line,
    } });
    out.success(fields, &warnings, || {
        let mut lines = vec![format!("Removed {}.", app.display())];
        for link in &links_removed {
            lines.push(format!("Removed the rallo command ({}).", tilde(link, &home)));
        }
        lines.extend(hook_lines);
        for path in &skills_removed {
            lines.push(format!("Removed the agent skill ({}).", tilde(path, &home)));
        }
        if let Some(report) = &prepared {
            let mut parts = Vec::new();
            if report["login_item"] == "removed" {
                parts.push("turned off Open at Login".to_owned());
            }
            let cancelled = report["notifications_removed"].as_u64().unwrap_or(0);
            if cancelled > 0 {
                parts
                    .push(format!("cancelled {cancelled} scheduled reminder{}", if cancelled == 1 { "" } else { "s" }));
            }
            if report["clickup_token"] == "removed" {
                parts.push("removed the ClickUp token".to_owned());
            }
            if report["voice_api_keys"] == "removed" {
                parts.push("removed the voice API keys".to_owned());
            }
            if !parts.is_empty() {
                let mut text = parts.join(", ");
                text[..1].make_ascii_uppercase();
                lines.push(format!("{text}."));
            }
        }
        if let Some(path) = &export_path {
            lines.push(format!("Saved a final export: {}", tilde(path, &home)));
        }
        if purge {
            lines.push("Deleted your notes and settings.".to_owned());
        } else {
            lines.push(format!(
                "Your notes are kept in {} (rallo uninstall --purge deletes them).",
                tilde(&data_dir, &home)
            ));
        }
        if let Some(profile) = &path_line {
            lines.push(format!(
                "Left the PATH line Rallo added to {}; other tools may use ~/.local/bin.",
                tilde(profile, &home)
            ));
        }
        lines.join("\n")
    });
    Ok(())
}
