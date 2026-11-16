# Permissions

Brim asks for a permission only when a feature that needs it is turned on, and
only from that feature's own screen or the setup tour. Settings › Permissions
shows each one's state and opens the matching pane of System Settings.

The release app's grants belong to `com.roblesconsulting.brim`; the Developer
app's to `com.roblesconsulting.brim.dev`, so each has its own.

## Accessibility

- **Keep awake** moves the pointer a pixel when its mouse jiggle option is on.
- **Paste as plain text** posts the paste keystroke to the app in front.
- **Dynamic Island**: its clipboard page pastes into the app in front.
- **Shortcuts**: recording a new shortcut watches the keyboard while the
  recorder is open.

## Full Disk Access

- **Cleaner** reads caches, logs and other folders macOS protects to size what
  can be removed.
- **Uninstaller** finds the files an app left in protected folders.

## Files and Folders

**Cleaner** reads Downloads, Desktop, Documents and connected volumes to find
WhatsApp downloads and forgotten screenshots. Only file metadata is read.

## Notifications

Cleaner (schedule and WhatsApp downloads), App Updates, the monitor's CPU,
memory, disk and power alerts, Claude accounts (limit alerts) and the Memory
module (memory pressure).

## Automation (Finder)

**Cleaner** and **Uninstaller** ask Finder to move items to the Trash, so they
can be put back from there.

## App Management

**Homebrew** and **App Updates** replace apps in /Applications when you update
them.

## Bluetooth

**Connected devices** reads the battery level of Bluetooth peripherals. macOS
asks the first time; nothing is sent anywhere.

## Administrator password

Not a privacy permission, but asked for in two places:

- **Fan control** installs its privileged helper once.
- **Keep awake** installs, if you choose, a rule in
  `/etc/sudoers.d/brim-clamshell` that lets closed-lid mode run
  `pmset disablesleep` without asking each time. Settings removes it again.

## Resetting

Settings › Advanced resets every permission Brim was granted, its login item
and the closed-lid rule. From Terminal:

```sh
tccutil reset All com.roblesconsulting.brim        # the release app
tccutil reset All com.roblesconsulting.brim.dev    # the Developer app
```

Reset when System Settings shows a permission as granted but Brim disagrees:
that happens when the grant went to a build signed by another identity.
