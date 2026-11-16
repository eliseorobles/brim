#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
# Copyright (C) 2026 Robles Consulting LLC

# Builds Brim, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications. --test builds and runs the tests instead.
#
#   identity  Tools/identity.sh names both variants; brim_finish_identity
#             stamps and checks the staged bundle.
#   signing   one identity, chosen explicitly (brim_resolve_signing_identity),
#             with the hardened runtime and the app's entitlements on every build.
#   jobs      BRIM_JOBS caps swiftc's parallel jobs (default 6).
#   install   only this variant's app in /Applications is stopped, replaced and,
#             when it was running, relaunched.
#   claude    brim_add_claude_helper compiles brim-claude (the Claude accounts
#             helper), runs its selftest and stages it in Contents/Helpers with
#             the zsh integration in Contents/Resources; codesign_app signs it
#             before the app.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# The icon catalog and the bundle are staged in temp dirs; sweep both however
# the script ends.
ICON_TMP=""
STAGE_TMP=""

cleanup() {
    [[ -n "$ICON_TMP" ]] && rm -rf "$ICON_TMP"
    [[ -n "$STAGE_TMP" ]] && rm -rf "$STAGE_TMP"
    return 0
}
trap cleanup EXIT
# zsh runs the EXIT trap when the script is hung up, but not when it is
# interrupted or terminated; route those through exit so a Ctrl-C partway
# into the build sweeps like any other ending.
trap 'exit 1' INT TERM HUP

# Flags: --dev builds the local-only "Brim (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
        --test-suite=*) TEST=1; TEST_ARGS+=("--suite=${arg#*=}") ;;
        --list-tests) TEST=1; TEST_ARGS+=(--list) ;;
    esac
done

if (( DEV )); then
    BUILD_VARIANT_FLAGS=(-D BRIM_DEVELOPMENT)
    APP_OPTIMIZATION_FLAGS=(-Onone)
    BUILD_CONFIGURATION="debug"
else
    BUILD_VARIANT_FLAGS=()
    APP_OPTIMIZATION_FLAGS=(-O)
    BUILD_CONFIGURATION="release"
fi
# APP_NAME, EXECUTABLE, APP_BUNDLE_ID and FAN_HELPER_ID of the variant DEV picks.
source Tools/identity.sh
TARGET="arm64-apple-macosx14.0"
ENTITLEMENTS="Resources/Brim.entitlements"

# --------------------------------------------------------------------------
# Jobs. Every swiftc job is a compiler process holding its own copy of the
# module, and parallel compiles have run this Mac out of memory before, so the
# cap is a fixed, modest number rather than every core.
BRIM_JOBS="${BRIM_JOBS:-6}"
if [[ "$BRIM_JOBS" != <1-> ]]; then
    echo "✗ BRIM_JOBS must be a whole number of at least 1 (it is '$BRIM_JOBS')" >&2
    exit 1
fi

codesign_with_timestamp_retry() {
    local attempt
    for attempt in 1 2 3; do
        if /usr/bin/codesign "$@"; then
            return 0
        fi
        if (( attempt < 3 )); then
            echo "  Developer ID signing failed; retrying ($((attempt + 1))/3)"
            sleep "$attempt"
        fi
    done
    return 1
}

# --------------------------------------------------------------------------
# Signing. A stable signature keeps macOS's privacy grants (Accessibility,
# Screen Recording) across rebuilds, and the fan helper and the app accept each
# other only when both carry Brim's team. So every build is signed by one
# identity, chosen explicitly:
#   1. BRIM_SIGN_IDENTITY, when set: a certificate's SHA-1 or its full name, or
#      "-" for an ad-hoc signature (CI, which has no certificate).
#   2. Otherwise the first valid code-signing identity whose certificate
#      belongs to team $BRIM_TEAM_ID, a "Developer ID Application" one before
#      an "Apple Development" one.
# There is no fallback: with neither, the build stops and says what to install.
# Nothing here creates a keychain or changes the keychain search list.
BRIM_TEAM_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$BRIM_TEAM_ID\""
BRIM_SIGNING_IDENTITY=""     # the certificate's SHA-1, or "-" for ad-hoc
BRIM_SIGNING_LABEL=""
BRIM_SIGNING_TIMESTAMP=0     # 1 for Developer ID: a secure timestamp from Apple
BRIM_SIGNING_IN_TEAM=0       # 1 when the identity carries $BRIM_TEAM_ID

# "<SHA-1><TAB><name>" for each valid code-signing identity, in listing order.
brim_valid_identities() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "(.*)"$/\1	\2/p'
}

