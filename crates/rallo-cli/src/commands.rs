use std::env;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use rallo_core::agents::{AgentKind, AgentSession, AgentState};
use rallo_core::items::{ItemView, ListFilter, ListQuery, MutationOptions, MutationOutcome, Page, SearchQuery};
use rallo_core::preferences::PetVisibility;
use rallo_core::reminders::{CancellationStatus, ReminderState, SchedulingStatus, TimeSpec};
use rallo_core::shared::{signal, text};
use rallo_core::storage::instance_lock::InstanceLock;
use rallo_core::storage::migrations::SCHEMA_VERSION;
use rallo_core::transfer::{ExportFormat, ImportReport, MAX_IMPORT_BYTES};
use rallo_core::{ErrorCode, Store};
use rallo_platform_macos::{archive, change_signal, launch, process_ancestry, terminal_command};
use serde_json::{Value, json};

use crate::args::ExportFormatArg;
use crate::local_time::format_local;
use crate::output::{Exit, Failure, Output, preview};
use crate::skill;

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
    let directory = link.parent().unwrap_or(link);
    // Off PATH: add it for new terminals rather than leave it to the user.
    let profile = if on_path {
        None
    } else {
        terminal_command::home_dir().and_then(|home| {
            terminal_command::add_to_login_profile(&terminal_command::user_shell(), &home, directory).ok().flatten()
        })
    };
    let mut warnings = Vec::new();
    if !on_path && profile.is_none() {
        warnings.push(format!("{} is not on your PATH.", directory.display()));
    }
    let noninteractive_fix = if on_path {
        terminal_command::home_dir().and_then(|home| crate::doctor::noninteractive_fix(link, &home))
    } else {
        None
    };
    out.success(
        json!({
            "terminal": {
                "status": status,
                "link": link,
                "target": target,
                "on_path": on_path,
                "path_export": if on_path { None } else { Some(PATH_EXPORT) },
                "profile_updated": profile,
                "noninteractive_fix": noninteractive_fix,
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
                let mut text = format!("{headline}\nTry it: rallo note \"Call the dentist\"");
                if let Some(fix) = &noninteractive_fix {
                    text.push_str(&format!(
                        "\nTools that run commands without an interactive terminal (some agents, IDE tasks) won't \
                         find it yet. To fix that:\n  {fix}"
                    ));
                }
                text
            } else if let Some(profile) = &profile {
                format!(
                    "{headline}\nAdded {} to your PATH in {}. Open a new terminal window to use `rallo` \
                     (or run: source {}).",
                    directory.display(),
                    profile.display(),
                    profile.display()
                )
            } else {
                format!(
                    "{headline}\n{} isn't on your PATH. Add this line to your shell's startup file, then open a new terminal:\n  {PATH_EXPORT}\nFull path: {}",
                    directory.display(),
                    target.display()
                )
            }
        },
    );
    Ok(())
}

