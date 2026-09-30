//! `rallo doctor` (M4, build plan §8/§10): a read-only health report. Unlike
//! every other command, this never opens a `Store` (which would migrate an
//! older schema under the write lock): it uses
//! `rallo_core::storage::inspect` instead, and never signals or launches the
//! app.

use std::env;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use rallo_core::reminders::{MAX_ACTIVE_REMINDERS, NotificationAuthorization};
use rallo_core::shared::clock::{Clock, SystemClock};
use rallo_core::storage::inspect::{self, StoreInspection};
use rallo_core::storage::instance_lock::InstanceLock;
use rallo_core::storage::migrations::SCHEMA_VERSION;
use rallo_core::storage::paths;
use rallo_platform_macos::{launch, terminal_command};
use serde_json::{Value, json};

use crate::output::{Exit, Failure, Output};
use crate::skill;

/// Active reminders at or above this count warn ahead of the hard 32 limit
/// (0003 §4).
const CAPACITY_WARNING_THRESHOLD: u32 = 28;
/// An unresolved intent older than this while the app is running suggests a
/// stuck drain rather than ordinary backoff (0005's retries top out at 60 s).
const STUCK_DRAIN_THRESHOLD_MS: i64 = 5 * 60 * 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum CheckStatus {
    Ok,
    Warning,
    Problem,
}

impl CheckStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Warning => "warning",
            Self::Problem => "problem",
        }
    }
}

struct Check {
    id: &'static str,
    status: CheckStatus,
    summary: String,
    fix: Option<String>,
}

impl Check {
    fn new(id: &'static str, status: CheckStatus, summary: impl Into<String>, fix: Option<String>) -> Self {
        Self { id, status, summary: summary.into(), fix }
    }

    fn to_json(&self) -> Value {
        json!({ "id": self.id, "status": self.status.as_str(), "summary": self.summary, "fix": self.fix })
    }
}

/// `rallo doctor [--json]`. Resolves the data directory but never creates it;
/// every check below tolerates "nothing there yet".
pub fn run(out: &Output, data_dir_arg: Option<&Path>) -> Result<ExitCode, Failure> {
    let data_dir = paths::resolve_data_dir(data_dir_arg)?;
    let now_ms = SystemClock.now_ms();
    // A pure metadata read: never creates the directory, unlike
    // `InstanceLock::is_held` or `Store::open`.
    let data_dir_exists = data_dir.is_dir();
    let inspection = StoreInspection::open(&data_dir, now_ms)?;
    let backups = inspect::inspect_backups(&data_dir.join("backups"));

    let home = terminal_command::home_dir();
    let (app_install, app) = check_app_install(home.as_deref());
    let terminal_command_check = check_terminal_command(app.as_deref(), home.as_deref());
    let agent_skill = check_agent_skill(home.as_deref());
    let data_directory = check_data_directory(&data_dir, inspection.as_ref());

    // Only probe the instance lock if the data directory already exists:
    // `InstanceLock::is_held` creates the lock file otherwise, and doctor
    // must never write anything for a fresh install.
    let running = if data_dir_exists { InstanceLock::is_held(&data_dir)? } else { false };
    let unresolved = inspection.as_ref().map(|i| i.intents.unresolved_count).unwrap_or(0);
    let app_running = check_app_running(data_dir_exists, running, unresolved);
    let notifications = check_notifications(inspection.as_ref(), now_ms);
    let reminders = check_reminders(inspection.as_ref(), running, now_ms);
    let backups_check = check_backups(&backups, now_ms);

    let checks = [
        app_install,
        terminal_command_check,
        agent_skill,
        data_directory,
        app_running,
        notifications,
        reminders,
        backups_check,
    ];
    let problem_count = checks.iter().filter(|c| c.status == CheckStatus::Problem).count();
    let warning_count = checks.iter().filter(|c| c.status == CheckStatus::Warning).count();
    let ok = problem_count == 0;

    let fields = json!({
        "ok": ok,
        "checks": checks.iter().map(Check::to_json).collect::<Vec<_>>(),
        "problem_count": problem_count,
        "warning_count": warning_count,
    });
    out.success(fields, &[], || human_report(&checks));
    Ok(ExitCode::from(if ok { Exit::Success } else { Exit::DoctorProblems }))
}

fn human_report(checks: &[Check]) -> String {
    let mut lines = Vec::with_capacity(checks.len() * 2);
    for check in checks {
        let marker = match check.status {
            CheckStatus::Ok => "[ok]",
            CheckStatus::Warning => "[warning]",
            CheckStatus::Problem => "[problem]",
        };
        lines.push(format!("{marker} {}: {}", check.id, check.summary));
        if let Some(fix) = &check.fix {
            lines.push(format!("    fix: {fix}"));
        }
    }
    lines.join("\n")
}