# The subject of the certificate with this SHA-1, as RFC 2253 (C=..,O=..,OU=..).
brim_certificate_subject() {
    security find-certificate -a -Z -p 2>/dev/null \
        | awk -v hash="$1" '
            /^SHA-1 hash:/ { mine = ($3 == hash) }
            mine && /-----BEGIN CERTIFICATE-----/ { pem = 1 }
            pem { print }
            pem && /-----END CERTIFICATE-----/ { exit }' \
        | /usr/bin/openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -E 's/^subject= ?//'
}

brim_in_team() {
    [[ ",$(brim_certificate_subject "$1")," == *",OU=$BRIM_TEAM_ID,"* ]]
}

brim_use_identity() {
    local hash="$1" name="$2"
    BRIM_SIGNING_IDENTITY="$hash"
    BRIM_SIGNING_LABEL="$name ($hash)"
    BRIM_SIGNING_TIMESTAMP=0
    [[ "$name" == "Developer ID Application:"* ]] && BRIM_SIGNING_TIMESTAMP=1
    BRIM_SIGNING_IN_TEAM=0
    brim_in_team "$hash" && BRIM_SIGNING_IN_TEAM=1
    return 0
}

brim_resolve_signing_identity() {
    local identities line hash name kind
    local -a matches
    identities="$(brim_valid_identities)"
    if [[ -n "${BRIM_SIGN_IDENTITY:-}" ]]; then
        if [[ "$BRIM_SIGN_IDENTITY" == "-" ]]; then
            BRIM_SIGNING_IDENTITY="-"
            BRIM_SIGNING_LABEL="ad-hoc, as BRIM_SIGN_IDENTITY asks"
            return 0
        fi
        for line in "${(@f)identities}"; do
            [[ -n "$line" ]] || continue
            hash="${line%%	*}"; name="${line#*	}"
            if [[ "$hash" == "${(U)BRIM_SIGN_IDENTITY}" || "$name" == "$BRIM_SIGN_IDENTITY" ]]; then
                matches+=("$line")
            fi
        done
        if (( ${#matches} != 1 )); then
            echo "✗ BRIM_SIGN_IDENTITY='$BRIM_SIGN_IDENTITY' names ${#matches} valid code-signing identities; it must name exactly one." >&2
            echo "  Use the SHA-1 from: security find-identity -v -p codesigning" >&2
            return 1
        fi
        brim_use_identity "${matches[1]%%	*}" "${matches[1]#*	}"
        if (( ! BRIM_SIGNING_IN_TEAM )); then
            echo "  ⚠ $BRIM_SIGNING_LABEL is not in team $BRIM_TEAM_ID: a release build's fan helper will refuse it." >&2
        fi
        return 0
    fi
    for kind in "Developer ID Application" "Apple Development"; do
        for line in "${(@f)identities}"; do
            [[ -n "$line" ]] || continue
            hash="${line%%	*}"; name="${line#*	}"
            [[ "$name" == "$kind:"* ]] || continue
            if brim_in_team "$hash"; then
                brim_use_identity "$hash" "$name"
                return 0
            fi
        done
    done
    {
        echo "✗ No code-signing identity for $BRIM_TEAM_NAME (team $BRIM_TEAM_ID) is installed."
        echo "  Brim signs every build with its team's certificate, so macOS keeps privacy"
        echo "  grants across rebuilds and the fan helper accepts the app. Install an"
        echo "  \"Apple Development\" or \"Developer ID Application\" certificate for the team"
        echo "  (Xcode › Settings › Accounts › Manage Certificates), or name one with"
        echo "  BRIM_SIGN_IDENTITY=<SHA-1 or full name>."
        if [[ -n "$identities" ]]; then
            echo "  Valid identities found, none of them in the team:"
            for line in "${(@f)identities}"; do echo "    ${line#*	}"; done
        else
            echo "  No valid code-signing identity was found at all."
        fi
    } >&2
    return 1
}

# Signs one item with the chosen identity, the hardened runtime and whatever
# else the caller passes (entitlements, an identifier). A team signature is
# then checked against the very requirement the fan helper link enforces.
brim_codesign() {
    local target="$1"
    shift
    local -a args=(--force --strip-disallowed-xattrs --options runtime "$@")
    if [[ "$BRIM_SIGNING_IDENTITY" == "-" ]]; then
        /usr/bin/codesign "${args[@]}" --sign - "$target" || return 1
        return 0
    fi
    if [[ -z "$BRIM_SIGNING_IDENTITY" ]]; then
        echo "✗ No signing identity was resolved" >&2
        return 1
    fi
    if (( BRIM_SIGNING_TIMESTAMP )); then
        codesign_with_timestamp_retry "${args[@]}" --timestamp \
            --sign "$BRIM_SIGNING_IDENTITY" "$target" || return 1
    else
        # A development certificate is never notarized; a timestamp would only
        # add a network round trip to every signature.
        /usr/bin/codesign "${args[@]}" --timestamp=none \
            --sign "$BRIM_SIGNING_IDENTITY" "$target" || return 1
    fi
    if (( BRIM_SIGNING_IN_TEAM )); then
        /usr/bin/codesign --verify --strict -R="$BRIM_TEAM_REQUIREMENT" "$target" || {
            echo "✗ $target does not satisfy: $BRIM_TEAM_REQUIREMENT" >&2
            return 1
        }
    fi
}

# The app bundle. Its Claude accounts helper is Brim's own nested code, so it
# is signed here, inside first, every time the app is: sign_bundle and
# finalize_installed_bundle_after_child sign the app with this function only
# after its other helpers.
codesign_app() {
    local claude_helper="$1/Contents/Helpers/$BRIM_CLAUDE_HELPER"
    if [[ -f "$claude_helper" ]]; then
        codesign_claude_helper "$claude_helper" || return 1
        /usr/bin/codesign --verify --strict "$claude_helper" || return 1
    fi
    brim_codesign "$1" --entitlements "$ENTITLEMENTS"
}

codesign_claude_helper() {
    brim_codesign "$1" --identifier "$BRIM_CLAUDE_HELPER_ID"
}

codesign_fan_helper() {
    brim_codesign "$1" --identifier "$FAN_HELPER_ID"
}

if (( ! TEST )); then
    brim_resolve_signing_identity || exit 1
fi

# --------------------------------------------------------------------------
# Identity of the staged bundle. The bundle and the fan helper's launchd plist
# are rewritten for the variant being built; this stamps the copyright and then
# checks the result against Tools/identity.sh.
brim_finish_identity() {
    local info="$1/Contents/Info.plist"
    local fan="$1/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    local key expected actual mentions
    /usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright '$BRIM_COPYRIGHT'" "$info"
    for key expected in \
        CFBundleIdentifier "$APP_BUNDLE_ID" \
        CFBundleExecutable "$EXECUTABLE" \
        CFBundleName "$APP_NAME" \
        CFBundleDisplayName "$APP_NAME" \
        NSHumanReadableCopyright "$BRIM_COPYRIGHT"; do
        actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$info" 2>/dev/null)"
        if [[ "$actual" != "$expected" ]]; then
            echo "✗ Info.plist $key is '$actual', expected '$expected'" >&2
            return 1
        fi
    done
    # Label, BundleProgram and the one MachServices key, and nothing else.
    mentions="$(grep -o -F "$FAN_HELPER_ID" "$fan" | wc -l | tr -d ' ')"
    if [[ "$mentions" != 3 \
          || "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$fan")" != "$FAN_HELPER_ID" \
          || "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$FAN_HELPER_ID" "$fan")" != true \
          || "$(/usr/libexec/PlistBuddy -c 'Print :MachServices' "$fan" | grep -c ' = ')" != 1 ]]; then
        echo "✗ the fan helper's launchd plist does not name $FAN_HELPER_ID where launchd reads it" >&2
        return 1
    fi
}

# --------------------------------------------------------------------------
# Install. Only the copy in /Applications of the variant being built is ever
# stopped or replaced, found by brim_app_pids (Tools/identity.sh) by its full
# executable path; no other app, and no process merely sharing its name.
BRIM_APP_WAS_RUNNING=0
brim_note_running_app() {
    BRIM_APP_WAS_RUNNING=0
    [[ -n "$(brim_app_pids)" ]] && BRIM_APP_WAS_RUNNING=1
    return 0
}

brim_relaunch_app() {
    if (( BRIM_APP_WAS_RUNNING )); then
        echo "▸ Relaunching $APP_NAME…"
        /usr/bin/open "/Applications/$APP_NAME.app"
    fi
}

# --------------------------------------------------------------------------
# Claude accounts helper. brim-claude runs as Claude Code's status line in
# every session and behind the zsh integration (pick, move), so it is a small
# Foundation-only binary, built from the pure files the app compiles too
# (Sources/Brim/Modules/ClaudeAccounts) and Sources/BrimClaude/main.swift. It
# opens no Keychain item.
# It is staged in Contents/Helpers and signed by codesign_app, inside first;
# the zsh integration goes in Contents/Resources. Only the app's "Install
# shell integration" puts either anywhere else, never the build.
BRIM_CLAUDE_HELPER="brim-claude"
BRIM_CLAUDE_HELPER_ID="$APP_BUNDLE_ID.claude-helper"
BRIM_CLAUDE_SHELL="Resources/claude.zsh"

brim_add_claude_helper() {
    local bundle="$1"
    echo "▸ Compiling Claude accounts helper ($BRIM_CLAUDE_HELPER)…"
    # The variant flag picks its state folder (~/.config/brim or brim-dev),
    # the same one the app it ships in uses.
    swiftc -O -whole-module-optimization -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        "${BUILD_VARIANT_FLAGS[@]}" -module-name BrimClaude \
        Sources/Brim/Modules/ClaudeAccounts/*.swift Sources/BrimClaude/main.swift \
        -o "build/$BRIM_CLAUDE_HELPER" || return 1
    "build/$BRIM_CLAUDE_HELPER" --selftest || return 1
    mkdir -p "$bundle/Contents/Helpers" "$bundle/Contents/Resources"
    cp "build/$BRIM_CLAUDE_HELPER" "$bundle/Contents/Helpers/$BRIM_CLAUDE_HELPER"
    cp "$BRIM_CLAUDE_SHELL" "$bundle/Contents/Resources/$BRIM_CLAUDE_HELPER.zsh"
}

write_swift_output_file_map() {
    local output_file="$1"
    local object_dir="$2"
    shift 2
    local source artifact

    {
        print -r -- "{"
        print -r -- "  \"\": {"
        print -r -- "    \"swift-dependencies\": \"$object_dir/master.swiftdeps\""
        print -r -- "  }"
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            print -r -- ","
            print -r -- "  \"$source\": {"
            print -r -- "    \"object\": \"$object_dir/$artifact.o\","
            print -r -- "    \"swift-dependencies\": \"$object_dir/$artifact.swiftdeps\""
            print -r -- "  }"
        done
        print -r -- "}"
    } > "$output_file"
}

finalize_installed_bundle_after_child() {
    local bundle="$1"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"

    echo "▸ Finalizing installed signature…"
    sleep 3
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    codesign_app "$bundle"
    [[ -f "$helper" ]] && /usr/bin/codesign --verify --strict "$helper"
    /usr/bin/codesign --verify --deep --strict "$bundle"
    echo "✓ Signature ready: $bundle"
}

if (( INSTALL && ! TEST )) && [[ "${BRIM_INSTALL_CHILD:-0}" != "1" ]]; then
    brim_note_running_app
    BRIM_INSTALL_CHILD=1 "$0" "$@"
    child_status=$?
    if (( child_status != 0 )); then
        exit "$child_status"
    fi
    finalize_installed_bundle_after_child "/Applications/$APP_NAME.app"
    brim_relaunch_app
    exit 0
fi

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
VM_STATISTICS_COMPAT_FLAGS=(-I Sources/VMStatisticsCompat)
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    # Swift 6.4 can read the SDK 26 interfaces when given their compiler version.
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# The defaults migrations under test need a real UserDefaults suite, and every
# suite leaves an empty plist in ~/Library/Preferences. The tests already clear
# the domains, but cfprefsd writes the emptied file back out around the time the
# process that owned it exits, so only a caller that outlives the run can remove
# them. `PreferenceNamespaceTests` scans every compiled Swift test file against
# these namespaces, which keeps this sweep complete without a second list.
discard_test_preferences() {
    local preferences="${1:-$HOME/Library/Preferences}" attempt
    local namespace="brim.tests."
    local survivors=0 quiet_passes=0
    # cfprefsd can recreate an emptied domain after the first removal. Require
    # two quiet checks, but keep a hard limit so persistent failures still fail CI.
    for attempt in {1..10}; do
        rm -f "$preferences"/$namespace*.plist(N)
        rm -f "$preferences/metrics-tests.plist"
        sleep 0.2
        survivors=$(find "$preferences" -maxdepth 1 \
            \( -name "$namespace*.plist" -o -name "metrics-tests.plist" \) 2>/dev/null \
            | wc -l | tr -d ' ')
        if [[ "$survivors" == "0" ]]; then
            quiet_passes=$((quiet_passes + 1))
            if (( quiet_passes == 2 )); then return 0; fi
        else
            quiet_passes=0
        fi
    done
    echo "✗ test preferences did not settle in $preferences ($survivors remaining)" >&2
    return 1
}

# Standalone automated tests: pure contracts plus isolated disk, subprocess
# and keyboard-data fixtures. No application windows or device capture.
if (( TEST )); then
    python3 Tests/generate_sources.py
    TEST_OBJECT_DIR="build/objects/tests"
    mkdir -p "$TEST_OBJECT_DIR"
    TEST_SOURCES=(
        Sources/Brim/Core/BrimIdentity.swift
        Sources/Brim/Modules/ClaudeAccounts/*.swift
        Sources/Brim/Modules/ClaudeAccounts/App/ClaudeAccountsStrings.swift
        Sources/Brim/Modules/ClaudeAccounts/App/ClaudeAccountsAppSupport.swift
        Sources/Brim/Modules/ClaudeAccounts/App/ClaudeSignInRun.swift
        Sources/Brim/Modules/ClaudeAccounts/App/ClaudeMCPGit.swift
        Sources/Brim/Modules/ClaudeAccounts/App/ClaudeMCPRun.swift
        Sources/Brim/Modules/Memory/ProcessTable.swift
        Sources/Brim/Modules/Memory/MemoryRules.swift
        Sources/Brim/Modules/Memory/MemoryClassifier.swift
        Sources/Brim/Modules/Memory/MemoryActivity.swift
        Sources/Brim/Modules/Memory/MemoryRunaway.swift
        Sources/Brim/Modules/Memory/MemoryStrings.swift
        Sources/Brim/Core/Defaults.swift
        Sources/Brim/Core/NotchStrings.swift
        Sources/Brim/Core/NotchEditorStrings.swift
        Sources/Brim/UI/Settings/NotchSettingsTabRow.swift
        Sources/Brim/Core/NotchActivityStrings.swift
        Sources/Brim/Services/Notch/NotchAppFullscreen.swift
        Sources/Brim/Core/NotchClipboardSizeStrings.swift
        Sources/Brim/Core/NotchAgentStrings.swift
        Sources/Brim/Core/CodexAccountStrings.swift
        Sources/Brim/Services/Notch/NotchAgentSupport.swift
        Sources/Brim/Core/NotchLockScreenStrings.swift
        Sources/Brim/Services/Notch/NotchLockScreenSupport.swift
        Sources/Brim/Services/AgentUsage/AgentUsageModels.swift
        Sources/Brim/Services/AgentUsage/AgentPricing.swift
        Sources/Brim/Services/AgentUsage/AgentLogObject.swift
        Sources/Brim/Services/AgentUsage/AgentLogParser.swift
        Sources/Brim/Services/AgentUsage/Harness/AgentHarnessReader.swift
        Sources/Brim/Services/AgentUsage/Harness/ClaudeReader.swift
        Sources/Brim/Services/AgentUsage/Harness/CodexReader.swift
        Sources/Brim/Services/AgentUsage/Harness/OpenCodeReader.swift
        Sources/Brim/Services/AgentUsage/Harness/CopilotReader.swift
        Sources/Brim/Services/AgentUsage/AgentUsageSummary.swift
        Sources/Brim/Services/AgentUsage/AgentUsageStore.swift
        Sources/Brim/Services/AgentUsage/AgentUsageArchive.swift
        Sources/Brim/Services/AgentUsage/AgentCLIConversation.swift
        Sources/Brim/Services/AgentUsage/AgentClaudeServer.swift
        Sources/Brim/Services/AgentUsage/AgentCodexServer.swift
        Sources/Brim/Services/AgentUsage/CodexAccountLimits.swift
        Sources/Brim/Services/AgentUsage/CodexProfileLimitsService.swift
        Sources/Brim/Services/AgentUsage/AgentOpenCodeReader.swift
        Sources/Brim/Services/Notch/NotchSectionPaging.swift
        Sources/Brim/Services/Notch/NotchKeepAwakeSupport.swift
        Sources/Brim/Services/Notch/NotchSupport.swift
        Sources/Brim/UI/Notch/NotchDecorativeClock.swift
        Sources/Brim/UI/Notch/NotchScrollEdgeFade.swift
        Sources/Brim/UI/Notch/NotchAgentAnimationView.swift
        Sources/Brim/UI/WindowVisibilityReader.swift
        Sources/Brim/Core/FeatureCatalog.swift
        Sources/Brim/Core/FeaturePresets.swift
        Sources/Brim/Core/FeatureHubStrings.swift
        Sources/Brim/Core/ShortcutSettingsStrings.swift
        Sources/Brim/Core/MenuBarAppearanceStrings.swift
        Sources/Brim/Core/AppAppearance.swift
        Sources/Brim/Core/AppearanceStrings.swift
        Sources/Brim/Core/GeneralSettingsStrings.swift
        Sources/Brim/Core/SettingsPageStrings.swift
        Sources/Brim/Core/BatteryTimeStrings.swift
        Sources/Brim/Core/CPUCoreStrings.swift
        Sources/Brim/Core/MonitorLayoutStrings.swift
        Sources/Brim/Core/KeepAwakeStrings.swift
        Sources/Brim/Core/PermissionGuideStrings.swift
        Sources/Brim/Core/FanControlStrings.swift
        Sources/Brim/Core/ConnectedDevicesStrings.swift
        Sources/Brim/Services/FanControl/FanControlSupport.swift
        Sources/Brim/Services/FanControl/FanControlResumeSupport.swift
        Sources/Brim/Services/KillProcess/KillProcessSupport.swift
        Sources/Brim/Services/PrivateFileStore.swift
        Sources/Brim/Core/AppInfo.swift
        Sources/Brim/Core/GlobalShortcut.swift
        Sources/Brim/Core/SymbolicHotKeys.swift
        Sources/Brim/Services/SystemShortcutTakeoverSupport.swift
        Sources/Brim/Core/Localization.swift
        Sources/Brim/Core/FeatureStrings.swift
        Sources/Brim/Core/KillProcessStrings.swift
        Sources/Brim/Core/PortManagerStrings.swift
        Sources/Brim/Core/WhatsAppDownloadStrings.swift
        Sources/Brim/Core/WhatsAppOrganizerStrings.swift
        Sources/Brim/Services/GeneralPasteboardAccess.swift
        Sources/Brim/Services/Clipboard/ClipboardHistoryWrite.swift
        Sources/Brim/Services/Homebrew/HomebrewSupport.swift
        Sources/Brim/Services/Homebrew/HomebrewEnvironment.swift
        Sources/Brim/Services/Homebrew/HomebrewManager.swift
        Sources/Brim/UI/HomebrewOperationStatusView.swift
        Sources/Brim/Services/AppUpdates/AppUpdatesSupport.swift
        Sources/Brim/Services/AppUpdates/AppUpdateFeedSupport.swift
        Sources/Brim/Core/AppUpdateStrings.swift
        Sources/Brim/Services/Clipboard/ClipboardHistorySupport.swift
        Sources/Brim/Core/ColorValue.swift
        Sources/Brim/Services/Clipboard/ClipboardAutoClearSupport.swift
        Sources/Brim/Services/InstalledApps.swift
        Sources/Brim/Services/LaunchAtLoginSupport.swift
        Sources/Brim/UI/Settings/SettingsSearchSupport.swift
        Sources/Brim/UI/Settings/SettingsSidebarSupport.swift
        Sources/Brim/UI/Settings/FeatureVisibilitySupport.swift
        Sources/Brim/UI/Settings/SettingsWindow.swift
        Sources/Brim/Core/SettingsNavigationStrings.swift
        Sources/Brim/App/MenuBarSpacingSupport.swift
        Sources/Brim/App/MenuBarAllowanceSupport.swift
        Sources/Brim/App/ReopenRequestSupport.swift
        Sources/Brim/App/StatusItemAnchorSupport.swift
        Sources/Brim/Core/ClipboardIgnoredAppsStrings.swift
        Sources/Brim/Core/ClipboardRetentionStrings.swift
        Sources/Brim/Core/DiskExclusionStrings.swift
        Sources/Brim/Services/QuickTools/QuickToolsSupport.swift
        Sources/Brim/UI/Settings/MonitorToken.swift
        Sources/Brim/Services/QuickTools/WindowActivationPolicy.swift
        Sources/Brim/Core/InputSourceSelection.swift
        Sources/Brim/Services/SessionActivity.swift
        Sources/Brim/Services/SessionActivitySupport.swift
        Sources/Brim/Services/AssistiveKeyboard.swift
        Sources/Brim/Services/Metrics/MetricFormat.swift
        Sources/Brim/Services/Metrics/VMStatisticsDecoder.swift
        Sources/Brim/Services/KeepAwakeAutomationSupport.swift
        Sources/Brim/Services/SudoersSupport.swift
        Sources/Brim/Services/Metrics/BatteryTimeSupport.swift
        Sources/Brim/Services/Metrics/BatteryPowerSupport.swift
        Sources/Brim/Services/BoundedProcessRunner.swift
        Sources/Brim/Services/DetachedProcess.swift
        Sources/Brim/Services/ShellSupport.swift
        Sources/Brim/Services/PortManager/PortManagerSupport.swift
        Sources/Brim/Services/Metrics/NetworkProcessSupport.swift
        Sources/Brim/Services/Metrics/NetworkSampler.swift
        Sources/Brim/Services/Metrics/NetworkAddressService.swift
        Sources/Brim/Services/Metrics/SpeedTest.swift
        Sources/Brim/Services/Metrics/PeripheralBatterySampler.swift
        Sources/Brim/Services/Metrics/PeripheralBatterySupport.swift
        Sources/Brim/Services/Metrics/DiskSupport.swift
        Sources/Brim/Services/Metrics/DiskEjectSupport.swift
        Sources/Brim/Services/Metrics/MonitorSamplingPolicy.swift
        Sources/Brim/Services/Metrics/USBDeviceSampler.swift
        Sources/Brim/Services/Metrics/CPUCoreSampler.swift
        Sources/Brim/Services/Metrics/MaxCapacityProbe.swift
        Sources/Brim/Services/Metrics/TemperatureSensorSelector.swift
        Sources/Brim/Services/Metrics/SustainedAlertGate.swift
        Sources/Brim/Core/GraphScaleStrings.swift
        Sources/Brim/Core/NotchLowBatteryStrings.swift
        Sources/Brim/Services/Display/LidDimmingSupport.swift
        Sources/Brim/Services/Cleaner/CleanerSupport.swift
        Sources/Brim/Services/Cleaner/CleanerPolicy.swift
        Sources/Brim/Services/Cleaner/CleanerSchedule.swift
        Sources/Brim/Services/Uninstall/UninstallerSupport.swift
        Sources/Brim/Services/FileEvents/FileEventStream.swift
        Sources/Brim/Services/NotifierSupport.swift
        Sources/Brim/Services/ManagedDownloads/WhatsAppDownloadSupport.swift
        Tests/*.swift
        build/generated-tests/*.swift
    )
    TEST_OUTPUT_FILE_MAP="$TEST_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$TEST_OUTPUT_FILE_MAP" "$TEST_OBJECT_DIR" "${TEST_SOURCES[@]}"
    echo "▸ Building & running tests against $(basename "$SDK")…"
    swiftc -Onone -incremental -enable-batch-mode -j "$BRIM_JOBS" \
        -module-name BrimTests -output-file-map "$TEST_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" \
        "${TEST_SOURCES[@]}" -o build/metrics-tests
    test_status=0
    ./build/metrics-tests "${TEST_ARGS[@]}" || test_status=$?
    if (( ${#TEST_ARGS} == 0 )); then
        ./Tests/PreferenceCleanupTests.sh || test_status=1
        ./Tests/DeveloperInstallIsolationTests.sh || test_status=1
        ./Tests/UninstallClaudeStateTests.sh || test_status=1
    fi
    discard_test_preferences || test_status=1
    exit $test_status
fi

echo "▸ Compiling ($BUILD_CONFIGURATION) against $(basename "$SDK")…"
APP_SOURCES=(Sources/Brim/**/*.swift)
if (( ! DEV )); then
    # A release starts from an empty build directory, so nothing an earlier
    # build left behind (an old icon catalog, a staged bundle) can reach it.
    # Only the compiler's incremental records stay: they rebuild whatever
    # changed since, and a fresh checkout has none.
    find build -mindepth 1 -maxdepth 1 ! -name objects -exec rm -rf {} + 2>/dev/null || true
fi
APP_OBJECT_DIR="build/objects/$EXECUTABLE"
mkdir -p build "$APP_OBJECT_DIR"
APP_OUTPUT_FILE_MAP="$APP_OBJECT_DIR/output-file-map.json"
write_swift_output_file_map "$APP_OUTPUT_FILE_MAP" "$APP_OBJECT_DIR" "${APP_SOURCES[@]}"
# Without -j the driver compiles one file at a time, and without batch mode
# each file's compiler parses the whole module again: a clean release took a
# quarter of an hour. Batches share that work and run on every core, and the
# optimization stays per file, as before.
swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -incremental -enable-batch-mode -j "$BRIM_JOBS" \
    -output-file-map "$APP_OUTPUT_FILE_MAP" \
    -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" \
    "${BUILD_VARIANT_FLAGS[@]}" \
    "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"

echo "▸ Compiling protected fan helper…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
    Sources/Brim/Services/FanControl/FanControlSupport.swift \
    Sources/Brim/Services/FanControl/FanControlXPC.swift \
    Sources/Brim/Services/SystemMonitor/SMCClient.swift \
    Sources/Brim/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/Brim/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset
xattr -c -r build/AppIcon.iconset build/AppIcon.icns build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
ACTOOL_BIN="$(xcrun --find actool 2>/dev/null || true)"
ICON_TMP="$(mktemp -d)"
ADAPTIVE_SKIP=""
if [[ -z "$ACTOOL_BIN" ]]; then
    ADAPTIVE_SKIP="actool not found (adaptive icons need Xcode 26+)"
else
    echo "▸ Compiling adaptive icon catalog…"
    # actool crashes on File Provider-synced paths, so compile a local copy.
    ditto "Resources/Brand/AppIcon.icon" "$ICON_TMP/AppIcon.icon"
    # Xcode 27 beta actool requires the --compile target directory to already exist.
    mkdir -p "$ICON_TMP/catalog"
    if "$ACTOOL_BIN" "$ICON_TMP/AppIcon.icon" \
            --compile "$ICON_TMP/catalog" \
            --app-icon AppIcon \
            --platform macosx \
            --target-device mac \
            --minimum-deployment-target 14.0 \
            --enable-on-demand-resources NO \
            --output-partial-info-plist "$ICON_TMP/partial-info.plist" \
            >"$ICON_TMP/actool.log" 2>&1 && [[ -s "$ICON_TMP/catalog/Assets.car" ]]; then
        mv "$ICON_TMP/catalog/Assets.car" build/Assets.car
    else
        ADAPTIVE_SKIP="actool could not compile the catalog"
    fi
fi
if [[ -n "$ADAPTIVE_SKIP" ]]; then
    cp "$ICON_TMP/actool.log" build/actool-failure.log 2>/dev/null || true
    echo "  adaptive icon skipped: $ADAPTIVE_SKIP (Dock falls back to AppIcon.icns)"
fi
echo "▸ Assembling and signing bundle…"
STAGE_TMP="$(mktemp -d)"
STAGE="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
brim_add_claude_helper "$STAGE"
cp Resources/agent-prices.json "$STAGE/Contents/Resources/agent-prices.json"
cp Resources/fan-control.plist "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
# Info.plist and the fan helper's launchd plist name the release build. Each
# variant writes its own identity from Tools/identity.sh into both, so the
# Developer build installs and runs next to the release one, with its own
# permissions, preferences, login item and fan service.
{
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    FAN_PLIST="$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices dict" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    brim_finish_identity "$STAGE"
}
if (( DEV )); then
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :BrimBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :BrimFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -f build/Assets.car ]]; then
    cp build/Assets.car "$STAGE/Contents/Resources/Assets.car"
