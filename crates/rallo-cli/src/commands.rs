use std::env;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use rallo_core::items::{ItemView, ListFilter, ListQuery, MutationOptions, MutationOutcome, Page, SearchQuery};
use rallo_core::preferences::PetVisibility;
use rallo_core::reminders::{CancellationStatus, ReminderState, SchedulingStatus, TimeSpec};
use rallo_core::shared::{signal, text};
use rallo_core::storage::instance_lock::InstanceLock;
use rallo_core::storage::migrations::SCHEMA_VERSION;
use rallo_core::transfer::{ExportFormat, ImportReport, MAX_IMPORT_BYTES};
use rallo_core::{ErrorCode, Store};
use rallo_platform_macos::{change_signal, launch, terminal_command};
use serde_json::{Value, json};

use crate::args::ExportFormatArg;
use crate::local_time::format_local;
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

/// `setup terminal`: links the CLI inside this installed app onto PATH as
/// `rallo` (spec §10). Reads `$HOME`/`$PATH` directly -- run from an actual
/// terminal, it already sees the same PATH a shell would, so there is no
/// need to ask a login shell the way the GUI's "Enable Terminal Command…"
/// does. Never touches a data directory and never starts the app.
pub fn setup_terminal(out: &Output) -> CommandResult {
    let home = terminal_command::home_dir()
        .ok_or_else(|| Failure::new(Exit::InvalidInput, "INVALID_INPUT", "$HOME is not set"))?;
    let app = terminal_command::locate_running_app().map_err(|_| {
        Failure::new(
            Exit::InvalidInput,
            "NOT_INSTALLED",
            "could not resolve this CLI's location inside an installed Rallo.app",
        )
    })?;
    let path_dirs: Vec<PathBuf> =
        env::var_os("PATH").map(|value| env::split_paths(&value).collect()).unwrap_or_default();
    let target = terminal_command::cli_path(&app);

    match terminal_command::inspect(&app, &home, &path_dirs) {
        terminal_command::State::NotInstalled => Err(Failure::new(
            Exit::InvalidInput,
            "NOT_INSTALLED",
            format!(
                "Rallo is running from {}, not an installed copy. Move it to /Applications or ~/Applications, \
                 then run this again. Full path: {}",
                app.display(),
                target.display()
            ),
        )),
        terminal_command::State::Conflict { existing } => Err(Failure::new(
            Exit::Conflict,
            "TERMINAL_COMMAND_CONFLICT",
            format!(
                "{} isn't Rallo's, so Rallo won't replace it. Run Rallo's CLI directly instead: {}",
                existing.display(),
                target.display()
            ),
        )),
        terminal_command::State::Enabled { link, on_path } => {
            setup_terminal_success(out, "already_enabled", &link, &target, on_path)
        }
        state @ (terminal_command::State::Available { .. } | terminal_command::State::Repairable { .. }) => {
            let repairing = matches!(state, terminal_command::State::Repairable { .. });
            let on_path = match &state {
                terminal_command::State::Available { on_path, .. } => *on_path,
                terminal_command::State::Repairable { on_path, .. } => *on_path,
                _ => unreachable!(),
            };
            let link = terminal_command::enable(&state, &app).map_err(|error| {
                Failure::new(Exit::InvalidInput, "TERMINAL_COMMAND_SETUP_FAILED", error.to_string())
            })?;
            setup_terminal_success(out, if repairing { "repaired" } else { "enabled" }, &link, &target, on_path)
        }
    }
}