/// `Xs ago` / `Xm ago` / `Xh ago` / `Xd ago`; never negative (a clock that
/// moved backward since the observation just reads as "just now").
fn format_age(delta_ms: i64) -> String {
    let secs = (delta_ms / 1000).max(0);
    if secs < 60 {
        format!("{secs}s ago")
    } else if secs < 3600 {
        format!("{}m ago", secs / 60)
    } else if secs < 86_400 {
        format!("{}h ago", secs / 3600)
    } else {
        format!("{}d ago", secs / 86_400)
    }
}

fn age_suffix(observed_at_ms: Option<i64>, now_ms: i64) -> String {
    match observed_at_ms {
        Some(at) => format!(", observed {}", format_age(now_ms - at)),
        None => String::new(),
    }
}

/// `app_install`: the app bundle containing this running CLI (spec §10,
/// reusing `launch::locate_app`'s resolution), whether it is an installed
/// copy, and whether this CLI is the one embedded inside it. Returns the
/// located app path too, so `terminal_command` can reuse it without asking
/// LaunchServices/the filesystem twice.
fn check_app_install(home: Option<&Path>) -> (Check, Option<PathBuf>) {
    let running_exe = env::current_exe().and_then(|exe| exe.canonicalize()).ok();
    let app = match launch::locate_app() {
        Ok(app) => app,
        Err(error) => {
            return (
                Check::new(
                    "app_install",
                    CheckStatus::Warning,
                    format!("Could not locate an installed Rallo app for this CLI: {error}"),
                    Some(
                        "Move Rallo.app into /Applications or ~/Applications, or set RALLO_APP_PATH for development."
                            .to_owned(),
                    ),
                ),
                None,
            );
        }
    };
    let installed = home.is_some_and(|home| terminal_command::is_installed(&app, home));
    if !installed {
        return (
            Check::new(
                "app_install",
                CheckStatus::Warning,
                format!("Rallo is running from {}, not an installed copy.", app.display()),
                Some(format!("Move {} into /Applications or ~/Applications.", app.display())),
            ),
            Some(app),
        );
    }
    let embedded_cli = terminal_command::cli_path(&app);
    if running_exe.as_deref() == Some(embedded_cli.as_path()) {
        (
            Check::new(
                "app_install",
                CheckStatus::Ok,
                format!("Installed at {} (this CLI is the one embedded in it).", app.display()),
                None,
            ),
            Some(app),
        )
    } else {
        let running = running_exe.as_ref().map(|path| path.display().to_string()).unwrap_or_default();
        (
            Check::new(
                "app_install",
                CheckStatus::Warning,
                format!(
                    "This CLI ({running}) is not the one embedded in the installed app ({}); versions may differ.",
                    embedded_cli.display()
                ),
                Some(format!("Run the CLI at {} instead, or reinstall Rallo.", embedded_cli.display())),
            ),
            Some(app),
        )
    }
}

