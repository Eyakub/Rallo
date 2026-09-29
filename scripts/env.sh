# Shared environment for Rallo build scripts. Source, don't execute.
# Xcode run-script phases start with a minimal PATH, so locate rustup explicitly.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
for candidate in "$HOME/.cargo/bin" /opt/homebrew/opt/rustup/bin /usr/local/opt/rustup/bin; do
  if [ -x "$candidate/cargo" ]; then
    export PATH="$candidate:$PATH"
    break
  fi
done
command -v cargo >/dev/null || { echo "error: cargo not found; install rustup" >&2; exit 1; }
export CARGO_TARGET_DIR="$REPO_ROOT/target"