/// `setup skill`: installs the embedded agent skill (`skill.rs`) for every
/// detected agent (Claude Code, Cursor, Codex), or the ones named by
/// `--agent`; Codex also gets a `rallo.rules` execpolicy file. Inspects every
/// chosen target before writing anything, so a foreign file at any of them
/// fails the whole command with nothing written. Never touches a data
/// directory and never starts the app.
pub fn setup_skill(out: &Output, print: bool, agents: Vec<skill::Agent>) -> CommandResult {
    if print {
        out.success(json!({ "skill": { "content": skill::SKILL } }), &[], || skill::SKILL.trim_end().to_owned());
        return Ok(());
    }
    let home = terminal_command::home_dir()
        .ok_or_else(|| Failure::new(Exit::InvalidInput, "INVALID_INPUT", "$HOME is not set"))?;

    let targets: Vec<skill::Agent> = if agents.is_empty() {
        let detected: Vec<skill::Agent> =
            skill::Agent::ALL.into_iter().filter(|&agent| skill::detected(agent, &home)).collect();
        if detected.is_empty() { vec![skill::Agent::Claude] } else { detected }
    } else {
        agents
    };

    struct Target {
        agent: skill::Agent,
        skill_path: PathBuf,
        skill_state: skill::State,
        rules: Option<(PathBuf, String, skill::State)>,
    }

    let plan: Vec<Target> = targets
        .into_iter()
        .map(|agent| {
            let skill_path = skill::skill_path(agent, &home);
            let skill_state = skill::inspect_skill(&skill_path);
            let rules = (agent == skill::Agent::Codex).then(|| {
                let rules_path = skill::rules_path(&home);
                let content = skill::rules_content(&home);
                let state = skill::inspect_rules(&rules_path, &content);
                (rules_path, content, state)
            });
            Target { agent, skill_path, skill_state, rules }
        })
        .collect();

    let mut foreign_paths = Vec::new();
    for target in &plan {
        if matches!(target.skill_state, skill::State::Foreign) {
            foreign_paths.push(target.skill_path.clone());
        }
        if let Some((rules_path, _, state)) = &target.rules
            && matches!(state, skill::State::Foreign)
        {
            foreign_paths.push(rules_path.clone());
        }
    }
    if !foreign_paths.is_empty() {
        let listed = foreign_paths.iter().map(|path| path.display().to_string()).collect::<Vec<_>>().join(", ");
        return Err(Failure::new(
            Exit::Conflict,
            "SKILL_CONFLICT",
            format!("{listed} isn't Rallo's, so Rallo won't replace it. `rallo setup skill --print` shows Rallo's."),
        ));
    }

    let mut installs = Vec::new();
    let mut lines = Vec::new();
    let mut names: Vec<&str> = Vec::new();
    for target in plan {
        names.extend(match target.agent {
            skill::Agent::Claude => ["Claude Code", "Cursor"].as_slice(),
            skill::Agent::Codex => ["Codex"].as_slice(),
            skill::Agent::Grok => ["Grok"].as_slice(),
            skill::Agent::Gemini => ["Gemini CLI"].as_slice(),
        });
        let status = match target.skill_state {
            skill::State::Current => "already_installed",
            skill::State::Missing => "installed",
            skill::State::Outdated => "updated",
            skill::State::Foreign => unreachable!("foreign targets were already rejected above"),
        };
        if status != "already_installed" {
            skill::install_skill(&target.skill_path)
                .map_err(|error| Failure::new(Exit::InvalidInput, "SKILL_SETUP_FAILED", error.to_string()))?;
        }

        let rules_json = if let Some((rules_path, content, state)) = target.rules {
            let rules_status = match state {
                skill::State::Current => "already_installed",
                skill::State::Missing => "installed",
                skill::State::Outdated => "updated",
                skill::State::Foreign => unreachable!("foreign targets were already rejected above"),
            };
            if rules_status != "already_installed" {
                skill::install_rules(&rules_path, &content)
                    .map_err(|error| Failure::new(Exit::InvalidInput, "SKILL_SETUP_FAILED", error.to_string()))?;
            }
            Some(json!({ "status": rules_status, "path": rules_path }))
        } else {
            None
        };

        let headline = match status {
            "already_installed" => format!("The Rallo skill for {} is already installed", target.agent.label()),
            "updated" => format!("Updated the Rallo skill for {}", target.agent.label()),
            _ => format!("Installed the Rallo skill for {}", target.agent.label()),
        };
        let rules_note = if target.agent == skill::Agent::Codex {
            " (and rallo.rules, so Codex runs Rallo's note commands without asking)"
        } else {
            ""
        };
        lines.push(format!("{headline} at {}{rules_note}.", target.skill_path.display()));

        installs.push(json!({
            "agent": target.agent.json_name(),
            "status": status,
            "path": target.skill_path,
            "rules": rules_json,
        }));
    }

    let on_path = env::var_os("PATH")
        .is_some_and(|value| env::split_paths(&value).any(|dir| dir.join(terminal_command::NAME).is_file()));
    let warnings: Vec<String> = if on_path {
        Vec::new()
    } else {
        vec!["Agents run `rallo` from PATH, and it isn't there yet: run `rallo setup terminal`.".into()]
    };

    out.success(json!({ "skill": { "installs": installs } }), &warnings, || {
        let (last, rest) = names.split_last().expect("at least one agent is always targeted");
        let who = if rest.is_empty() {
            last.to_string()
        } else {
            format!("{}{} and {last}", rest.join(", "), if rest.len() > 1 { "," } else { "" })
        };
        let (verb, pronoun) = if rest.is_empty() { ("picks", "it") } else { ("pick", "one") };
        let hint = format!("{who} {verb} it up from there; ask {pronoun} to \"note that …\" or \"remind me …\".");
        lines.push(hint);
        lines.join("\n")
    });
    Ok(())
}

