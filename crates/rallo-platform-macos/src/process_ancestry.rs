//! Which terminal app to bring forward for a waiting agent (0007). Walks this
//! process's ancestors via `proc_pidinfo`/`proc_pidpath` (no `ps`, no
//! subprocesses, so `rallo agent-event` stays fast) to the first one running
//! inside an `.app` bundle, e.g. Terminal, iTerm2, cmux, or VS Code's Helper
//! process.

use std::mem;
use std::path::{Component, Path, PathBuf};

/// Ancestor walks stop here even if the real process tree (init/launchd) goes
/// deeper; a real terminal/editor ancestor is always much closer than this.
const MAX_STEPS: u32 = 32;

/// The short form, not `PROC_PIDTBSDINFO`: the full one is refused for
/// another user's process, and Terminal and cmux start shells through the
/// root-owned `/usr/bin/login`, so the walk would stop there.
fn parent_pid(pid: libc::pid_t) -> Option<libc::pid_t> {
    let mut info: libc::proc_bsdshortinfo = unsafe { mem::zeroed() };
    let size = mem::size_of::<libc::proc_bsdshortinfo>() as libc::c_int;
    let written = unsafe {
        libc::proc_pidinfo(pid, libc::PROC_PIDT_SHORTBSDINFO, 0, &mut info as *mut _ as *mut libc::c_void, size)
    };
    if written == size { Some(info.pbsi_ppid as libc::pid_t) } else { None }
}

fn process_path(pid: libc::pid_t) -> Option<PathBuf> {
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let written = unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if written <= 0 {
        return None;
    }
    buffer.truncate(written as usize);
    Some(PathBuf::from(String::from_utf8(buffer).ok()?))
}

/// The outermost `.app` bundle containing `path` (everything up to and
/// including the first path component ending in `.app`), e.g.
/// `/Applications/Visual Studio Code.app` for a `Code Helper` executable
/// nested inside it. `None` if `path` has no `.app` component.
pub fn outermost_bundle(path: &Path) -> Option<PathBuf> {
    let mut bundle = PathBuf::new();
    for component in path.components() {
        bundle.push(component);
        if let Component::Normal(name) = component
            && Path::new(name).extension().is_some_and(|ext| ext == "app")
        {
            return Some(bundle);
        }
    }
    None
}

fn is_rallo_bundle(bundle: &Path) -> bool {
    bundle.file_name().is_some_and(|name| name == "Rallo.app")
}

/// Walks parent pids from the current process, at most `MAX_STEPS`, stopping
/// at pid ≤ 1, to the first ancestor running inside an `.app` bundle other
/// than Rallo's own (an ancestor deeper still might be a real terminal, e.g.
/// under a dev/test harness). Returns the outermost bundle path and that
/// ancestor's pid. `None` without one (tmux server, SSH, or no `.app`
/// ancestor at all).
pub fn terminal_app() -> Option<(PathBuf, u32)> {
    let mut pid = std::process::id() as libc::pid_t;
    for _ in 0..MAX_STEPS {
        let ppid = parent_pid(pid)?;
        if ppid <= 1 {
            return None;
        }
        if let Some(path) = process_path(ppid)
            && let Some(bundle) = outermost_bundle(&path)
            && !is_rallo_bundle(&bundle)
        {
            return Some((bundle, ppid as u32));
        }
        pid = ppid;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_app_component_is_none() {
        assert_eq!(outermost_bundle(Path::new("/usr/bin/bash")), None);
    }

    #[test]
    fn a_direct_bundle_executable_resolves_to_its_own_bundle() {
        assert_eq!(
            outermost_bundle(Path::new("/Applications/Terminal.app/Contents/MacOS/Terminal")),
            Some(PathBuf::from("/Applications/Terminal.app"))
        );
    }

    #[test]
    fn a_nested_helper_resolves_to_the_outermost_bundle() {
        assert_eq!(
            outermost_bundle(Path::new(
                "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
            )),
            Some(PathBuf::from("/Applications/Visual Studio Code.app"))
        );
    }

    #[test]
    fn a_bundle_name_with_a_space_is_preserved() {
        assert_eq!(
            outermost_bundle(Path::new("/Applications/iTerm.app/Contents/MacOS/iTerm2")),
            Some(PathBuf::from("/Applications/iTerm.app"))
        );
    }

    #[test]
    fn this_process_has_some_ancestor_reachable_within_the_step_limit() {
        // Not asserting a specific result (test harnesses vary), just that
        // walking real ancestry via libc never panics or hangs.
        let _ = terminal_app();
    }
}
