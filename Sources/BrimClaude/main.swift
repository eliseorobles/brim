// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robles Consulting LLC

// brim-claude: Brim's command-line helper for Claude Code accounts. Claude
// Code runs `brim-claude statusline` as its status line in every session; the
// zsh integration (Resources/claude.zsh) runs `pick` and `move`. It is
// compiled from this file and Sources/Brim/Modules/ClaudeAccounts/*.swift,
// where every subcommand lives (ClaudeHelper), so the app's tests cover them.
//
// It never reads or writes a Claude credential, never opens the Keychain,
// never starts a process and never uses the network.

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let result = ClaudeHelper.run(arguments, input: { FileHandle.standardInput.readDataToEndOfFile() },
                              context: ClaudeHelperContext.current())
if !result.stdout.isEmpty { FileHandle.standardOutput.write(Data(result.stdout.utf8)) }
if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
// A status line must never fail the session it draws for.
exit(arguments.first == "statusline" ? 0 : result.status)
