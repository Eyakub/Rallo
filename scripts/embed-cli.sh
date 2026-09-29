#!/usr/bin/env bash
# Xcode post-build phase: embeds the matching rallo CLI at
# Rallo.app/Contents/Helpers/rallo and signs it before Xcode signs the app.
set -euo pipefail
source "$(dirname "$0")/env.sh"

helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helpers"
cp "$CARGO_TARGET_DIR/release/rallo" "$helpers/rallo"
codesign --force --options runtime --timestamp=none \
  --identifier com.razlio.rallo.cli \
  --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helpers/rallo"