fn to_core_agent(agent: skill::Agent) -> AgentKind {
    match agent {
        skill::Agent::Claude => AgentKind::Claude,
        skill::Agent::Codex => AgentKind::Codex,
        skill::Agent::Grok => AgentKind::Grok,
        skill::Agent::Gemini => AgentKind::Gemini,
    }
}

/// `Xs ago` / `X min ago` / `Xh ago` / `Xd ago`; never negative.
fn agent_age(now_ms: i64, at_ms: i64) -> String {
    let secs = ((now_ms - at_ms) / 1000).max(0);
    if secs < 60 {
        format!("{secs}s ago")
    } else if secs < 3600 {
        format!("{} min ago", secs / 60)
    } else if secs < 86_400 {
        format!("{}h ago", secs / 3600)
    } else {
        format!("{}d ago", secs / 86_400)
    }
}

fn agent_detail_phrase(state: AgentState, detail: Option<&str>) -> String {
    match (state, detail) {
        (AgentState::Waiting, Some(tool)) => format!("Waiting for permission: {tool}"),
        (AgentState::Waiting, None) => "Waiting for you".to_owned(),
        (AgentState::Working, _) => "Working".to_owned(),
        (AgentState::Dismissed, _) => "Dismissed".to_owned(),
    }
}

/// Distinct from `skill::Agent::label` ("Claude Code and Cursor"): this is
/// the shorter, hook-flavoured name `setup hooks`/`doctor` also use.
fn agent_kind_label(agent: AgentKind) -> &'static str {
    match agent {
        AgentKind::Claude => "Claude Code",
        AgentKind::Codex => "Codex",
        AgentKind::Grok => "Grok",
        AgentKind::Gemini => "Gemini CLI",
        AgentKind::ClickUp => "ClickUp",
    }
}

fn agent_line(session: &AgentSession, now_ms: i64) -> String {
    let label = agent_kind_label(session.agent);
    if session.agent == AgentKind::ClickUp {
        let what = if session.detail.as_deref() == Some("group") { "Group message" } else { "Messaged you" };
        return format!(
            "{}  {label} · {} — {what} · {}",
            session.state.as_str(),
            session.place.as_deref().unwrap_or("someone"),
            agent_age(now_ms, session.updated_at_ms)
        );
    }
    let location = session.place.as_deref().unwrap_or("unknown directory");
    format!(
        "{}  {label} · {location} — {} · {}",
        session.state.as_str(),
        agent_detail_phrase(session.state, session.detail.as_deref()),
        agent_age(now_ms, session.updated_at_ms)
    )
}

fn agent_session_json(session: &AgentSession) -> Value {
    json!({
        "agent": session.agent.as_str(),
        "session_id": session.session_id,
        "state": session.state.as_str(),
        "place": session.place,
        "detail": session.detail,
        "app_path": session.app_path,
        "app_pid": session.app_pid,
        "focus": session.focus,
        "updated_at_ms": session.updated_at_ms,
    })
}

