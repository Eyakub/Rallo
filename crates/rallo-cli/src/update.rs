//! `rallo update [--check]` (distribution build, no Apple Developer ID): the
//! only Rallo command that uses the network, and only when invoked directly
//! -- never automatically, never in the background. Platform mechanics
//! (curl, checksum/signature verification, the atomic bundle swap, process
//! management) live in `rallo_platform_macos::update`; this module resolves
//! the data directory, backs up the store before anything native changes
//! (reusing the same code as `rallo backup`), and shapes the CLI's output.

use std::path::Path;

use rallo_core::storage::backup::default_manual_backup_path;
use rallo_core::storage::paths;
use rallo_core::{Store, StoreOptions};
use rallo_platform_macos::terminal_command;
use rallo_platform_macos::update::{self, Config};
use serde_json::json;

use crate::commands::CommandResult;
use crate::output::{Exit, Failure, Output};

impl From<update::UpdateError> for Failure {
    fn from(error: update::UpdateError) -> Self {
        Failure::new(Exit::Platform, error.code(), error.to_string())
    }
}

fn not_installed() -> Failure {
    Failure::new(
        Exit::InvalidInput,
        "NOT_INSTALLED",
        "could not resolve this CLI's location inside an installed Rallo.app; `rallo update` only runs from an \
         installed copy in /Applications or ~/Applications",
    )
}

/// `rallo update [--check] [--json]`. Refuses (`NOT_INSTALLED`, exit 2)
/// unless this CLI is the one embedded in an installed app -- there is
/// nothing to swap otherwise.
pub fn run(out: &Output, data_dir_arg: Option<&Path>, check: bool) -> CommandResult {
    let home = terminal_command::home_dir()
        .ok_or_else(|| Failure::new(Exit::InvalidInput, "INVALID_INPUT", "$HOME is not set"))?;
    let app = terminal_command::locate_running_app().map_err(|_| not_installed())?;
    if !terminal_command::is_installed(&app, &home) {
        return Err(not_installed());
    }

    let current_version = env!("CARGO_PKG_VERSION");
    let config = Config::from_env(current_version);
    let workdir = update::create_workdir(&app)?;
    let (check_result, release) = update::check_for_update(&config, workdir.path(), current_version)?;

    if check || !check_result.update_available {
        let fields = json!({
            "current": check_result.current,
            "latest": check_result.latest,
            "update_available": check_result.update_available,
            "release_url": check_result.release_url,
        });
        out.success(fields, &[], || {
            if check_result.update_available {
                format!(
                    "Rallo {} is available (currently {}): {}",
                    check_result.latest, check_result.current, check_result.release_url
                )
            } else {
                format!("Rallo {} is up to date.", check_result.current)
            }
        });
        return Ok(());
    }

    // Download, verify the checksum, extract, and verify the bundle -- all
    // before touching the installed app or quitting anything.
    let (zip_path, sums_path) = update::download_release(&config, &release, &check_result.latest, workdir.path())?;
    update::verify_checksum(&zip_path, &sums_path)?;
    let extracted = workdir.path().join("extracted");
    update::extract_zip(&zip_path, &extracted)?;
    let new_app = update::verify_bundle(&extracted, &check_result.latest, &config)?;

    // Back up the store before anything native changes, exactly like `rallo
    // backup`, so a schema migration the new version performs is
    // recoverable. Skipped if there is no data yet.
    let data_dir = paths::resolve_data_dir(data_dir_arg)?;
    let backup_path = if data_dir.is_dir() {
        let store = Store::open(StoreOptions::new(data_dir.clone()))?;
        let destination = default_manual_backup_path(store.data_dir(), store.now_ms());
        Some(store.backup_database_to_file(&destination, false)?.path)
    } else {
        None
    };

    update::quit_running_app(&app)?;

    let previous = update::swap_bundle(&app, &new_app)?;
    update::remove_quarantine(&app);
    update::register_launch_services(&config, &app);

    let mut warnings = Vec::new();
    if let Err(error) = update::relaunch(&config, &app, &data_dir) {
        warnings.push(format!("the update is installed, but Rallo could not be relaunched: {error}"));
    }
    let previous_removed = update::cleanup_previous(&previous);

    out.success(
        json!({
            "current": check_result.current,
            "installed_version": check_result.latest,
            "release_url": check_result.release_url,
            "backup_path": backup_path,
            "previous_removed": previous_removed,
        }),
        &warnings,
        || {
            let backup_note =
                backup_path.as_ref().map(|path| format!(" Backup: {}", path.display())).unwrap_or_default();
            format!("Updated Rallo {} → {}.{backup_note}", check_result.current, check_result.latest)
        },
    );
    Ok(())
}
