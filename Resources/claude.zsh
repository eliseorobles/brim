# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robles Consulting LLC
#
# Brim: Claude Code accounts in zsh.
#
# What this is. Three shell functions that start Claude Code on one of the
# accounts Brim lists (one Claude Code config folder per account):
#   claude [args]                      start on the account Brim picks (Auto:
#                                      the soonest weekly renewal), or on the
#                                      folder CLAUDE_CONFIG_DIR already names
#                                      (direnv, an export)
#   cc <account> [args]                start on that account (by its label)
#   cx [<session-id>] [--to <account>] after /exit, continue the newest
#                                      conversation in this folder (or that
#                                      one) on another account
# They ask Brim's helper, brim-claude, which account to use; brim-claude never
# touches a sign-in. An account is named exactly as Brim lists it (its label,
# any case; never a part of one): an unknown name prints the list of names and
# starts nothing; two names that differ only in case are named by folder
# (`cc ~/.claude-work`, `cc ~/.claude` for the default account).
# `claude <name>` with an account's label as its only argument asks "did you
# mean cc <name>?" and starts nothing (`claude -- <name>` sends it as a
# prompt, on the account Brim picks).
#
# When the conversation cx, `claude -c` or `claude -r <id>` would continue is
# still open in another terminal (a session left open, say one paused at its
# usage limit), brim-claude never takes an older one instead: it names the
# account, the tab and why, then waits for that session to end (Esc and /exit
# there) and continues; Ctrl-C cancels and starts nothing. The newest ended
# conversation is continued only when named (cx <id>, claude -r <id>).
#
# Every account folder holds a copy of every conversation (Brim keeps them in
# sync), so Claude Code's /resume lists every account's conversations and a
# conversation continues anywhere with a plain resume. `claude --resume <id>`
# (also -r and --resume=<id>), `claude -c`/`--continue` and a bare --resume
# (the picker) ask `brim-claude resume` first: it syncs this folder's
# conversations into the account it picks (the one the conversation last ran
# on while that one has room) and names that account. The arguments are
# passed on unchanged, except that -c becomes `--resume <id>` when Claude
# Code's own -c would pick another conversation (a running one). `cc
# <account>` with a resume target does the same on that account, and with
# CLAUDE_CONFIG_DIR already set (direnv, an export) on that folder. Arguments
# after `--` are never read. Every launch removes
# CLAUDE_SECURESTORAGE_CONFIG_DIR, and the default account starts with
# CLAUDE_CONFIG_DIR removed: naming ~/.claude explicitly would select a
# different sign-in. Without brim-claude on PATH, `claude` runs Claude Code as
# if this file were not there.
#
# `cc` shadows the C compiler in interactive shells only. When its first
# argument is an option or an existing regular file it still runs the
# compiler (a folder is an account's), and `command cc` always does.
#
# Claude Code's management subcommands (mcp, auth, plugin, doctor, update,
# attach, logs, ...) are not routed: they run on the default account, as they
# did before this file, so `claude mcp add` or `claude auth logout` never lands
# on whichever account Auto picked. Use `cc <account> mcp ...` to aim one.
#
# Claude Code copies these functions into each session's shell snapshot, so
# its Bash tool sees them too. There (CLAUDECODE or CLAUDE_CODE_ENTRYPOINT is
# set) they step aside: `claude` stays on the session's own account (the
# CLAUDE_CONFIG_DIR it inherited, set or unset) and `cc` is the compiler.
#
# Installed by Brim's "Install shell integration" as ~/.config/brim/claude.zsh,
# sourced from ~/.zshrc after the direnv hook.
# To remove it: delete the line that sources this file from ~/.zshrc, delete
# the file, and open a new terminal (or run `unfunction claude cc cx
# _brim_claude_run _brim_claude_resume _brim_claude_manages` in each open one).