fn setup_terminal_success(out: &Output, status: &str, link: &Path, target: &Path, on_path: bool) -> CommandResult {
    const PATH_EXPORT: &str = r#"export PATH="$HOME/.local/bin:$PATH""#;
    let mut warnings = Vec::new();
    if !on_path {
        warnings.push(format!("{} is not on your PATH.", link.parent().unwrap_or(link).display()));
    }
    out.success(
        json!({
            "terminal": {
                "status": status,
                "link": link,
                "target": target,
                "on_path": on_path,
                "path_export": if on_path { None } else { Some(PATH_EXPORT) },
            }
        }),
        &warnings,
        || {
            let headline = match status {
                "already_enabled" => format!("`rallo` is already set up at {} → {}.", link.display(), target.display()),
                "repaired" => format!("Repaired `rallo` at {} to point at {}.", link.display(), target.display()),
                _ => format!("Added `rallo` at {}, linked to {}.", link.display(), target.display()),
            };
            if on_path {
                format!("{headline}\nTry it: rallo note \"Call the dentist\"")
            } else {
                format!(
                    "{headline}\n{} isn't on your PATH. Add this line to your shell's startup file, then open a new terminal:\n  {PATH_EXPORT}\nFull path: {}",
                    link.parent().unwrap_or(link).display(),
                    target.display()
                )
            }
        },
    );
    Ok(())
}

fn item_json(view: &ItemView) -> Value {
    serde_json::to_value(view).expect("ItemView serializes")
}

/// The standard mutation output shape (0003 §11): item, changed, replayed,
/// scheduling, cancellation. `delete` adds `undo` on top of this.
fn mutation_fields(outcome: &MutationOutcome) -> Value {
    json!({
        "item": item_json(&outcome.item),
        "changed": outcome.changed,
        "replayed": outcome.replayed,
        "scheduling": outcome.scheduling,
        "cancellation": outcome.cancellation,
    })
}

