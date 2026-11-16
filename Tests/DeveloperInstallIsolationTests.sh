#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

set -euo pipefail
cd "$(dirname "$0")/.."
install_test_dir=$(mktemp -d)
trap 'command rm -rf "$install_test_dir"' EXIT

# Run the real installation block against disposable bundles. No process is
# stopped and no app under /Applications is read, removed or installed.
sed -n '/^if (( INSTALL )); then$/,$p' build.sh \
    | sed 's|/Applications|$install_test_dir/Applications|g' > "$install_test_dir/install.zsh"
[[ -s "$install_test_dir/install.zsh" ]]
mkdir -p "$install_test_dir/Applications" "$install_test_dir/stage"
print new > "$install_test_dir/stage/content"
INSTALL=1
STAGE="$install_test_dir/stage"
stopped=()
signed=()
stop_process() { stopped+=("$1"); }
sign_installed_bundle() { signed+=("$1"); }

for DEV in 1 0; do
    stopped=()
    signed=()
    # This variant's APP_NAME and EXECUTABLE, from the one file that names
    # them. Only that app is stopped and replaced; the other Brim variant and
    # every upstream app (Vorssaint, its Developer build and its pre-rename
    # names) are never touched.
    source Tools/identity.sh
    others=()
    for name in "$BRIM_RELEASE_APP_NAME" "$BRIM_DEVELOPER_APP_NAME" \
            Vorss 'Vorssaint Utils' Vorssaint 'Vorssaint (Developer)'; do
        mkdir -p "$install_test_dir/Applications/$name.app"
        print original > "$install_test_dir/Applications/$name.app/content"
        [[ "$name" == "$APP_NAME" ]] || others+=("$name")
    done
    (( ${#others} == 5 ))
    # An app that only shares the name is refused before anything is
    # stopped or removed; this variant's own (its bundle ID) is replaced.
    own_plist="$install_test_dir/Applications/$APP_NAME.app/Contents/Info.plist"
    mkdir -p "${own_plist:h}"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.foreign" "$own_plist" >/dev/null
    if ( source "$install_test_dir/install.zsh" ) 2>/dev/null; then
        print -u2 "an app with another bundle ID was replaced"
        exit 1
    fi
    [[ "$(cat "$install_test_dir/Applications/$APP_NAME.app/content")" == original ]]
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$own_plist" >/dev/null
    source "$install_test_dir/install.zsh"
    [[ "$(cat "$install_test_dir/Applications/$APP_NAME.app/content")" == new ]]
    [[ "${signed[*]}" == "$install_test_dir/Applications/$APP_NAME.app" ]]
    [[ "${stopped[*]}" == "$EXECUTABLE" ]]
    for name in "${others[@]}"; do
        [[ "$(cat "$install_test_dir/Applications/$name.app/content")" == original ]]
    done
done
print 'DEVELOPER INSTALL ISOLATION TESTS OK'