fi
xattr -c -r "$STAGE" 2>/dev/null || true

# Signing: one identity for every item, chosen explicitly, with the hardened
# runtime (codesign_app and codesign_fan_helper, above).
sign_bundle() {
    local bundle="$1"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"

    echo "  signing (hardened runtime): $BRIM_SIGNING_LABEL"
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    codesign_app "$bundle"

    # If local filesystem metadata invalidates the first signature, sign once
    # more. The installed Developer bundle is signed again after the final copy.
    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        echo "  re-signing after filesystem metadata settled"
        xattr -c -r "$bundle" 2>/dev/null || true
        [[ -f "$helper" ]] && codesign_fan_helper "$helper"
        codesign_app "$bundle"
    fi
    [[ -f "$executable" ]] && codesign --verify --strict "$executable"
    [[ -f "$helper" ]] && codesign --verify --strict "$helper"
    codesign --verify --deep --strict "$bundle"
}

sign_installed_bundle() {
    local bundle="$1"
    wait_for_install_metadata "$bundle"
    sign_bundle "$bundle"
}

sign_bundle "$STAGE"

# Only the installed copy of this variant, matched by its full executable
# path (brim_app_pids), never a process that merely shares the name.
process_is_running() {
    [[ -n "$(brim_app_pids "$1")" ]]
}

