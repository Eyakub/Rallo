mod args;
mod commands;
mod output;

use std::process::ExitCode;

use clap::Parser;
use rallo_core::storage::paths;
use rallo_core::{Store, StoreOptions};

use args::{Cli, Command};
use output::Output;

fn main() -> ExitCode {
    // Ordinary Unix behaviour for `rallo list | head`: die quietly on SIGPIPE
    // instead of panicking on a failed write.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let cli = Cli::parse();
    let out = Output { json: cli.json };
    match run(cli, &out) {
        Ok(()) => ExitCode::SUCCESS,
        Err(failure) => out.failure(&failure),
    }
}

fn run(cli: Cli, out: &Output) -> commands::CommandResult {
    if cli.version {
        return commands::version(out);
    }
    let Some(command) = cli.command else {
        use clap::CommandFactory;
        // Help goes to stderr so `--json` stdout stays machine-readable.
        eprintln!("{}", Cli::command().render_help());
        return Err(output::Failure::new(output::Exit::InvalidInput, "INVALID_INPUT", "a command is required"));
    };
    let data_dir = paths::resolve_data_dir(cli.data_dir.as_deref())?;
    let mut store = Store::open(StoreOptions::new(data_dir))?;
    match command {
        Command::Note { text, stdin } => commands::note(out, &mut store, text, stdin),
        Command::List => commands::list(out, &store),
        Command::Show { reset_position } => commands::show(out, &mut store, reset_position),
        Command::Hide => commands::hide(out, &mut store),
        Command::Status => commands::status(out, &store),
    }
}
