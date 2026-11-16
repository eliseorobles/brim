# Privacy

Brim runs on the Mac and keeps what it reads there. It has no account, no
analytics, no crash reporting and no server of its own.

## What stays on the Mac

- Monitor readings (CPU, GPU, memory, network, disk, power, fans, connected
  devices) are read through macOS and shown, never uploaded.
- Clipboard history, including copied images and files, is stored in Brim's
  own folder. Content its source app marks as concealed is never recorded.
- Claude Code and Codex usage come from their own logs and from the tools
  themselves: Brim starts `claude` or `codex` for a short check, and they sign
  in with their own credentials, which Brim never reads.
- Preferences live in Brim's own defaults domain; Claude accounts state lives in
  `~/.config/brim` (`~/.config/brim-dev` for the Developer app). Uninstalling
  Brim deletes both.

## When Brim uses the network

Only for a feature you turned on, and only for what it shows:

| Feature | Contacts | Why |
|---|---|---|
| App Updates | Each app's own update feed, the App Store lookup service, `formulae.brew.sh` | Newer versions of installed apps |
| Homebrew | `formulae.brew.sh`, and whatever `brew` itself contacts | Install counts for the list; installs and upgrades you start |
| Speed test | `speed.cloudflare.com` | Measuring the connection when you start a test |
| Claude accounts, AI agents | Anthropic and OpenAI, through `claude` and `codex` | Plan limits and resets of the signed-in account |

Nothing else leaves the Mac.
