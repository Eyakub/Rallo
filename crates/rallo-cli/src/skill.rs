//! The agent skill (`skills/rallo/SKILL.md`), embedded so it always matches
//! this CLI's version, and its place in `~/.claude/skills`: Claude Code's
//! personal skills directory, which Cursor also reads.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub const SKILL: &str = include_str!("../../../skills/rallo/SKILL.md");

pub enum State {
    Missing,
    Current,
    /// Rallo's skill (`name: rallo`), but not this version's text.
    Outdated,
    /// Something else occupies the path.
    Foreign,
}

pub fn path(home: &Path) -> PathBuf {
    home.join(".claude/skills/rallo/SKILL.md")
}

pub fn inspect(home: &Path) -> State {
    let path = path(home);
    match fs::read_to_string(&path) {
        Ok(text) if text == SKILL => State::Current,
        Ok(text) if text.lines().any(|line| line.trim() == "name: rallo") => State::Outdated,
        Err(error) if error.kind() == io::ErrorKind::NotFound => State::Missing,
        _ => State::Foreign,
    }
}

/// Writes through a temporary file and a rename, so an agent never reads a
/// half-written skill.
pub fn install(home: &Path) -> io::Result<PathBuf> {
    let path = path(home);
    let dir = path.parent().expect("skill path has a parent");
    fs::create_dir_all(dir)?;
    let temporary = dir.join(".SKILL.md.tmp");
    fs::write(&temporary, SKILL)?;
    fs::rename(&temporary, &path)?;
    Ok(path)
}