/// `rallo agents [--json]` (0007, 0009): fresh `waiting` sessions whose
/// agent is still running, most recent first. Prunes sessions whose agent
/// has gone, signalling a running app if it did; never launches the app.
pub fn agents_list(out: &Output, store: &mut Store) -> CommandResult {
    let now_ms = store.now_ms();
    if store.prune_agent_sessions(now_ms, &|p| process_ancestry::is_alive(p.pid, p.started_us))? {
        signal_if_running(store.data_dir());
    }
    let sessions = store.agent_sessions(now_ms)?;
    let fields = json!({ "sessions": sessions.iter().map(agent_session_json).collect::<Vec<_>>() });
    out.success(fields, &[], || {
        if sessions.is_empty() {
            "No agent sessions.".to_owned()
        } else {
            sessions.iter().map(|session| agent_line(session, now_ms)).collect::<Vec<_>>().join("\n")
        }
    });
    Ok(())
}

/// `rallo agents clear [--agent A] [--session ID]` (0007): removes tracked
/// sessions (any freshness, not just the ones `agents_list` would show), and
/// signals a running app when it actually removed anything.
pub fn agents_clear(
    out: &Output,
    store: &mut Store,
    agent: Option<skill::Agent>,
    session: Option<String>,
) -> CommandResult {
    let cleared = store.clear_agent_sessions(agent.map(to_core_agent), session.as_deref())?;
    if cleared > 0 {
        signal_if_running(store.data_dir());
    }
    out.success(json!({ "cleared": cleared }), &[], || {
        format!("Cleared {cleared} agent session{}.", if cleared == 1 { "" } else { "s" })
    });
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

/// Reads `--image` files (0018): the size is checked before reading, so a
/// huge file is refused without loading it.
fn read_images(paths: &[PathBuf]) -> Result<Vec<Vec<u8>>, Failure> {
    paths
        .iter()
        .map(|path| {
            let unreadable = |error: std::io::Error| {
                Failure::new(Exit::InvalidInput, "IMAGE_UNREADABLE", format!("can't read {}: {error}", path.display()))
            };
            let size = std::fs::metadata(path).map_err(unreadable)?.len();
            if size > rallo_core::images::MAX_IMAGE_BYTES as u64 {
                return Err(Failure::new(
                    Exit::InvalidInput,
                    "IMAGE_TOO_LARGE",
                    format!("{} is {:.1} MB; the limit is 10 MB", path.display(), size as f64 / (1024.0 * 1024.0)),
                ));
            }
            // Bounded read: a device or FIFO reports a length of 0 and never ends.
            let mut bytes = Vec::new();
            std::fs::File::open(path)
                .and_then(|file| file.take(rallo_core::images::MAX_IMAGE_BYTES as u64 + 1).read_to_end(&mut bytes))
                .map_err(unreadable)?;
            if bytes.len() > rallo_core::images::MAX_IMAGE_BYTES {
                return Err(Failure::new(
                    Exit::InvalidInput,
                    "IMAGE_TOO_LARGE",
                    format!("{} is over 10 MB; the limit is 10 MB", path.display()),
                ));
            }
            Ok(bytes)
        })
        .collect()
}

fn images_suffix(view: &ItemView) -> String {
    match view.images.len() {
        0 => String::new(),
        1 => " · 1 image".to_owned(),
        n => format!(" · {n} images"),
    }
}

/// The note's text for a human line; a text-less (image-only) note reads `(image)`.
fn quoted(view: &ItemView, max: usize) -> String {
    if view.item.text.is_empty() { "(image)".to_owned() } else { format!("“{}”", preview(&view.item.text, max)) }
}

pub fn note(
    out: &Output,
    store: &mut Store,
    arg_text: Option<String>,
    from_stdin: bool,
    images: Vec<PathBuf>,
    request_id: Option<String>,
) -> CommandResult {
    let images = read_images(&images)?;
    let note_text = if arg_text.is_none() && !from_stdin { String::new() } else { resolve_text(arg_text, from_stdin)? };
    let outcome = store.create_note_with_images(&note_text, &images, request_id.as_deref())?;
    let view = &outcome.item;
    // Committed. Everything below is a best-effort nudge to the app.
    let mut warnings = Vec::new();
    nudge_passive(store, &mut warnings);
    out.success(mutation_fields(&outcome), &warnings, || {
        if view.item.text.is_empty() {
            format!("Saved an image note ({})", view.display_id)
        } else {
            format!("Saved {} ({}){}", quoted(view, 80), view.display_id, images_suffix(view))
        }
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
    images: Vec<PathBuf>,
    when: TimeSpec,
    request_id: Option<String>,
) -> CommandResult {
    let images = read_images(&images)?;
    let note_text = if arg_text.is_none() && !from_stdin { String::new() } else { resolve_text(arg_text, from_stdin)? };
    let outcome = store.create_reminder_with_images(&note_text, &when, &images, request_id.as_deref())?;
    let view = &outcome.item;
    let mut warnings = Vec::new();
    nudge_reminder_intent(store, &mut warnings);
    let deadline_ms = view.reminder.as_ref().expect("remind always attaches a reminder").deadline_ms;
    out.success(mutation_fields(&outcome), &warnings, || {
        // Never "Reminder set": the app has not yet confirmed native scheduling (M2).
        format!(
            "Saved {} ({}){}; reminder at {} — scheduling pending",
            quoted(view, 80),
            view.display_id,
            images_suffix(view),
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
    let text = if view.item.text.is_empty() { "(image)".to_owned() } else { preview(&view.item.text, 100) };
    format!("{}  {marker}{text}{reminder}{}", view.display_id, images_suffix(view))
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
        quoted(view, 200),
    ];
    for image in &view.images {
        lines.push(format!("Image: {} {}", image.mime_type, image.path.display()));
    }
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
            format!("Updated {} ({})", quoted(view, 80), view.display_id)
        } else {
            format!("No change: {} ({}) already matches.", quoted(view, 80), view.display_id)
        }
    });
    Ok(())
}

pub fn attach(out: &Output, store: &mut Store, id: &str, paths: &[PathBuf], opts: MutationOptions) -> CommandResult {
    let images = read_images(paths)?;
    let outcome = store.attach_images(id, &images, &opts)?;
    let mut warnings = Vec::new();
    nudge_after(store, &outcome, &mut warnings);
    let view = &outcome.item;
    out.success(mutation_fields(&outcome), &warnings, || {
        let added = if images.len() == 1 { "1 image".to_owned() } else { format!("{} images", images.len()) };
        format!("Added {added} to {}{}", view.display_id, images_suffix(view))
    });
    Ok(())
}

pub fn detach(out: &Output, store: &mut Store, id: &str, image_id: &str, opts: MutationOptions) -> CommandResult {
    let outcome = store.detach_image(id, image_id, &opts)?;
    let mut warnings = Vec::new();
    nudge_after(store, &outcome, &mut warnings);
    let view = &outcome.item;
    out.success(mutation_fields(&outcome), &warnings, || {
        format!("Removed the image from {}{}", view.display_id, images_suffix(view))
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
            format!("Done: {} ({})", quoted(view, 80), view.display_id)
        } else {
            format!("Already done: {} ({})", quoted(view, 80), view.display_id)
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
            format!("Reopened {} ({})", quoted(view, 80), view.display_id)
        } else {
            format!("Already open: {} ({})", quoted(view, 80), view.display_id)
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
            format!("Restored {} ({}){reminder_note}", quoted(view, 80), view.display_id)
        } else {
            format!("Not deleted: {} ({})", quoted(view, 80), view.display_id)
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
            "Rescheduled {} ({}); reminder at {} — scheduling pending",
            quoted(view, 80),
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
            "Snoozed {} ({}); reminder at {} — scheduling pending",
            quoted(view, 80),
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
            format!("Acknowledged {} ({})", quoted(view, 80), view.display_id)
        } else {
            format!("No active reminder to acknowledge: {} ({})", quoted(view, 80), view.display_id)
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
            format!("Reminder cancelled for {} ({})", quoted(view, 80), view.display_id)
        } else {
            format!("No active reminder to cancel: {} ({})", quoted(view, 80), view.display_id)
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
            format!("Deleted {}. Undo: rallo restore {}", quoted(view, 80), view.display_id)
        } else {
            format!("Already deleted: {}. Undo: rallo restore {}", quoted(view, 80), view.display_id)
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
/// `.csv` is CSV, `.zip` a zip, anything else (including "-" for stdout) is
/// JSON. `None` is a zip archive (0018); the core has no single-file format for it.
fn infer_export_format(output: &str, explicit: Option<ExportFormatArg>) -> Option<ExportFormat> {
    let lower = output.to_ascii_lowercase();
    match explicit {
        Some(ExportFormatArg::Json) => Some(ExportFormat::Json),
        Some(ExportFormatArg::Csv) => Some(ExportFormat::Csv),
        Some(ExportFormatArg::Zip) => None,
        None if lower.ends_with(".csv") => Some(ExportFormat::Csv),
        None if lower.ends_with(".zip") => None,
        None => Some(ExportFormat::Json),
    }
}

fn export_zip(out: &Output, store: &Store, output: &str, force: bool) -> CommandResult {
    if output == "-" {
        return Err(Failure::new(
            Exit::InvalidInput,
            ErrorCode::InvalidInput.as_str(),
            "a zip export needs a file path, not \"-\"",
        ));
    }
    let path = Path::new(output);
    rallo_core::transfer::export::refuse_existing(path, force)?;
    let summary = archive::write_zip(path, |dir| -> Result<_, Failure> { Ok(store.export_to_dir(dir)?) })?;
    out.success(
        json!({ "export": { "items": summary.items, "path": path, "format": "zip" } }),
        &summary.warnings,
        || {
            format!(
                "Exported {} note{} with their images to {} (zip).",
                summary.items,
                if summary.items == 1 { "" } else { "s" },
                path.display()
            )
        },
    );
    Ok(())
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
    let Some(format) = infer_export_format(output, format) else {
        return export_zip(out, store, output, force);
    };
    if output == "-" {
        let bytes = store.export_bytes(format)?;
        io::stdout().lock().write_all(&bytes)?;
        for warning in store.export_warnings(format)? {
            eprintln!("warning: {warning}");
        }
        return Ok(());
    }
    let summary = store.export_to_file(Path::new(output), format, force)?;
    out.success(
        json!({ "export": { "items": summary.items, "path": summary.path, "format": format } }),
        &summary.warnings,
        || {
            format!(
                "Exported {} note{} to {} ({}).",
                summary.items,
                if summary.items == 1 { "" } else { "s" },
                summary.path.display(),
                export_format_name(format)
            )
        },
    );
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

fn import_fields(report: &ImportReport, zip: bool) -> Value {
    json!({
        "format": if zip { json!("zip") } else { json!(report.format) },
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
    let zip = file != "-" && archive::is_zip(Path::new(file)).unwrap_or(false);
    let report = if zip {
        archive::read_zip(Path::new(file), |dir| -> Result<ImportReport, Failure> {
            Ok(if dry_run { store.preview_import_dir(dir)? } else { store.apply_import_dir(dir)? })
        })?
    } else {
        let bytes = read_import_bytes(file)?;
        if dry_run { store.preview_import(&bytes)? } else { store.apply_import(&bytes)? }
    };
    if !dry_run {
        signal_if_running(store.data_dir());
    }
    let warnings = report.warnings.clone();
    out.success(import_fields(&report, zip), &warnings, || import_human(&report, dry_run));
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
    out.success(
        json!({ "backup": { "path": summary.path, "bytes": summary.bytes, "images": summary.images } }),
        &[],
        || {
            let images = if summary.images > 0 { format!(", {} images", summary.images) } else { String::new() };
            format!("Backup saved to {} ({} bytes{images}).", summary.path.display(), summary.bytes)
        },
    );
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
