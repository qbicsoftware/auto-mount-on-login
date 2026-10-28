# auto-mount-on-login

Re-attach the SMB share and the Time Machine image on a schedule, so backups do
not stop when the network drops or the Mac is locked rather than logged out.

## Quick start

On the Mac you want to back up:

```bash
curl -fsSL https://raw.githubusercontent.com/qbicsoftware/auto-mount-on-login/main/install.sh | bash
```

The installer asks for the settings in [Configuration](#configuration). To skip
the questions, set them up front:

```bash
curl -fsSL https://raw.githubusercontent.com/qbicsoftware/auto-mount-on-login/main/install.sh |
  SMB_USER=ab1234 bash -s -- --yes
```

`TM_VOLUME` can be added to that line (`TM_VOLUME="time-machine"`) if you already
know the name; otherwise the first successful mount detects it.

Then:

1. **Allow the one-time permission.** The first run triggers macOS' consent
   dialog ("MountTimeMachine would like to access files on a network volume") —
   click **Allow**. Trigger it now with
   `launchctl kickstart -k gui/$(id -u)/org.kochtobi.mount-time-machine`; see
   [Network volume permission](#network-volume-permission).
2. **Watch it work:**
   `tail -f ~/Library/Logs/auto-mount-on-login.log` (and
   `launchctl print gui/$(id -u)/org.kochtobi.mount-time-machine`).
3. **Pause, resume or remove** with `stop-autobackup`, `start-autobackup`,
   `uninstall-autobackup` — see [Managing the agent](#managing-the-agent).

## How it works

Every minute the LaunchAgent runs `mount-time-machine.sh`, which acts only when
**both**:

1. the Time Machine volume (`TM_VOLUME`, when set) is **not** mounted, and
2. the Mac has an IPv4 address inside `SUBNET` (default `134.2.0.0/16`).

Otherwise it exits quietly, so a mounted volume does not grow the log. When it
does act, it mounts the share (default
`smb://workgroup-storage.qbic.uni-tuebingen.de/<SMB_USER>`), looks for the image
in the share root or one level below, and attaches it:

| Image type | Attached with |
| --- | --- |
| `.asif` (macOS 26+) | `diskutil image attach` |
| `.dmg`, `.sparseimage`, `.sparsebundle` | `hdiutil attach` |

A stale mount (after sleep or a dropped connection) is ejected and remounted
first; a *permission* error is reported instead, since the mount itself is fine.
If several images are found, set `IMAGE_NAME`.

The name a disk image mounts as comes from the image, not from a setting. After
a successful attach the script reads the mount point from the attach command's
own output (`hdiutil` reports it; for the asynchronous `open` fallback it diffs
`/Volumes` around the attach) and remembers the name in
`~/Library/Application Support/auto-mount-on-login/volume`. Later runs use that
name for the first check, so `TM_VOLUME` does not have to be known at install
time.

## Configuration

All settings are environment variables, written by the installer into the
LaunchAgent's `EnvironmentVariables` dictionary:

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `TM_VOLUME` | no | detected | Expected mounted volume name, e.g. `Time Machine`; learned on the first successful mount when unset |
| `SMB_USER` | yes | – | Your user id on the SMB server |
| `SMB_SERVER` | no | `smb://workgroup-storage.qbic.uni-tuebingen.de` | Base SMB URL |
| `SMB_SHARE` | no | `SMB_USER` | Share name appended to `SMB_SERVER` |
| `SUBNET` | no | `134.2.0.0/16` | CIDR block in which the script may run |
| `IMAGE_NAME` | no | – | Exact image file name (needed only if there are several) |
| `IMAGE_KEYCHAIN_SERVICE` | no | `auto-mount-on-login` | Keychain service for the image passphrase |
| `IMAGE_KEYCHAIN_ACCOUNT` | no | `SMB_USER` | Keychain account for the image passphrase |
| `LOG_FILE` | no | `~/Library/Logs/auto-mount-on-login.log` | Log file, rotated at 1 MB |
| `MOUNT_TIMEOUT` | no | `45` | Seconds to wait for a mount to appear |
| `PROMPT_TIMEOUT` | no | `300` | Seconds to wait after a password dialog |

`TM_VOLUME` is the name in `/Volumes` once the image is attached (as Finder and
Disk Utility show it), **not** the image file name. It is optional: without it,
the first successful attach learns the name and stores it in
`~/Library/Application Support/auto-mount-on-login/volume`, and later runs use
that. Set it only if you want the script to prefer a particular name; a mismatch
is logged and the volume that actually appeared is used. To look the name up by
hand, mount the image once and run `ls /Volumes`.

The app wrapper cannot read the plist, so the installer writes the same settings
to `~/.config/auto-mount-on-login/config.env`, which the wrapper sources. Edit
that file to change a setting without reinstalling; the helpers still read the
plist, so the installer keeps both in sync.

## Credentials

Passwords never appear on a command line. They live in the login keychain and
macOS shows its own dialogs when something is missing.

- **Share.** Mounting uses `mount volume`, so macOS takes the password from the
  keychain. Tick **Remember this password in my keychain** the first time.
- **Image.** Store the passphrase once (run this as yourself, not with `sudo`, so
  it lands in *your* login keychain):

  ```bash
  SMB_USER=ab1234 ./mount-time-machine.sh --store-image-password
  ```

  The script feeds it to `diskutil image --stdinpassphrase` (ASIF) or
  `hdiutil attach -stdinpass` (other formats), so it never shows up in `ps`.
  Without a stored passphrase it opens the image and macOS asks; a lock keeps
  dialogs from stacking.

## Install

`install.sh` downloads the script, helpers, wrapper app and LaunchAgent from the
same repo/ref, installs them and loads the agent. Re-running upgrades in place.
It refuses to run as root and only works on macOS (`--dry-run` works anywhere).
Pass options after `-s --`, e.g. `... | bash -s -- --dry-run`.

| Option | Meaning |
| --- | --- |
| `--ref REF` | Branch, tag or commit to download from (default `main`) |
| `--repo OWNER/REPO` | Repository to download from (default `qbicsoftware/auto-mount-on-login`) |
| `--no-app` | Skip the app wrapper and run the script directly (needs Full Disk Access; see below) |
| `--dry-run` | Validate and print the steps without changing anything |
| `--yes`, `-y` | Skip the final confirmation |
| `--help`, `-h` | Show usage |

Because `curl | bash` runs whatever the server sends, read it first with
`... | less`.

### Network volume permission

macOS guards files on network volumes (TCC) **per application**, and the consent
dialog can only be shown to a process that has an application identity. A script
run directly by `launchd` has none, so the read is denied with a bare
`Operation not permitted` and the log shows:

```
ERROR: share at /Volumes/<userid> is mounted but cannot be listed: ls: /Volumes/<userid>: Operation not permitted
```

`install.sh` avoids that by running the script as a child of a small app wrapper
(`~/Applications/MountTimeMachine.app`), which gives macOS something to ask
about. If you missed the dialog, enable **MountTimeMachine** by hand under
**System Settings → Privacy & Security → Files and Folders**.

The wrapper is ad-hoc signed: an unsigned applet has no code identity and would
be denied silently. Nothing mutable lives inside it (the script runs from
`/usr/local/bin`, the settings from `~/.config/auto-mount-on-login/config.env`),
so reinstalling keeps the grant; only a change to the wrapper rebuilds and
re-signs it.

**Without the wrapper** (`--no-app`): the script runs directly, so grant **Full
Disk Access** to `/bin/bash` (**System Settings → Privacy & Security → Full Disk
Access → + → Cmd+Shift+G → `/bin/bash`**). Simpler, but the grant covers every
bash script on the Mac, which is why the wrapper is the default.

**Why not root?** A root LaunchDaemon skips these checks, but the login-session
parts would break: the passphrase is in *your* keychain, the share mounts through
*your* Finder session, and root would own the attached image.

### Manual install

```bash
git clone https://github.com/qbicsoftware/auto-mount-on-login.git
cd auto-mount-on-login

$EDITOR org.kochtobi.mount-time-machine.plist   # fill in the REPLACE_WITH_* values
                                                 # (TM_VOLUME may be deleted; the
                                                 # name is then detected on first mount)
plutil -lint org.kochtobi.mount-time-machine.plist

sudo install -m 755 mount-time-machine.sh start-autobackup stop-autobackup \
     uninstall-autobackup /usr/local/bin/
install -m 644 org.kochtobi.mount-time-machine.plist ~/Library/LaunchAgents/

launchctl bootout gui/$(id -u)/org.kochtobi.mount-time-machine 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.kochtobi.mount-time-machine.plist
```

The template points at `/usr/local/bin/mount-time-machine.sh`, so a manual
install runs the script directly and needs [Full Disk Access](#network-volume-permission).
Run it once by hand to answer the password dialogs:

```bash
SMB_USER=ab1234 /usr/local/bin/mount-time-machine.sh
```

Add `TM_VOLUME="Time Machine"` in front of that command if you want to pin the
name; without it the script learns it from the attach.

## Managing the agent

Three helpers in `/usr/local/bin`. Run them as **yourself** — they use `sudo`
only for `tmutil`, which needs Full Disk Access for your terminal:

| Command | Effect |
| --- | --- |
| `stop-autobackup` | unload and disable the agent, turn automatic backups off (`--unmount` also ejects the volume) |
| `start-autobackup` | re-enable the agent, mount now if inside `SUBNET`, turn backups on |
| `uninstall-autobackup` | remove everything (see [Uninstall](#uninstall)) |

`--dry-run` prints the commands without changing anything.

## Troubleshooting

- **Nothing happens.** You are outside `SUBNET`, or the expected volume name does
  not match `ls /Volumes` (exact, case-sensitive). With `TM_VOLUME` unset, the
  learned name lives in `~/Library/Application Support/auto-mount-on-login/volume`;
  delete that file to make the next run detect it again.
- **`Operation not permitted` in the log.** The TCC block — see
  [Network volume permission](#network-volume-permission). The script stops
  instead of remounting, because the mount is fine.
- **Image password asked every time.** Store it with `--store-image-password`
  using the same `SMB_USER`/`IMAGE_KEYCHAIN_ACCOUNT` as the agent, and answer the
  first "security wants to access ..." prompt with **Always Allow**.
- **Share password asked every time.** Re-mount once with "Remember this
  password in my keychain".
- **`.asif` does not attach.** It needs macOS 26+.
- **"more than one image found".** Set `IMAGE_NAME`.
- **No image found.** The `contents of ...` log lines list the directory;
  `._time-machine.asif` is SMB metadata and is ignored.
- **Logs.** `~/Library/Logs/auto-mount-on-login.log` (rotated to `.log.1`).

## Uninstall

```bash
uninstall-autobackup          # removes the agent, app and scripts
uninstall-autobackup --purge  # also the log file and the keychain entry
```

Run it as yourself (sudo only for `/usr/local/bin`). Automatic backups are left
as they are. To drop the privacy grant too, remove **MountTimeMachine** under
**System Settings → Privacy & Security → Files and Folders**.

## License

MIT, see [LICENSE](LICENSE).