/// `terminal_command`: reuses `terminal_command::inspect` against the app
/// `check_app_install` located.
fn check_terminal_command(app: Option<&Path>, home: Option<&Path>) -> Check {
    let (Some(app), Some(home)) = (app, home) else {
        return Check::new(
            "terminal_command",
            CheckStatus::Ok,
            "Not checked: no installed app located (see app_install).",
            None,
        );
    };
    let path_dirs: Vec<PathBuf> =
        env::var_os("PATH").map(|value| env::split_paths(&value).collect()).unwrap_or_default();
    match terminal_command::inspect(app, home, &path_dirs) {
        terminal_command::State::NotInstalled => Check::new(
            "terminal_command",
            CheckStatus::Ok,
            "Not checked: the located app is not an installed copy (see app_install).",
            None,
        ),
        terminal_command::State::Enabled { link, on_path: true } => match noninteractive_fix(&link, home) {
            None => Check::new(
                "terminal_command",
                CheckStatus::Ok,
                format!("`rallo` is set up at {}.", link.display()),
                None,
            ),
            Some(fix) => Check::new(
                "terminal_command",
                CheckStatus::Warning,
                format!(
                    "`rallo` works in interactive terminals, but tools that run commands without one (some agents, \
                     IDE tasks) won't find it: {} is only on PATH in interactive shells.",
                    link.parent().unwrap_or(&link).display()
                ),
                Some(fix),
            ),
        },
        terminal_command::State::Enabled { link, on_path: false } => {
            let directory = link.parent().unwrap_or(&link);
            Check::new(
                "terminal_command",
                CheckStatus::Warning,
                format!("`rallo` is set up at {}, but {} is not on PATH.", link.display(), directory.display()),
                Some(format!(r#"export PATH="{}:$PATH""#, directory.display())),
            )
        }
        terminal_command::State::Available { .. } => Check::new(
            "terminal_command",
            CheckStatus::Warning,
            "The terminal command is not enabled yet.",
            Some("rallo setup terminal".to_owned()),
        ),
        terminal_command::State::Repairable { link, old_target, .. } => Check::new(
            "terminal_command",
            CheckStatus::Problem,
            format!("{} points at a moved or deleted app ({}).", link.display(), old_target.display()),
            Some("rallo setup terminal".to_owned()),
        ),
        terminal_command::State::Conflict { existing } => Check::new(
            "terminal_command",
            CheckStatus::Warning,
            format!("{} is not Rallo's own link; `rallo setup terminal` will not replace it.", existing.display()),
            None,
        ),
    }
}

/// Evaluates every detected agent's skill (and, for Codex, its
/// `rallo.rules`) and folds them into the one `agent_skill` check: any
/// outdated file outranks everything else, then Codex's skill being current
/// without rules, then "nothing detected has anything installed", then "every
/// detected agent is fully current"; anything else (a mix of installed,
/// missing, and foreign) is reported per agent without raising the status --
/// a foreign file is always left alone, never a `warning`/`problem`.
fn check_agent_skill(home: Option<&Path>) -> Check {
    let Some(home) = home else {
        return Check::new("agent_skill", CheckStatus::Ok, "Not checked: $HOME is not set.", None);
    };

    struct Entry {
        agent: skill::Agent,
        state: skill::State,
        path: PathBuf,
        rules: Option<(skill::State, PathBuf)>,
    }

    let entries: Vec<Entry> = skill::Agent::ALL
        .into_iter()
        .filter(|&agent| skill::detected(agent, home))
        .map(|agent| {
            let path = skill::skill_path(agent, home);
            let state = skill::inspect_skill(&path);
            let rules = (agent == skill::Agent::Codex).then(|| {
                let rules_path = skill::rules_path(home);
                let content = skill::rules_content(home);
                (skill::inspect_rules(&rules_path, &content), rules_path)
            });
            Entry { agent, state, path, rules }
        })
        .collect();

    if entries.is_empty() {
        return not_installed_check();
    }

    let outdated = entries.iter().any(|entry| {
        matches!(entry.state, skill::State::Outdated)
            || entry.rules.as_ref().is_some_and(|(r, _)| matches!(r, skill::State::Outdated))
    });
    if outdated {
        return Check::new(
            "agent_skill",
            CheckStatus::Warning,
            "An installed agent skill or Codex's rallo.rules is from another Rallo version.",
            Some("rallo setup skill".into()),
        );
    }

    let codex_rules_missing = entries.iter().any(|entry| {
        entry.agent == skill::Agent::Codex
            && matches!(entry.state, skill::State::Current)
            && entry.rules.as_ref().is_some_and(|(r, _)| matches!(r, skill::State::Missing))
    });
    if codex_rules_missing {
        return Check::new(
            "agent_skill",
            CheckStatus::Warning,
            "Codex's skill is installed, but rallo.rules is missing, so Codex will ask before running Rallo's \
             commands.",
            Some("rallo setup skill --agent codex".into()),
        );
    }

    let all_missing = entries.iter().all(|entry| {
        matches!(entry.state, skill::State::Missing)
            && entry.rules.as_ref().is_none_or(|(r, _)| matches!(r, skill::State::Missing))
    });
    if all_missing {
        return not_installed_check();
    }

    let all_current = entries.iter().all(|entry| {
        matches!(entry.state, skill::State::Current)
            && entry.rules.as_ref().is_none_or(|(r, _)| matches!(r, skill::State::Current))
    });
    if all_current {
        let installed: Vec<String> =
            entries.iter().map(|entry| format!("{} ({})", entry.agent.label(), entry.path.display())).collect();
        return Check::new("agent_skill", CheckStatus::Ok, format!("Installed for {}.", installed.join(" and ")), None);
    }

    let parts: Vec<String> = entries
        .iter()
        .map(|entry| match entry.state {
            skill::State::Current => format!("installed for {} ({})", entry.agent.label(), entry.path.display()),
            skill::State::Missing => format!("not installed for {}", entry.agent.label()),
            skill::State::Foreign => format!("{} isn't Rallo's skill; left alone", entry.path.display()),
            skill::State::Outdated => unreachable!("handled above"),
        })
        .collect();
    Check::new("agent_skill", CheckStatus::Ok, format!("{}.", parts.join("; ")), None)
}

fn not_installed_check() -> Check {
    Check::new(
        "agent_skill",
        CheckStatus::Ok,
        "Not installed (optional): `rallo setup skill` teaches Claude Code, Cursor, and Codex to use Rallo.",
        None,
    )
}

/// The line to add when `link`'s directory is missing from a non-interactive
/// login shell's PATH, or `None` when it's there (or the shell didn't answer).
pub(crate) fn noninteractive_fix(link: &Path, home: &Path) -> Option<String> {
    let directory = link.parent()?;
    let shell = terminal_command::user_shell();
    let path = terminal_command::noninteractive_login_path(&shell, std::time::Duration::from_secs(3))?;
    if path.iter().any(|entry| entry == directory) {
        return None;
    }
    let shown = match directory.strip_prefix(home) {
        Ok(relative) => format!("$HOME/{}", relative.display()),
        Err(_) => directory.display().to_string(),
    };
    Some(format!(r#"echo 'export PATH="{shown}:$PATH"' >> {}"#, terminal_command::login_profile(&shell)))
}

fn human_size(bytes: u64) -> String {
    match bytes {
        0..1024 => format!("{bytes} bytes"),
        1024..1_048_576 => format!("{:.1} KiB", bytes as f64 / 1024.0),
        _ => format!("{:.1} MiB", bytes as f64 / 1_048_576.0),
    }
}

/// `data_directory`: the path, directory/file permissions, schema version
/// versus what this build supports, `PRAGMA quick_check`, and database size.
fn check_data_directory(data_dir: &Path, inspection: Option<&StoreInspection>) -> Check {
    let Some(inspection) = inspection else {
        return Check::new("data_directory", CheckStatus::Ok, format!("{} — no data yet.", data_dir.display()), None);
    };

    let mut status = CheckStatus::Ok;
    let mut notes = Vec::new();
    let mut fixes = Vec::new();

    for (stat, expected_mode) in [
        (inspection.dir_stat.as_ref(), 0o700u32),
        (Some(&inspection.db_stat), 0o600),
        (inspection.wal_stat.as_ref(), 0o600),
        (inspection.shm_stat.as_ref(), 0o600),
    ] {
        if let Some(stat) = stat
            && stat.mode & 0o077 != 0
        {
            status = CheckStatus::Problem;
            notes.push(format!("{} is mode {:o} (should be {expected_mode:o})", stat.path.display(), stat.mode));
            fixes.push(format!("chmod {expected_mode:o} {}", stat.path.display()));
        }
    }

    let found = inspection.schema_version_found;
    if found > SCHEMA_VERSION {
        status = CheckStatus::Problem;
        notes.push(format!("schema version {found} is newer than this build supports ({SCHEMA_VERSION})"));
        fixes.push("Update Rallo to a version that supports this schema, or restore an older backup.".to_owned());
    } else if found < SCHEMA_VERSION {
        notes.push(format!(
            "schema version {found} will be migrated to {SCHEMA_VERSION} automatically the next time Rallo opens \
             the store or any write command runs"
        ));
    }

    if inspection.quick_check != "ok" {
        status = CheckStatus::Problem;
        notes.push(format!("integrity check reported: {}", inspection.quick_check));
        fixes.push(format!("Restore from a backup in {}.", data_dir.join("backups").display()));
    }

    // In WAL mode recent writes live in -wal until a checkpoint, so the
    // main file alone can look empty.
    let wal_bytes = inspection.wal_stat.as_ref().map_or(0, |wal| wal.size_bytes);
    notes.push(format!("{} on disk", human_size(inspection.db_stat.size_bytes + wal_bytes)));

    let summary = format!("{} — {}", data_dir.display(), notes.join("; "));
    let fix = (!fixes.is_empty()).then(|| fixes.join("; "));
    Check::new("data_directory", status, summary, fix)
}

/// `app_running`: whether the instance lock is held; a warning only when the
/// app is not running but unresolved notification intents are waiting on it.
fn check_app_running(data_dir_exists: bool, running: bool, unresolved_intents: u32) -> Check {
    if !data_dir_exists {
        return Check::new("app_running", CheckStatus::Ok, "Not running (no data yet).", None);
    }
    if running {
        return Check::new("app_running", CheckStatus::Ok, "Rallo is running.", None);
    }
    if unresolved_intents > 0 {
        Check::new(
            "app_running",
            CheckStatus::Warning,
            format!("Rallo is not running, and {unresolved_intents} reminder(s) are waiting for it."),
            Some("Open Rallo, or run `rallo show`.".to_owned()),
        )
    } else {
        Check::new("app_running", CheckStatus::Ok, "Rallo is not running.", None)
    }
}

/// `notifications`: the last authorization the app observed and its age.
fn check_notifications(inspection: Option<&StoreInspection>, now_ms: i64) -> Check {
    let Some(inspection) = inspection else {
        return Check::new("notifications", CheckStatus::Ok, "Not observed yet.", None);
    };
    let has_active_reminders = inspection.active_reminders > 0;
    let observed_at = inspection.notifications_authorization_observed_at_ms;
    let authorization = inspection.notifications_authorization.and_then(NotificationAuthorization::from_code);

    match (authorization, has_active_reminders) {
        (None, false) => Check::new("notifications", CheckStatus::Ok, "Not observed yet.", None),
        (None, true) => Check::new(
            "notifications",
            CheckStatus::Warning,
            "Not observed yet, and active reminders exist.",
            Some("Open Rallo's menu and choose Enable Notifications…".to_owned()),
        ),
        (Some(NotificationAuthorization::Denied), true) => Check::new(
            "notifications",
            CheckStatus::Warning,
            format!("Denied{}.", age_suffix(observed_at, now_ms)),
            Some("System Settings → Notifications → Rallo.".to_owned()),
        ),
        (Some(NotificationAuthorization::NotDetermined), true) => Check::new(
            "notifications",
            CheckStatus::Warning,
            format!("Not determined{}.", age_suffix(observed_at, now_ms)),
            Some("Open Rallo's menu and choose Enable Notifications…".to_owned()),
        ),
        (Some(authorization), _) => Check::new(
            "notifications",
            CheckStatus::Ok,
            format!("{}{}.", authorization.as_str(), age_suffix(observed_at, now_ms)),
            None,
        ),
    }
}

/// `reminders`: active count against the 32 limit, unresolved intent age, and
/// recent abandonment history.
fn check_reminders(inspection: Option<&StoreInspection>, running: bool, now_ms: i64) -> Check {
    let Some(inspection) = inspection else {
        return Check::new(
            "reminders",
            CheckStatus::Ok,
            format!("0/{MAX_ACTIVE_REMINDERS} active; no data yet."),
            None,
        );
    };

    let mut status = CheckStatus::Ok;
    let mut notes = vec![format!("{}/{MAX_ACTIVE_REMINDERS} active", inspection.active_reminders)];
    let mut fixes = Vec::new();

    if inspection.active_reminders >= CAPACITY_WARNING_THRESHOLD {
        status = CheckStatus::Warning;
        fixes.push("Complete, cancel, or delete some reminders before reaching the 32 limit.".to_owned());
    }

    let unresolved = inspection.intents.unresolved_count;
    if unresolved > 0 {
        let oldest_age_ms = inspection.intents.oldest_unresolved_created_at_ms.map(|at| now_ms - at);
        let age_note = oldest_age_ms.map(|age| format!(", oldest {}", format_age(age))).unwrap_or_default();
        notes.push(format!("{unresolved} unresolved{age_note}"));
        if running && oldest_age_ms.is_some_and(|age| age > STUCK_DRAIN_THRESHOLD_MS) {
            status = status.max(CheckStatus::Warning);
            fixes.push(
                "Reminders have been waiting longer than expected while Rallo is running; try `rallo show` or \
                 restart Rallo."
                    .to_owned(),
            );
        }
    }

    if inspection.intents.abandoned_last_7d_count > 0 {
        notes.push(format!("{} abandoned in the last 7 days", inspection.intents.abandoned_last_7d_count));
    }

    let fix = (!fixes.is_empty()).then(|| fixes.join("; "));
    Check::new("reminders", status, notes.join("; "), fix)
}

/// `backups`: count and newest file in `<data dir>/backups/`. Always `ok`;
/// none yet is fine.
fn check_backups(backups: &inspect::BackupsSummary, now_ms: i64) -> Check {
    if backups.count == 0 {
        return Check::new("backups", CheckStatus::Ok, "None yet.", None);
    }
    let newest = backups.newest_path.as_ref().map(|path| path.display().to_string()).unwrap_or_default();
    let age = backups.newest_modified_ms.map(|at| format!(" ({})", format_age(now_ms - at))).unwrap_or_default();
    Check::new(
        "backups",
        CheckStatus::Ok,
        format!("{} backup{}; newest {newest}{age}.", backups.count, if backups.count == 1 { "" } else { "s" }),
        None,
    )
}
