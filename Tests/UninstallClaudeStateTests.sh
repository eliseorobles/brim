#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robles Consulting LLC

# Runs the Claude accounts block of Tools/uninstall.sh, as shipped, against
# scratch homes and scratch BRIM_CLAUDE_STATE_DIR folders. Nothing else in the
# script runs: no app is quit or removed, and no real ~/.config/brim*,
# ~/.claude* or ~/.zshrc is read or written.
set -euo pipefail
cd "$(dirname "$0")/.."
state_test_dir=$(mktemp -d)
trap 'command rm -rf "$state_test_dir"' EXIT
state_test_dir="${state_test_dir:A}"

sed -n '/^# Claude accounts\. /,/^# `--uninstall` restores sleep/p' Tools/uninstall.sh > "$state_test_dir/block.zsh"
grep -q 'claude_left=()' "$state_test_dir/block.zsh"

failures=0
fail() { print -u2 "✗ $1"; failures=$((failures + 1)); }

# The block in its own zsh with the script's options and no startup files.
# Prints what it named as left behind, then "kept=" and the folder it kept.
run_block() {  # home, DEV, optional BRIM_CLAUDE_STATE_DIR
    [[ "$1" == "$state_test_dir"/* && "${3:-$state_test_dir/}" == "$state_test_dir"/* ]] \
        || { print -u2 "refusing a folder outside $state_test_dir"; exit 1; }
    HOME="$1" DEV="$2" BRIM_CLAUDE_STATE_DIR="${3:-}" zsh -f -c '
        set -uo pipefail
        source "$0" >/dev/null
        (( ${#claude_left} )) && print -rl -- "${claude_left[@]}"
        (( ${#claude_held} )) && print -rl -- "held: "${^claude_held}
        print -r -- "kept=${claude_kept-}"
    ' "$state_test_dir/block.zsh"
}

# The real failure (T-20): the release app's folder stayed. What
# installs.json names is read first, then the folder goes, with the variant
# folder it leaves empty.
home="$state_test_dir/release-home"
state="$home/.config/brim/claude"
mkdir -p "$state/live" "$state/sessions" "$state/requests" "$state/mcp-backups" \
    "$home/.config/other" "$state_test_dir/outside"
print '{}' > "$state/accounts.json"
print '{}' > "$state/live/a.json"
print '{}' > "$state/mcp-backups/a-20261113-000000.json"
print keep > "$home/.config/other/keep"
print keep > "$state_test_dir/outside/keep"
ln -s "$state_test_dir/outside" "$state/link"
cat > "$state/installs.json" <<EOF
{"statusLine": {"settings": "$home/.claude/settings.json", "inserted": "x", "createdFile": false,
                "installedAt": "2026-11-13T00:00:00Z"},
 "shell": {"link": "$home/.local/bin/brim-claude", "linkTarget": "/x", "linkCreated": true,
           "script": "$home/.config/brim/claude.zsh", "rcFile": "$home/.zshrc", "rcLine": "source x",
           "installedAt": "2026-11-13T00:00:00Z"}}
EOF
output="$(run_block "$home" 0)"
[[ "$output" == *"the \"statusLine\" entry Brim added to $home/.claude/settings.json"* \
    && "$output" == *"this line in $home/.zshrc: source x"* \
    && "$output" == *"the link $home/.local/bin/brim-claude"* ]] \
    || fail "what installs.json names is read before the folder goes: $output"
[[ ! -e "$state" ]] || fail "the release app's Claude state folder is removed"
[[ ! -e "$home/.config/brim" ]] || fail "and ~/.config/brim, which it left empty"
[[ "${output##*$'\n'}" == "kept=" ]] || fail "and nothing is reported as kept: $output"
[[ -d "$home/.config" && "$(cat "$home/.config/other/keep")" == keep ]] \
    || fail "~/.config and its other folders stay"
[[ "$(cat "$state_test_dir/outside/keep")" == keep ]] \
    || fail "whatever a link inside the state folder points at stays"

# The Developer app removes only its own folder; the release app's stays, and
# so does a variant folder with anything else in it.
home="$state_test_dir/developer-home"
mkdir -p "$home/.config/brim/claude" "$home/.config/brim-dev/claude/live"
print '{}' > "$home/.config/brim/claude/accounts.json"
print '{}' > "$home/.config/brim-dev/claude/accounts.json"
print keep > "$home/.config/brim-dev/keep"
output="$(run_block "$home" 1)"
[[ ! -e "$home/.config/brim-dev/claude" ]] || fail "the Developer app's Claude state folder is removed"
[[ "$(cat "$home/.config/brim-dev/keep")" == keep ]] || fail "a variant folder with anything else in it stays"
[[ "$(cat "$home/.config/brim/claude/accounts.json")" == '{}' ]] \
    || fail "the Developer uninstall never touches the release app's folder"

# BRIM_CLAUDE_STATE_DIR: that folder goes; the folder above it stays even when
# empty, and so does the standard folder.
home="$state_test_dir/override-home"
mkdir -p "$home/.config/brim/claude" "$state_test_dir/override/claude/live"
print '{}' > "$home/.config/brim/claude/accounts.json"
output="$(run_block "$home" 0 "$state_test_dir/override/claude")"
[[ ! -e "$state_test_dir/override/claude" ]] || fail "the BRIM_CLAUDE_STATE_DIR folder is removed"
[[ -d "$state_test_dir/override" ]] || fail "the folder above BRIM_CLAUDE_STATE_DIR stays"
[[ "$(cat "$home/.config/brim/claude/accounts.json")" == '{}' ]] \
    || fail "the standard folder stays when BRIM_CLAUDE_STATE_DIR names another"

# Only Brim's own folder ever goes. Each of these is kept and reported.
home="$state_test_dir/refuse-home"
mkdir -p "$home" "$state_test_dir/link-target" "$state_test_dir/links" "$home/.claude-work/claude" \
    "$state_test_dir/refuse/state" "$state_test_dir/dots/a" "$state_test_dir/dots/claude" \
    "$state_test_dir/claude/user"
print keep > "$state_test_dir/link-target/keep"
ln -s "$state_test_dir/link-target" "$state_test_dir/links/claude"
refused=(
    "$home" "$state_test_dir/links/claude" "a link named claude"
    "$home" "$home/.claude-work/claude" "a folder inside ~/.claude*"
    "$home" "$state_test_dir/refuse/state" "a folder with another name"
    "$home" "$state_test_dir/dots/a/../claude" "a path with .. in it"
    "$home" "$state_test_dir/dots/claude/" "a path with an empty part"
    "$state_test_dir/claude" "$state_test_dir/claude" "the home folder"
    "$state_test_dir/claude/user" "$state_test_dir/claude" "a folder above the home folder"
)
for refusal_home refusal_folder refusal_what in "${refused[@]}"; do
    output="$(run_block "$refusal_home" 0 "$refusal_folder")"
    [[ -e "$refusal_folder" && "${output##*$'\n'}" == "kept=$refusal_folder" ]] \
        || fail "$refusal_what is left alone and reported: $output"
done
[[ -L "$state_test_dir/links/claude" && "$(cat "$state_test_dir/link-target/keep")" == keep ]] \
    || fail "nothing a refused link points at is touched"

# The standard path, when ~/.config/brim is a link into ~/.claude*, resolves
# there and is refused.
home="$state_test_dir/linked-home"
mkdir -p "$home/.claude-x/brim/claude" "$home/.config"
print '{}' > "$home/.claude-x/brim/claude/accounts.json"
ln -s "$home/.claude-x/brim" "$home/.config/brim"
output="$(run_block "$home" 0)"
[[ "$(cat "$home/.claude-x/brim/claude/accounts.json")" == '{}' \
    && "${output##*$'\n'}" == "kept=$home/.config/brim/claude" ]] \
    || fail "a state folder that resolves inside ~/.claude* is left alone: $output"

# Copies a check-out still holds out of Claude Code's view (T-40; the app was
# gone, so `--uninstall` could not put them back): each is named, in ~/.claude,
# ~/.claude-* and every account folder accounts.json names, once.
home="$state_test_dir/held-home"
elsewhere="$state_test_dir/held-elsewhere"
mkdir -p "$home/.config/brim/claude" "$home/.claude/projects/-App/.brim-checked-out" \
    "$home/.claude-a/projects/-App/.brim-checked-out" "$elsewhere/projects/-Repo/.brim-checked-out" "$home/.claude-linked"
ln -s "$home/.claude/projects" "$home/.claude-linked/projects"
print x > "$home/.claude/projects/-App/.brim-checked-out/s1.jsonl"
print x > "$home/.claude-a/projects/-App/.brim-checked-out/s2.jsonl"
print x > "$elsewhere/projects/-Repo/.brim-checked-out/s3.jsonl"
print x > "$home/.claude/projects/-App/s4.jsonl"
print "{\"accounts\": [{\"folder\": \"\"}, {\"folder\": \"$elsewhere\"}]}" > "$home/.config/brim/claude/accounts.json"
output="$(run_block "$home" 0)"
held_lines=("${(@f)$(print -r -- "$output" | grep '^held: ')}")
[[ ${#held_lines} == 3 && "$output" == *"held: $home/.claude/projects/-App/.brim-checked-out/s1.jsonl"* \
    && "$output" == *"held: $home/.claude-a/projects/-App/.brim-checked-out/s2.jsonl"* \
    && "$output" == *"held: $elsewhere/projects/-Repo/.brim-checked-out/s3.jsonl"* ]] \
    || fail "every held copy left behind is named once, a linked folder's too: $output"

# Nothing there: nothing to do, nothing kept.
home="$state_test_dir/empty-home"
mkdir -p "$home"
output="$(run_block "$home" 0)"
[[ "$output" == "kept=" ]] || fail "with no state folder nothing is named or kept: $output"

(( failures == 0 )) || exit 1
print 'UNINSTALL CLAUDE STATE TESTS OK'
