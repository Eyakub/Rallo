use std::io::{self, Read};
use std::path::Path;

use rallo_core::items::{ItemView, ListFilter, ListQuery};
use rallo_core::preferences::PetVisibility;
use rallo_core::shared::{signal, text};
use rallo_core::storage::instance_lock::InstanceLock;
use rallo_core::storage::migrations::SCHEMA_VERSION;
use rallo_core::{ErrorCode, Store};
use rallo_platform_macos::{change_signal, launch};
use serde_json::{Value, json};

use crate::output::{Exit, Failure, Output, preview};

pub type CommandResult = Result<(), Failure>;

pub fn version(out: &Output) -> CommandResult {
    out.success(
        json!({
            "cli_version": env!("CARGO_PKG_VERSION"),
            "core_version": rallo_core::CORE_VERSION,
            "database_schema_version": SCHEMA_VERSION,
            "json_contract_version": rallo_core::JSON_CONTRACT_VERSION,
        }),
        &[],
        || format!("rallo {} (core {}, schema {SCHEMA_VERSION})", env!("CARGO_PKG_VERSION"), rallo_core::CORE_VERSION),
    );
    Ok(())
}

fn item_json(view: &ItemView) -> Value {
    serde_json::to_value(view).expect("ItemView serializes")
}

/// Reads `--stdin` input with a hard bound so an oversized stream cannot
/// exhaust memory; drops exactly one trailing line ending (the shell's).
fn read_stdin_text() -> Result<String, Failure> {
    // Room for the limit plus a trailing CRLF; anything longer is rejected.
    let bound = text::MAX_TEXT_BYTES as u64 + 2;
    let mut bytes = Vec::new();
    io::stdin().lock().take(bound + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > bound {
        return Err(Failure::new(
            Exit::InvalidInput,
            ErrorCode::TextTooLong.as_str(),
            format!("stdin input exceeds the {} byte UTF-8 limit", text::MAX_TEXT_BYTES),
        ));
    }
    let mut input = String::from_utf8(bytes)
        .map_err(|_| Failure::new(Exit::InvalidInput, ErrorCode::InvalidInput.as_str(), "stdin is not valid UTF-8"))?;
    if input.ends_with("\r\n") {
        input.truncate(input.len() - 2);
    } else if input.ends_with('\n') {
        input.truncate(input.len() - 1);
    }
    Ok(input)
}

pub fn note(out: &Output, store: &mut Store, arg_text: Option<String>, from_stdin: bool) -> CommandResult {
    let note_text = match arg_text {
        Some(value) if !from_stdin => value,
        _ => read_stdin_text()?,
    };
    let outcome = store.create_note(&note_text, None)?;
    let view = &outcome.item;
    // Committed. Everything below is a best-effort nudge to the app.
    let mut warnings = Vec::new();
    if store.pet_visibility()? == Some(PetVisibility::Visible) {
        nudge_app(store.data_dir(), launch::LaunchMode::Background, &mut warnings);
    } else {
        signal_if_running(store.data_dir());
    }
    out.success(
        json!({ "item": item_json(view), "scheduling": outcome.scheduling, "cancellation": outcome.cancellation }),
        &warnings,
        || format!("Saved “{}” ({})", preview(&view.item.text, 80), view.display_id),
    );
    Ok(())
}

pub fn list(out: &Output, store: &Store) -> CommandResult {
    let page = store.list(ListQuery {
        filter: ListFilter::Open,
        limit: rallo_core::items::service::DEFAULT_PAGE_SIZE,
        cursor: None,
    })?;
    out.success(json!({ "items": page.items.iter().map(item_json).collect::<Vec<_>>() }), &[], || {
        if page.items.is_empty() {
            "No open notes.".to_owned()
        } else {
            page.items
                .iter()
                .map(|view| format!("{}  {}", view.display_id, preview(&view.item.text, 100)))
                .collect::<Vec<_>>()
                .join("\n")
        }
    });
    Ok(())
}

pub fn show(out: &Output, store: &mut Store, reset_position: bool) -> CommandResult {
    store.set_pet_visibility(PetVisibility::Visible)?;
    if reset_position {
        store.set_pet_placement(None)?;
    }
    let data_dir = store.data_dir().to_path_buf();
    if InstanceLock::is_held(&data_dir)? {
        change_signal::post(&signal::change_signal_name(&data_dir));
        change_signal::post(&signal::show_signal_name(&data_dir));
    } else {
        let app = launch::locate_app().map_err(platform_failure)?;
        launch::launch(&app, launch::LaunchMode::Show, &data_dir).map_err(platform_failure)?;
    }
    out.success(json!({ "pet": { "visibility": "visible" } }), &[], || "Rallo is visible.".to_owned());
    Ok(())
}

pub fn hide(out: &Output, store: &mut Store) -> CommandResult {
    store.set_pet_visibility(PetVisibility::Hidden)?;
    // Never launches the app: hiding a pet that is not running needs no work.
    signal_if_running(store.data_dir());
    out.success(json!({ "pet": { "visibility": "hidden" } }), &[], || {
        "Rallo is hidden. Notes and scheduled reminders are unaffected; `rallo show` brings it back.".to_owned()
    });
    Ok(())
}

pub fn status(out: &Output, store: &Store) -> CommandResult {
    let running = InstanceLock::is_held(store.data_dir())?;
    let app = launch::locate_app().ok();
    let visibility = store.pet_visibility()?;
    let open_count = store
        .list(ListQuery {
            filter: ListFilter::Open,
            limit: rallo_core::items::service::DEFAULT_PAGE_SIZE,
            cursor: None,
        })?
        .items
        .len();
    let fields = json!({
        "app": { "running": running, "path": app },
        "storage": {
            "data_dir": store.data_dir(),
            "schema_version": store.schema_version()?,
            "change_revision": store.change_revision()?,
        },
        "pet": { "visibility": visibility },
        "open_items_first_page": open_count,
    });
    out.success(fields, &[], || {
        let visibility = match visibility {
            Some(PetVisibility::Visible) => "visible",
            Some(PetVisibility::Hidden) => "hidden",
            None => "not yet introduced",
        };
        format!(
            "App: {}\nPet: {visibility}\nOpen notes: {open_count}\nData: {}",
            if running { "running" } else { "not running" },
            store.data_dir().display()
        )
    });
    Ok(())
}

fn platform_failure(error: launch::LaunchError) -> Failure {
    let code = match error {
        launch::LaunchError::AppNotFound => "APP_NOT_FOUND",
        launch::LaunchError::LaunchFailed(_) => "APP_LAUNCH_FAILED",
    };
    Failure::new(Exit::Platform, code, error.to_string())
}

fn signal_if_running(data_dir: &Path) {
    if InstanceLock::is_held(data_dir).unwrap_or(false) {
        change_signal::post(&signal::change_signal_name(data_dir));
    }
}

/// Signals a running app, or asks macOS to start it in the background.
/// Never waits for the app's own startup.
fn nudge_app(data_dir: &Path, mode: launch::LaunchMode, warnings: &mut Vec<String>) {
    if InstanceLock::is_held(data_dir).unwrap_or(false) {
        change_signal::post(&signal::change_signal_name(data_dir));
        return;
    }
    let result = launch::locate_app().and_then(|app| launch::launch(&app, mode, data_dir));
    if let Err(error) = result {
        warnings.push(format!("saved, but the app was not started: {error}"));
    }
}
