mod agent_event;
mod args;
mod commands;
mod doctor;
mod hooks;
mod local_time;
mod output;
mod skill;
mod uninstall;
mod update;

use std::process::ExitCode;

use clap::Parser;
use rallo_core::items::MutationOptions;
use rallo_core::reminders::{TimeSpec, phrase};
use rallo_core::shared::clock::{Clock, SystemClock};
use rallo_core::storage::paths;
use rallo_core::{Store, StoreOptions};

use args::{Cli, Command, SetupCommand};
use output::{Failure, Output};

fn main() -> ExitCode {
    // Ordinary Unix behaviour for `rallo list | head`: die quietly on SIGPIPE
    // instead of panicking on a failed write.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let cli = Cli::parse();
    let out = Output { json: cli.json };
    match run(cli, &out) {
        Ok(exit) => exit,
        Err(failure) => out.failure(&failure),
    }
}

/// Exactly one of `--in`/`--at` is required by clap for every caller. `--at`
/// takes RFC 3339 or a plain-language phrase (0016), resolved against this
/// Mac's local time zone.
fn time_spec(in_: Option<String>, at: Option<String>) -> Result<TimeSpec, Failure> {
    match (in_, at) {
        (Some(in_), None) => Ok(TimeSpec::In(in_)),
        (None, Some(at)) => Ok(phrase::time_spec(
            &at,
            SystemClock.now_ms(),
            rallo_platform_macos::local_time::wall_clock,
            rallo_platform_macos::local_time::instant,
        )?),
        _ => unreachable!("clap enforces exactly one of --in/--at"),
    }
}

fn run(cli: Cli, out: &Output) -> Result<ExitCode, Failure> {
    if cli.version {
        return commands::version(out).map(|()| ExitCode::SUCCESS);
    }
    let Some(command) = cli.command else {
        use clap::CommandFactory;
        // Help goes to stderr so `--json` stdout stays machine-readable.
        eprintln!("{}", Cli::command().render_help());
        return Err(output::Failure::new(output::Exit::InvalidInput, "INVALID_INPUT", "a command is required"));
    };
    // No data directory: these manage files outside the notes store.
    if let Command::Setup { command: setup_command } = command {
        return match setup_command {
            SetupCommand::Terminal => commands::setup_terminal(out),
            SetupCommand::Skill { print, agents } => commands::setup_skill(out, print, agents),
            SetupCommand::Hooks { agents, remove, print } => hooks::run(out, agents, remove, print),
        }
        .map(|()| ExitCode::SUCCESS);
    }
    // Read-only and never migrates: must not go through `Store::open`.
    if let Command::Doctor = command {
        return doctor::run(out, cli.data_dir.as_deref());
    }
    // Manages its own conditional store open (skipped with no data yet) and
    // resolves the data directory itself, like `Doctor` above.
    if let Command::Update { check } = command {
        return update::run(out, cli.data_dir.as_deref(), check).map(|()| ExitCode::SUCCESS);
    }
    if let Command::Uninstall { purge, yes } = command {
        return uninstall::run(out, cli.data_dir.as_deref(), purge, yes).map(|()| ExitCode::SUCCESS);
    }
    // Never fails, never blocks, never writes to stdout (0007): reports its
    // own store-open/record errors to stderr rather than through `Failure`.
    if let Command::AgentEvent { agent } = command {
        agent_event::run(cli.data_dir.as_deref(), agent);
        return Ok(ExitCode::SUCCESS);
    }
    let data_dir = paths::resolve_data_dir(cli.data_dir.as_deref())?;
    let mut store = Store::open(StoreOptions::new(data_dir))?;
    let result: commands::CommandResult = match command {
        Command::Note { text, stdin, images, request_id } => {
            commands::note(out, &mut store, text, stdin, images, request_id)
        }
        Command::Remind { text, stdin, images, in_, at, request_id } => {
            commands::remind(out, &mut store, text, stdin, images, time_spec(in_, at)?, request_id)
        }
        Command::List { all, deleted, due, limit, cursor } => {
            commands::list(out, &store, all, deleted, due, limit, cursor)
        }
        Command::Get { id } => commands::get(out, &store, &id),
        Command::Search { text, exact, include_deleted, limit, cursor } => {
            commands::search(out, &store, text, exact, include_deleted, limit, cursor)
        }
        Command::Edit { id, text, request_id, if_revision } => {
            commands::edit(out, &mut store, &id, &text, MutationOptions { request_id, if_revision })
        }
        Command::Attach { id, paths, request_id, if_revision } => {
            commands::attach(out, &mut store, &id, &paths, MutationOptions { request_id, if_revision })
        }
        Command::Detach { id, image_id, request_id, if_revision } => {
            commands::detach(out, &mut store, &id, &image_id, MutationOptions { request_id, if_revision })
        }
        Command::Done { id, request_id, if_revision } => {
            commands::done(out, &mut store, &id, MutationOptions { request_id, if_revision })
        }
        Command::Reopen { id, request_id, if_revision } => {
            commands::reopen(out, &mut store, &id, MutationOptions { request_id, if_revision })
        }
        Command::Restore { id, request_id, if_revision } => {
            commands::restore(out, &mut store, &id, MutationOptions { request_id, if_revision })
        }
        Command::Reschedule { id, in_, at, request_id, if_revision } => {
            commands::reschedule(out, &mut store, &id, time_spec(in_, at)?, MutationOptions { request_id, if_revision })
        }
        Command::Snooze { id, duration, request_id, if_revision } => {
            commands::snooze(out, &mut store, &id, &duration, MutationOptions { request_id, if_revision })
        }
        Command::Acknowledge { id, request_id, if_revision } => {
            commands::acknowledge(out, &mut store, &id, MutationOptions { request_id, if_revision })
        }
        Command::CancelReminder { id, request_id, if_revision } => {
            commands::cancel_reminder(out, &mut store, &id, MutationOptions { request_id, if_revision })
        }
        Command::Delete { id, text, request_id, if_revision } => {
            commands::delete(out, &mut store, id, text, MutationOptions { request_id, if_revision })
        }
        Command::Show { reset_position } => commands::show(out, &mut store, reset_position),
        Command::Hide => commands::hide(out, &mut store),
        Command::Status { id } => commands::status(out, &store, id),
        Command::Export { output, format, force } => commands::export(out, &store, &output, format, force),
        Command::Import { file, dry_run } => commands::import(out, &mut store, &file, dry_run),
        Command::Backup { output, force } => commands::backup(out, &store, output.as_deref(), force),
        Command::Agents { command: agents_command } => match agents_command {
            None => commands::agents_list(out, &mut store),
            Some(args::AgentsCommand::Clear { agent, session }) => {
                commands::agents_clear(out, &mut store, agent, session)
            }
        },
        Command::Setup { .. }
        | Command::Doctor
        | Command::Update { .. }
        | Command::Uninstall { .. }
        | Command::AgentEvent { .. } => {
            unreachable!("handled before the store was opened")
        }
    };
    result.map(|()| ExitCode::SUCCESS)
}
