# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub:
[Report a vulnerability](https://github.com/eliseorobles/brim/security/advisories/new).
Don't open a public issue for them.

Include what you found, how to reproduce it, the Brim version (Settings › About)
and your macOS version. You should get a first reply within a week.

## Scope

Brim runs with access to sensitive parts of the Mac, so these areas matter most:

- the privileged fan control helper and its XPC connection
- the Claude Code accounts module and the `brim-claude` helper, which start
  Claude Code with a chosen config folder (Brim must never read, copy or expose
  a Claude credential)
- the Cleaner and Uninstaller, which move files to the Trash
- the Memory module, which can end processes
- clipboard history, which must never record content marked as concealed

## Supported versions

Only the latest commit on `main` is supported.
