#!/usr/bin/env bash
# Builds whisper.cpp as static libraries (0014) into build/whisper/<version>/.
# Static on purpose: a dynamic framework fails library validation under
# Rallo's self-signed hardened runtime. Invoked by the Xcode pre-build phase.
set -euo pipefail
source "$(dirname "$0")/env.sh"

VERSION=1.9.4
SHA256=57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae
URL="https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${VERSION}.tar.gz"
WORK="$REPO_ROOT/build/whisper"
PREFIX="$WORK/v${VERSION}"

if [ -f "$PREFIX/lib/libwhisper.a" ] && [ -f "$PREFIX/include/module.modulemap" ]; then
  exit 0
fi

# Xcode run-script phases start with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v cmake >/dev/null || { echo "error: cmake not found (brew install cmake)" >&2; exit 1; }

mkdir -p "$WORK"
tarball="$WORK/whisper.cpp-${VERSION}.tar.gz"
if [ ! -f "$tarball" ]; then
  curl -fsSL "$URL" -o "$tarball.part"
  mv "$tarball.part" "$tarball"
fi
actual="$(shasum -a 256 "$tarball" | awk '{print $1}')"
if [ "$actual" != "$SHA256" ]; then
  rm -f "$tarball"
  echo "error: whisper.cpp ${VERSION} tarball hash mismatch (got ${actual}, want ${SHA256})" >&2
  exit 1
fi

src="$WORK/whisper.cpp-${VERSION}"
rm -rf "$src" "$WORK/cmake-build"
tar -xzf "$tarball" -C "$WORK"

cmake -S "$src" -B "$WORK/cmake-build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_NATIVE=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
cmake --build "$WORK/cmake-build" -j 8 >/dev/null
rm -rf "$PREFIX"
cmake --install "$WORK/cmake-build" --prefix "$PREFIX" >/dev/null

printf 'module whisper {\n  header "whisper.h"\n  export *\n}\n' > "$PREFIX/include/module.modulemap"
rm -rf "$src" "$WORK/cmake-build"
echo "built whisper.cpp ${VERSION}"
