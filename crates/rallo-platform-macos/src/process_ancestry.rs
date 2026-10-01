//! Which terminal app to bring forward for a waiting agent (0007), and which
//! agent process a hook belongs to (0009). Walks this process's ancestors via
//! `proc_pidinfo`/`proc_pidpath` (no `ps`, no subprocesses, so `rallo
//! agent-event` stays fast): to the first one running inside an `.app`
//! bundle, e.g. Terminal, iTerm2, cmux, or VS Code's Helper process; and to
//! the first one that isn't a shell, the agent itself.

use std::ffi::CStr;
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

/// The full form: only for this user's own processes, which an agent is.
fn bsd_info(pid: libc::pid_t) -> Option<libc::proc_bsdinfo> {
    let mut info: libc::proc_bsdinfo = unsafe { mem::zeroed() };
    let size = mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let written =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, &mut info as *mut _ as *mut libc::c_void, size) };
    if written == size { Some(info) } else { None }
}

fn started_us(info: &libc::proc_bsdinfo) -> i64 {
    info.pbi_start_tvsec as i64 * 1_000_000 + info.pbi_start_tvusec as i64
}

unsafe extern "C" {
    /// libSystem's `devname(3)`: "ttys003" for a terminal device number.
    fn devname(dev: libc::dev_t, kind: libc::mode_t) -> *const libc::c_char;
}

/// `/dev/ttysNNN` for a process's controlling terminal, if it has one.
fn controlling_tty(info: &libc::proc_bsdinfo) -> Option<String> {
    // `e_tdev` is NODEV (all ones) without a controlling terminal.
    if info.e_tdev == u32::MAX {
        return None;
    }
    let name = unsafe { devname(info.e_tdev as libc::dev_t, libc::S_IFCHR) };
    if name.is_null() {
        return None;
    }
    let name = unsafe { CStr::from_ptr(name) }.to_str().ok()?;
    let digits = name.strip_prefix("ttys")?;
    (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())).then(|| format!("/dev/{name}"))
}

/// The agent a hook ran for (0009): its pid and start time, which together
/// tell a live agent from a recycled pid, and its controlling terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentProcess {
    pub pid: u32,
    pub started_us: i64,
    pub tty: Option<String>,
}

const SHELLS: [&str; 8] = ["sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh"];

/// The nearest ancestor that is neither a shell nor Rallo's own CLI: hooks
/// run as `sh -c "…rallo agent-event…"` under Claude Code or Codex, so that
/// is the agent process. `None` past `MAX_STEPS` or at launchd.
pub fn agent_process() -> Option<AgentProcess> {
    let mut pid = std::process::id() as libc::pid_t;
    for _ in 0..MAX_STEPS {
        pid = parent_pid(pid)?;
        if pid <= 1 {
            return None;
        }
        let path = process_path(pid)?;
        let name = path.file_name()?.to_str()?;
        if SHELLS.contains(&name) || name == "rallo" {
            continue;
        }
        let info = bsd_info(pid)?;
        return Some(AgentProcess { pid: pid as u32, started_us: started_us(&info), tty: controlling_tty(&info) });
    }
    None
}

/// Whether the process `pid` still exists and is the one that started at
/// `started_us` (a recycled pid has another start time, or belongs to
/// another user and can't be inspected at all).
pub fn is_alive(pid: i64, started_us: i64) -> bool {
    libc::pid_t::try_from(pid).ok().and_then(bsd_info).is_some_and(|info| self::started_us(&info) == started_us)
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
    fn this_process_is_alive_only_with_its_own_start_time() {
        let pid = std::process::id();
        let info = bsd_info(pid as libc::pid_t).expect("our own process is inspectable");
        assert!(is_alive(pid.into(), started_us(&info)));
        assert!(!is_alive(pid.into(), started_us(&info) + 1), "a recycled pid has another start time");
        assert!(!is_alive(i64::from(i32::MAX), 0), "no such process");
    }

    #[test]
    fn the_agent_process_is_never_a_shell() {
        // Under `cargo test` the nearest non-shell ancestor is cargo or a
        // terminal; whichever it is, it must be alive and not a shell.
        if let Some(agent) = agent_process() {
            assert!(is_alive(agent.pid.into(), agent.started_us));
            let name = process_path(agent.pid as libc::pid_t).unwrap();
            assert!(!SHELLS.contains(&name.file_name().unwrap().to_str().unwrap()));
            if let Some(tty) = agent.tty {
                assert!(tty.starts_with("/dev/ttys"), "{tty}");
            }
        }
    }

    #[test]
    fn this_process_has_some_ancestor_reachable_within_the_step_limit() {
        // Not asserting a specific result (test harnesses vary), just that
        // walking real ancestry via libc never panics or hangs.
        let _ = terminal_app();
    }
}
