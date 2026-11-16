# Troubleshooting

## A feature does nothing

Most features need a macOS permission ([permissions](PERMISSIONS.md)).

1. Open System Settings › Privacy & Security and find the permission.
2. Make sure Brim (or Brim (Developer)) is listed and on.
3. If it is on and still does nothing, turn it off and on again.

A build signed with a different identity counts as a different app to macOS:
remove the old entry with the minus button and grant it again, or reset the
grants (below).

## Clipboard history does not copy or paste

Check first whether a fresh copy shows up in history. History must be on, and
copies from excluded apps or marked as concealed are not saved. If copying
works but automatic paste does not, check Accessibility and the app that
should receive the paste.

A history copy fails, with the system alert, after five seconds or while
another one is still pending. If another app stops answering a clipboard read,
history waits for that read instead of piling more behind it; quit and reopen
that app if fresh copies stop appearing.

## Homebrew and your shell startup files

Homebrew in Brim uses the proxy and `HOMEBREW_*` settings your shell exports.
To read them, Brim starts your login shell once per launch, which reads
`~/.zprofile` and `~/.zshrc`; a startup file that reads a protected folder then
asks for access in Brim's name. During that run `BRIM_RESOLVING_ENVIRONMENT` is
`1`, so a startup file can skip terminal-only work:

```sh
[[ -n $BRIM_RESOLVING_ENVIRONMENT ]] && return
```

## Resetting permissions

Settings › Advanced resets every grant, the login item and the closed-lid rule.
From Terminal:

```sh
tccutil reset All com.roblesconsulting.brim
tccutil reset All com.roblesconsulting.brim.dev   # the Developer app
```

## Uninstalling

Settings › Advanced › Uninstall Brim completely, or from a checkout:

```sh
Tools/uninstall.sh          # Brim
Tools/uninstall.sh --dev    # Brim (Developer)
```

## Health check

```sh
./build/BrimDeveloper --selftest
build/brim-claude --selftest
```