# Runs Claude Code on an account folder ("" is the default account; "-"
# keeps whatever CLAUDE_CONFIG_DIR is already set, or unset).
_brim_claude_run() {
    emulate -L zsh
    local dir="$1"
    shift
    if [[ "$dir" == - ]]; then
        command env -u CLAUDE_SECURESTORAGE_CONFIG_DIR claude "$@"
    elif [[ -z "$dir" ]]; then
        command env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CONFIG_DIR claude "$@"
    else
        command env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR="$dir" claude "$@"
    fi
}

# Whether the first argument is one of Claude Code's management subcommands,
# which are never routed (see the header).
_brim_claude_manages() {
    case "${1-}" in
        agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|purge|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade)
            return 0
            ;;
    esac
    return 1
}

claude() {
    emulate -L zsh
    # Inside a Claude Code session, the session's account; so does a missing
    # helper.
    if [[ -n "${CLAUDECODE-}" || -n "${CLAUDE_CODE_ENTRYPOINT-}" ]] || (( ! $+commands[brim-claude] )); then
        _brim_claude_run - "$@"
        return
    fi
    # An account's name as the only argument is a mistyped `cc <name>`, not a
    # prompt.
    if (( $# == 1 )) && [[ "$1" != -* ]] && ! _brim_claude_manages "$1"; then
        local account
        if account="$(command brim-claude account-name "$1" 2>/dev/null)" && [[ -n "$account" ]]; then
            print -ru2 -- "claude: did you mean cc $account? \"$1\" is a Claude account's name, so Claude Code did not start."
            print -ru2 -- "        (To send it to Claude Code as a prompt: claude -- ${(q)1})"
            return 2
        fi
    fi
    local arg previous="" model=""
    for arg in "$@"; do
        [[ "$arg" == -- ]] && break
        if [[ "$previous" == --model ]]; then
            model="$arg"
        elif [[ "$arg" == --model=* ]]; then
            model="${arg#--model=}"
        fi
        previous="$arg"
    done
    # An explicit folder (direnv, an export) wins; a conversation to resume
    # is synced into it first.
    if [[ -n "${CLAUDE_CONFIG_DIR-}" ]]; then
        if ! _brim_claude_manages "${1-}"; then
            _brim_claude_resume "" "$CLAUDE_CONFIG_DIR" "$model" "$@" && return _brim_claude_status
            (( _brim_claude_status != 255 )) && return _brim_claude_status
        fi
        _brim_claude_run - "$@"
        return
    fi
    # Management subcommands stay on the default account (see the header).
    if _brim_claude_manages "${1-}"; then
        _brim_claude_run "" "$@"
        return
    fi
    _brim_claude_resume "" "" "$model" "$@" && return _brim_claude_status
    (( _brim_claude_status != 255 )) && return _brim_claude_status
    local -a ask
    ask=(pick --cwd "$PWD")
    [[ -n "$model" ]] && ask+=(--model "$model")
    local dir
    # brim-claude's stderr stays visible: it says when it waits for Brim.
    dir="$(command brim-claude "${ask[@]}")" || dir=""
    _brim_claude_run "$dir" "$@"
}

# When the arguments resume a conversation (-r/--resume <id>, --resume=<id>,
# -c/--continue, or a bare -r/--resume; nothing after `--` counts), asks
# `brim-claude resume` where, which syncs the conversation there first, then
# runs Claude Code with the arguments unchanged (-c becomes `--resume <id>`
# when brim-claude names one). Its first argument fixes the account (cc), its
# second pins the config folder already set (CLAUDE_CONFIG_DIR, kept as it is
# for the launch), its third is the --model. Returns 0 after running it, with
# Claude Code's exit status in _brim_claude_status; otherwise returns 1 and
# sets _brim_claude_status: 255 when the arguments resume nothing (the caller
# launches as usual), else brim-claude's failure, already shown.
_brim_claude_resume() {
    emulate -L zsh
    local account="$1" folder="$2" model="$3"
    shift 3
    local kind="" id="" arg
    local -i i=1 at=0
    while (( i <= $# )); do
        arg="${@[i]}"
        [[ "$arg" == -- ]] && break
        if [[ "$arg" == -r || "$arg" == --resume ]]; then
            if (( i < $# )) && [[ "${@[i+1]}" != -* ]]; then
                kind=id
                id="${@[i+1]}"
            else
                kind=picker
            fi
            break
        elif [[ "$arg" == --resume=* ]]; then
            kind=id
            id="${arg#--resume=}"
            break
        elif [[ "$arg" == -c || "$arg" == --continue ]]; then
            kind=continue
            at=i
            break
        fi
        (( i += 1 ))
    done
    typeset -g _brim_claude_status=255
    [[ -z "$kind" ]] && return 1
    local -a ask
    ask=(resume --cwd "$PWD")
    case "$kind" in
        id) ask+=(--id "$id") ;;
        continue) ask+=(--continue) ;;
        picker) ask+=(--picker) ;;
    esac
    [[ -n "$model" ]] && ask+=(--model "$model")
    [[ -n "$account" ]] && ask+=(--account "$account")
    [[ -n "$folder" ]] && ask+=(--folder "$folder")
    local out
    # brim-claude's stderr stays visible: it says where and why.
    out="$(command brim-claude "${ask[@]}")" || { _brim_claude_status=$?; return 1; }
    # Two lines: the folder (empty for the default account) and, for -c, the
    # session id to resume in its place (empty: the arguments as given).
    local -a plan
    plan=("${(@f)out}")
    local dir="${plan[1]-}" sid="${plan[2]-}"
    # A pinned folder is launched as it is set.
    [[ -n "$folder" ]] && dir=-
    local -a args
    args=("$@")
    [[ "$kind" == continue && -n "$sid" ]] && args[at,at]=(--resume "$sid")
    _brim_claude_run "$dir" "${args[@]}"
    _brim_claude_status=$?
    return 0
}

cc() {
    emulate -L zsh
    if [[ -n "${CLAUDECODE-}" || -n "${CLAUDE_CODE_ENTRYPOINT-}" ]]; then
        command cc "$@"
        return
    fi
    if (( $# == 0 )); then
        print -ru2 -- "usage: cc <account> [claude arguments]   (the C compiler: command cc)"
        return 2
    fi
    if [[ "$1" == -* || -f "$1" ]]; then
        command cc "$@"
        return
    fi
    if (( ! $+commands[brim-claude] )); then
        print -ru2 -- "cc: brim-claude is not on PATH; open Brim and install the shell integration"
        return 127
    fi
    local account="$1"
    shift
    # Management subcommands run on the named account as given.
    if ! _brim_claude_manages "${1-}"; then
        _brim_claude_resume "$account" "" "" "$@" && return _brim_claude_status
        (( _brim_claude_status != 255 )) && return _brim_claude_status
    fi
    local dir
    dir="$(command brim-claude pick --account "$account")" || return
    _brim_claude_run "$dir" "$@"
}

cx() {
    emulate -L zsh
    if (( ! $+commands[brim-claude] )); then
        print -ru2 -- "cx: brim-claude is not on PATH; open Brim and install the shell integration"
        return 127
    fi
    local out
    # brim-claude's stderr stays visible: it says where the conversation goes,
    # or where it is still open while it waits for it to end (Ctrl-C: exit
    # 130, nothing starts).
    out="$(command brim-claude move --cwd "$PWD" "$@")" || return
    # Two lines: the target folder (empty for the default account) and the
    # session id. brim-claude already synced the conversation into it.
    local -a plan
    plan=("${(@f)out}")
    local dir="${plan[1]-}" sid="${plan[2]-}"
    if [[ -z "$sid" ]]; then
        print -ru2 -- "cx: brim-claude move did not name a session"
        return 1
    fi
    _brim_claude_run "$dir" --resume "$sid"
}