fn page_json(page: &Page<ItemView>) -> Value {
    json!({
        "items": page.items.iter().map(item_json).collect::<Vec<_>>(),
        "total_count": page.total_count,
        "next_cursor": page.next_cursor,
    })
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

fn resolve_text(arg_text: Option<String>, from_stdin: bool) -> Result<String, Failure> {
    match arg_text {
        Some(value) if !from_stdin => Ok(value),
        _ => read_stdin_text(),
    }
}

pub fn note(
    out: &Output,
    store: &mut Store,
    arg_text: Option<String>,
    from_stdin: bool,
    request_id: Option<String>,
) -> CommandResult {
    let note_text = resolve_text(arg_text, from_stdin)?;
    let outcome = store.create_note(&note_text, request_id.as_deref())?;
    let view = &outcome.item;
    // Committed. Everything below is a best-effort nudge to the app.
    let mut warnings = Vec::new();
    nudge_passive(store, &mut warnings);
    out.success(mutation_fields(&outcome), &warnings, || {
        format!("Saved “{}” ({})", preview(&view.item.text, 80), view.display_id)
    });
    Ok(())
}

/// `remind TEXT|--stdin (--in|--at)` (0003 §3): always creates a new item
/// with an active reminder, so this always nudges the app to start draining
/// the schedule intent, regardless of pet visibility.
pub fn remind(
    out: &Output,
    store: &mut Store,
    arg_text: Option<String>,
    from_stdin: bool,
    when: TimeSpec,
    request_id: Option<String>,
) -> CommandResult {
    let note_text = resolve_text(arg_text, from_stdin)?;
    let outcome = store.create_reminder(&note_text, &when, request_id.as_deref())?;
    let view = &outcome.item;
    let mut warnings = Vec::new();
    nudge_reminder_intent(store, &mut warnings);
    let deadline_ms = view.reminder.as_ref().expect("remind always attaches a reminder").deadline_ms;
    out.success(mutation_fields(&outcome), &warnings, || {
        // Never "Reminder set": the app has not yet confirmed native scheduling (M2).
        format!(
            "Saved “{}” ({}); reminder at {} — scheduling pending",
            preview(&view.item.text, 80),
            view.display_id,
            format_local(deadline_ms)
        )
    });
    Ok(())
}

fn list_filter(all: bool, deleted: bool, due: bool) -> ListFilter {
    if all {
        ListFilter::All
    } else if deleted {
        ListFilter::Deleted
    } else if due {
        ListFilter::Due
    } else {
        ListFilter::Open
    }
}

pub fn list(
    out: &Output,
    store: &Store,
    all: bool,
    deleted: bool,
    due: bool,
    limit: u32,
    cursor: Option<String>,
) -> CommandResult {
    let filter = list_filter(all, deleted, due);
    let page = store.list(ListQuery { filter, limit, cursor })?;
    out.success(page_json(&page), &[], || human_page(&page, "No matching notes."));
    Ok(())
}

pub fn search(
    out: &Output,
    store: &Store,
    text: String,
    exact: bool,
    include_deleted: bool,
    limit: u32,
    cursor: Option<String>,
) -> CommandResult {
    let page = store.search(SearchQuery { text, exact, include_deleted, limit, cursor })?;
    out.success(page_json(&page), &[], || human_page(&page, "No matches."));
    Ok(())
}

fn human_page(page: &Page<ItemView>, empty_message: &str) -> String {
    if page.items.is_empty() {
        return empty_message.to_owned();
    }
    let mut lines: Vec<String> = page.items.iter().map(list_line).collect();
    if page.total_count as usize > page.items.len() {
        lines.push(format!("{} matches; showing {}", page.total_count, page.items.len()));
    }
    lines.join("\n")
}

fn list_line(view: &ItemView) -> String {
    let marker = if view.item.status.as_str() == "done" { "[done] " } else { "" };
    let reminder =
        view.reminder.as_ref().map(|r| format!("  (reminder {})", format_local(r.deadline_ms))).unwrap_or_default();
    format!("{}  {marker}{}{reminder}", view.display_id, preview(&view.item.text, 100))
}

pub fn get(out: &Output, store: &Store, id: &str) -> CommandResult {
    let view = store.get_item(id)?;
    let scheduling = store.scheduling_status(&view)?;
    let cancellation = store.cancellation_status(&view)?;
    out.success(
        json!({ "item": item_json(&view), "scheduling": scheduling, "cancellation": cancellation }),
        &[],
        || item_human(&view, scheduling.as_ref(), cancellation.as_ref()),
    );
    Ok(())
}

fn item_human(
    view: &ItemView,
    scheduling: Option<&SchedulingStatus>,
    cancellation: Option<&CancellationStatus>,
) -> String {
    let mut lines = vec![
        format!("{}  {}  revision {}", view.display_id, view.item.status.as_str(), view.item.revision),
        format!("“{}”", preview(&view.item.text, 200)),
    ];
    if let Some(reminder) = &view.reminder {
        lines.push(format!("Reminder: {} ({})", format_local(reminder.deadline_ms), reminder.state().as_str()));
        if let Some(scheduling) = scheduling {
            lines.push(format!("Scheduling: {} ({})", scheduling.state, scheduling.reason));
        }
        if let Some(cancellation) = cancellation {
            lines.push(format!("Cancellation: {} ({})", cancellation.state, cancellation.reason));
        }
    }
    lines.join("\n")
}

pub fn edit(out: &Output, store: &mut Store, id: &str, new_text: &str, opts: MutationOptions) -> CommandResult {
    let outcome = store.edit_text(id, new_text, &opts)?;
    let mut warnings = Vec::new();
    nudge_after(store, &outcome, &mut warnings);
    let view = &outcome.item;
    out.success(mutation_fields(&outcome), &warnings, || {
        if outcome.changed {
            format!("Updated “{}” ({})", preview(&view.item.text, 80), view.display_id)
        } else {
            format!("No change: “{}” ({}) already matches.", preview(&view.item.text, 80), view.display_id)
        }
    });
    Ok(())
}

pub fn done(out: &Output, store: &mut Store, id: &str, opts: MutationOptions) -> CommandResult {
    let outcome = store.complete(id, &opts)?;
    let mut warnings = Vec::new();
    nudge_after(store, &outcome, &mut warnings);
    let view = &outcome.item;
    out.success(mutation_fields(&outcome), &warnings, || {
        if outcome.changed {
            format!("Done: “{}” ({})", preview(&view.item.text, 80), view.display_id)
        } else {
            format!("Already done: “{}” ({})", preview(&view.item.text, 80), view.display_id)
        }
    });
    Ok(())
}

pub fn reopen(out: &Output, store: &mut Store, id: &str, opts: MutationOptions) -> CommandResult {
    let outcome = store.reopen(id, &opts)?;
    let mut warnings = Vec::new();
    nudge_passive(store, &mut warnings);
    let view = &outcome.item;
    out.success(mutation_fields(&outcome), &warnings, || {
        if outcome.changed {
            format!("Reopened “{}” ({})", preview(&view.item.text, 80), view.display_id)
        } else {
            format!("Already open: “{}” ({})", preview(&view.item.text, 80), view.display_id)
        }
    });
    Ok(())
}

pub fn restore(out: &Output, store: &mut Store, id: &str, opts: MutationOptions) -> CommandResult {
    let outcome = store.restore(id, &opts)?;
    let mut warnings = Vec::new();
    nudge_passive(store, &mut warnings);
    let view = &outcome.item;
    // Restore never re-enables an old reminder (0003 §3); say so when one exists.
    let reminder_note = view.reminder.as_ref().map(|_| " (its old reminder was not re-enabled)").unwrap_or("");
    out.success(mutation_fields(&outcome), &warnings, || {
        if outcome.changed {
            format!("Restored “{}” ({}){reminder_note}", preview(&view.item.text, 80), view.display_id)
        } else {
            format!("Not deleted: “{}” ({})", preview(&view.item.text, 80), view.display_id)
        }
    });
    Ok(())
}

pub fn reschedule(out: &Output, store: &mut Store, id: &str, when: TimeSpec, opts: MutationOptions) -> CommandResult {
    let outcome = store.reschedule(id, &when, &opts)?;
    let mut warnings = Vec::new();
    nudge_reminder_intent(store, &mut warnings);
    let view = &outcome.item;
    let deadline_ms = view.reminder.as_ref().expect("reschedule always attaches a reminder").deadline_ms;
    out.success(mutation_fields(&outcome), &warnings, || {
        format!(
            "Rescheduled “{}” ({}); reminder at {} — scheduling pending",
            preview(&view.item.text, 80),
            view.display_id,
            format_local(deadline_ms)
        )
    });
    Ok(())
}

pub fn snooze(out: &Output, store: &mut Store, id: &str, duration: &str, opts: MutationOptions) -> CommandResult {
    let outcome = store.snooze(id, duration, &opts)?;
    let mut warnings = Vec::new();
    nudge_reminder_intent(store, &mut warnings);
    let view = &outcome.item;
    let deadline_ms = view.reminder.as_ref().expect("snooze always keeps a reminder").deadline_ms;
    out.success(mutation_fields(&outcome), &warnings, || {
        format!(
            "Snoozed “{}” ({}); reminder at {} — scheduling pending",
            preview(&view.item.text, 80),
            view.display_id,
            format_local(deadline_ms)
        )
    });
    Ok(())
}

pub fn acknowledge(out: &Output, store: &mut Store, id: &str, opts: MutationOptions) -> CommandResult {
    let outcome = store.acknowledge(id, &opts)?;
    let mut warnings = Vec::new();
    nudge_reminder_intent(store, &mut warnings);
    let view = &outcome.item;
    out.success(mutation_fields(&outcome), &warnings, || {
        if outcome.changed {
            format!("Acknowledged “{}” ({})", preview(&view.item.text, 80), view.display_id)
        } else {
            format!("No active reminder to acknowledge: “{}” ({})", preview(&view.item.text, 80), view.display_id)
        }
    });
    Ok(())
}

pub fn cancel_reminder(out: &Output, store: &mut Store, id: &str, opts: MutationOptions) -> CommandResult {
    let outcome = store.cancel_reminder(id, &opts)?;
    let mut warnings = Vec::new();
    nudge_reminder_intent(store, &mut warnings);
    let view = &outcome.item;
    out.success(mutation_fields(&outcome), &warnings, || {
        if outcome.changed {
            format!("Reminder cancelled for “{}” ({})", preview(&view.item.text, 80), view.display_id)
        } else {
            format!("No active reminder to cancel: “{}” ({})", preview(&view.item.text, 80), view.display_id)
        }
    });
    Ok(())
}

/// `delete ID | --text TEXT` (0003 §8): exactly one selector, enforced by
/// clap. `--if-revision` only applies to the ID form (also enforced by clap).
pub fn delete(
    out: &Output,
    store: &mut Store,
    id: Option<String>,
    text_selector: Option<String>,
    opts: MutationOptions,
) -> CommandResult {
    let outcome = match id {
        Some(id) => store.delete(&id, &opts)?,
        None => {
            let text_selector = text_selector.expect("clap requires exactly one of id / --text");
            store.delete_by_text(&text_selector, opts.request_id.as_deref())?
        }
    };
    let mut warnings = Vec::new();
    nudge_after(store, &outcome, &mut warnings);

    let view = &outcome.item;
    let mut fields = mutation_fields(&outcome);
    fields["undo"] = json!({ "command": format!("rallo restore {}", view.display_id), "item_id": view.item.id });

    // 0003 §3/§8: restoring never re-enables the reminder; say so when this
    // item's reminder was disabled by a deletion (this call or an earlier one
    // replayed through `--request-id`).
    let reminder_deleted = view.reminder.as_ref().is_some_and(|r| r.state() == ReminderState::Deleted);
    out.success(fields, &warnings, || {
        let headline = if outcome.changed {
            format!("Deleted “{}”. Undo: rallo restore {}", preview(&view.item.text, 80), view.display_id)
        } else {
            format!("Already deleted: “{}”. Undo: rallo restore {}", preview(&view.item.text, 80), view.display_id)
        };
        if reminder_deleted {
            format!(
                "{headline}\nRestoring will not re-enable its reminder; removing the scheduled alert is still pending."
            )
        } else {
            headline
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

/// `status` (no ID): existing app/storage/pet overview. `status ID`: the item
/// plus its scheduling/cancellation detail, same shape as `get`.
pub fn status(out: &Output, store: &Store, id: Option<String>) -> CommandResult {
    match id {
        Some(id) => get(out, store, &id),
        None => status_overview(out, store),
    }
}

fn status_overview(out: &Output, store: &Store) -> CommandResult {
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

fn export_format_name(format: ExportFormat) -> &'static str {
    match format {
        ExportFormat::Json => "json",
        ExportFormat::Csv => "csv",
    }
}

/// Format defaults from the `--output` extension (build plan §5, 0004):
/// `.csv` is CSV, anything else (including "-" for stdout) is JSON.
fn infer_export_format(output: &str, explicit: Option<ExportFormatArg>) -> ExportFormat {
    match explicit {
        Some(ExportFormatArg::Json) => ExportFormat::Json,
        Some(ExportFormatArg::Csv) => ExportFormat::Csv,
        None if output.to_ascii_lowercase().ends_with(".csv") => ExportFormat::Csv,
        None => ExportFormat::Json,
    }
}

/// `rallo export --output PATH [--format json|csv] [--force]` (0004). Never
/// nudges the app: exporting reads the store, it never changes it.
/// `--output -` writes the export bytes directly to stdout and skips the
/// usual envelope, since the payload itself is what "-" asks for.
pub fn export(
    out: &Output,
    store: &Store,
    output: &str,
    format: Option<ExportFormatArg>,
    force: bool,
) -> CommandResult {
    let format = infer_export_format(output, format);
    if output == "-" {
        let bytes = store.export_bytes(format)?;
        io::stdout().lock().write_all(&bytes)?;
        return Ok(());
    }
    let summary = store.export_to_file(Path::new(output), format, force)?;
    out.success(json!({ "export": { "items": summary.items, "path": summary.path, "format": format } }), &[], || {
        format!(
            "Exported {} note{} to {} ({}).",
            summary.items,
            if summary.items == 1 { "" } else { "s" },
            summary.path.display(),
            export_format_name(format)
        )
    });
    Ok(())
}

fn read_import_bytes(file: &str) -> Result<Vec<u8>, Failure> {
    // Read one byte past the cap so the core's own size check still fires
    // with its documented message, rather than a bounded read silently
    // truncating an oversized document.
    let bound = MAX_IMPORT_BYTES as u64;
    let mut bytes = Vec::new();
    if file == "-" {
        io::stdin().lock().take(bound + 1).read_to_end(&mut bytes)?;
    } else {
        let handle = std::fs::File::open(file).map_err(|error| {
            Failure::new(
                Exit::InvalidInput,
                ErrorCode::InvalidInput.as_str(),
                format!("could not open {file}: {error}"),
            )
        })?;
        handle.take(bound + 1).read_to_end(&mut bytes)?;
    }
    Ok(bytes)
}

fn import_fields(report: &ImportReport) -> Value {
    json!({
        "format": report.format,
        "total_records": report.total_records,
        "new": report.new,
        "identical": report.identical,
        "conflicts": report.conflicts,
        "applied": report.applied,
        "backup_path": report.backup_path,
    })
}

fn import_human(report: &ImportReport, dry_run: bool) -> String {
    let verb = if dry_run { "Would import" } else { "Imported" };
    let mut line = format!(
        "{verb} {} note{} ({} already here, skipped).",
        report.new,
        if report.new == 1 { "" } else { "s" },
        report.identical
    );
    if report.new > 0 {
        line.push_str(" Imported reminders stay off until you reschedule them.");
    }
    if let Some(path) = &report.backup_path {
        line.push_str(&format!(" Backup saved to {}.", path.display()));
    }
    line
}

/// `rallo import --file PATH [--dry-run]` (0004). Any conflict fails the
/// whole call (exit 4) with nothing changed, dry run or not. Never launches
/// the app; a successful, non-dry-run import signals one that is already
/// running (the same helper `hide` uses).
pub fn import(out: &Output, store: &mut Store, file: &str, dry_run: bool) -> CommandResult {
    let bytes = read_import_bytes(file)?;
    let report = if dry_run { store.preview_import(&bytes)? } else { store.apply_import(&bytes)? };
    if !dry_run {
        signal_if_running(store.data_dir());
    }
    let warnings = report.warnings.clone();
    out.success(import_fields(&report), &warnings, || import_human(&report, dry_run));
    Ok(())
}

/// `rallo backup [--output PATH] [--force]` (M4): a consistent snapshot via
/// the existing SQLite online-backup code. Never starts or signals the app --
/// it only reads the store, the same as `export`.
pub fn backup(out: &Output, store: &Store, output: Option<&str>, force: bool) -> CommandResult {
    let destination = match output {
        Some(path) => PathBuf::from(path),
        None => rallo_core::storage::backup::default_manual_backup_path(store.data_dir(), store.now_ms()),
    };
    let summary = store.backup_to_file(&destination, force)?;
    out.success(json!({ "backup": { "path": summary.path, "bytes": summary.bytes } }), &[], || {
        format!("Backup saved to {} ({} bytes).", summary.path.display(), summary.bytes)
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
        warnings.push(format!("the change is saved, but the Rallo app was not started: {error}"));
    }
}

/// Existing nudge behaviour for plain note/edit/done/reopen/delete/restore
/// writes (build plan §5): signal a running app; otherwise only background-
/// launch it if the pet is visible. Never fails the command.
fn nudge_passive(store: &Store, warnings: &mut Vec<String>) {
    if store.pet_visibility().unwrap_or(None) == Some(PetVisibility::Visible) {
        nudge_app(store.data_dir(), launch::LaunchMode::Background, warnings);
    } else {
        signal_if_running(store.data_dir());
    }
}

/// Nudge for a command that changed reminder scheduling/cancellation intent
/// (build plan §5/§8): signal if running, else background-launch, regardless
/// of pet visibility, since native work is now pending. A launch failure is a
/// warning; the exit code stays 0.
fn nudge_reminder_intent(store: &Store, warnings: &mut Vec<String>) {
    nudge_app(store.data_dir(), launch::LaunchMode::Background, warnings);
}

/// `done`/`delete`/`edit` only queue a reminder intent conditionally (an
/// active reminder being cancelled, or a preview payload refresh); other
/// mutations touch no reminder at all. A pending schedule or cancel intent on
/// the resulting item is the signal that this call (or an idempotent replay
/// of it) left native work for the app to do.
fn touched_reminder_intent(outcome: &MutationOutcome) -> bool {
    outcome.changed && (outcome.scheduling.is_some() || outcome.cancellation.is_some())
}

fn nudge_after(store: &Store, outcome: &MutationOutcome, warnings: &mut Vec<String>) {
    if touched_reminder_intent(outcome) {
        nudge_reminder_intent(store, warnings);
    } else {
        nudge_passive(store, warnings);
    }
}