stop_process() {
    local proc="$1"
    local -a pids
    pids=($(brim_app_pids "$proc"))
    (( ${#pids} )) && kill "${pids[@]}" 2>/dev/null || true
    for _ in {1..50}; do
        if ! process_is_running "$proc"; then
            return 0
        fi
        sleep 0.1
    done
    echo "✗ $proc is still running — quit it and retry" >&2
    return 1
}

wait_for_install_metadata() {
    local bundle="$1"
    local missing
    for _ in {1..50}; do
        missing=0
        while IFS= read -r file; do
            if ! xattr -p com.apple.provenance "$file" >/dev/null 2>&1; then
                missing=1
                break
            fi
        done < <(find "$bundle/Contents" -type f ! -path "*/_CodeSignature/*")
        if (( missing == 0 )); then
            return 0
        fi
        sleep 0.1
    done
}

# Installed development builds only need the copy in /Applications. Retaining
# another app in each checkout pollutes application search with stale builds.
if (( DEV )); then
    for old_bundle in "build/stage/$APP_NAME.app" "build/stage.noindex/$APP_NAME.app"; do
        if [[ -d "$old_bundle" ]]; then
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                -u "$PWD/$old_bundle" >/dev/null 2>&1 || true
            rm -rf "$old_bundle"
        fi
    done
fi

if (( !DEV || !INSTALL )); then
    STAGE_DIRECTORY="build/stage"
    (( DEV )) && STAGE_DIRECTORY="build/stage.noindex"
    mkdir -p "$STAGE_DIRECTORY"
    BUILD_STAGE="$STAGE_DIRECTORY/$APP_NAME.app"
    rm -rf "$BUILD_STAGE"
    ditto --noextattr --noqtn "$STAGE" "$BUILD_STAGE"
    xattr -c -r "$BUILD_STAGE" 2>/dev/null || true
    if ! codesign --verify --deep --strict "$BUILD_STAGE" >/dev/null 2>&1; then
        if xattr -lr "$BUILD_STAGE" 2>/dev/null | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork|provenance|fileprovider)'; then
            echo "  staging copy has local filesystem metadata; temp bundle was verified"
        else
            codesign --verify --deep --strict "$BUILD_STAGE"
        fi
    fi
    echo "✓ Bundle ready: $BUILD_STAGE"
fi

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    brim_refuse_foreign_bundle "/Applications/$APP_NAME.app" || exit 1   # never another app of that name
    stop_process "$EXECUTABLE"
    INSTALL_DEST="/Applications/$APP_NAME.app"
    rm -rf "$INSTALL_DEST"
    ditto --noextattr --noqtn "$STAGE" "$INSTALL_DEST"
    sign_installed_bundle "$INSTALL_DEST"
    echo "✓ Installed: $INSTALL_DEST"
fi
