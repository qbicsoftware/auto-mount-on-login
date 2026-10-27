# auto-mount-on-login

Re-attach the SMB share and the Time Machine image on a schedule, so backups do
not stop when the network drops or when the Mac is locked instead of logged out.

## What it does

Every minute the LaunchAgent runs `mount-time-machine.sh`. The script does
nothing unless **both** of these are true:

1. the Time Machine volume (`TM_VOLUME`) is **not** mounted, and
2. the Mac has an IPv4 address inside `SUBNET` (default `134.2.0.0/16`, i.e.
   `134.2.x.x`).

When both hold, it:

1. mounts the SMB share (`SMB_SERVER`/`SMB_SHARE`, by default
   `smb://workgroup-storage.qbic.uni-tuebingen.de/<SMB_USER>`), ejecting and
   remounting it first if an existing mount cannot be listed (stale after
   sleep or a dropped connection),
2. looks for the Time Machine image inside that share, and
3. attaches the image.

| Image type | Attached with |
| --- | --- |
| `.asif` (Apple Sparse Image Format, macOS 26+) | `diskutil image attach` |
| `.dmg`, `.sparseimage`, `.sparsebundle` | `hdiutil attach` |

Images are searched in the root of the share and one directory below, which
covers the usual layout `smb://host/<user-id>` with the image in the
`<user-id>` folder. If more than one image is found, set `IMAGE_NAME` to pick
one.

An already mounted volume is left alone, so the script is a no-op in steady
state and does not write to the log every minute.

## Credentials

Both the share and the image are usually password protected. The script never
puts a password on a command line; credentials live in the login keychain and
macOS shows its own dialogs when something is missing.

- **SMB share** – mounting uses `mount volume`, so macOS takes the password
  from the login keychain. If none is stored, macOS shows its own "connect to
  server" dialog; tick **Remember this password in my keychain** so later runs
  are unattended. Once the keychain entry exists, no dialog appears.
- **Disk image** – store the image passphrase in the login keychain once (run
  this as yourself, not with `sudo`, so the item ends up in *your* login
  keychain):

  ```bash
  SMB_USER=ab1234 ./mount-time-machine.sh --store-image-password
  # or with an explicit account: ./mount-time-machine.sh --store-image-password ab1234
  ```

  The script reads it with `security` and feeds it to
  `diskutil image --stdinpassphrase` (ASIF) or `hdiutil attach -stdinpass`
  (other formats), so it never appears in `ps`.

  If no passphrase is stored, the script opens the image with `open`, which
  hands it to DiskImageMounter and makes macOS show its normal password dialog.
  From `launchd` that dialog stays open until answered; a lock keeps the next
  run from stacking another dialog on top of it.

If you previously mounted the image by hand and ticked "Remember password in my
keychain" there, DiskImageMounter can reuse that entry too; the
`--store-image-password` helper is the deterministic option for the agent.

## Configuration

All configuration is done through environment variables, which the LaunchAgent
sets in its `EnvironmentVariables` dictionary.

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `TM_VOLUME` | yes | – | Mounted Time Machine volume name, e.g. `Time Machine` |
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

## Install

### Quick install

The installer asks for the settings below, downloads `mount-time-machine.sh`
and the LaunchAgent from this repository, installs both and loads the agent:

```bash
curl -fsSL https://raw.githubusercontent.com/qbicsoftware/auto-mount-on-login/main/install.sh | bash
```

It prompts for:

| Prompt | Default |
| --- | --- |
| Time Machine volume name (as it appears in `/Volumes` once the image is attached) | – |
| SMB user id | – |
| SMB server URL | `smb://workgroup-storage.qbic.uni-tuebingen.de` |
| SMB share name | the SMB user id |
| Allowed subnet (CIDR) | `134.2.0.0/16` |
| Image file name (optional, empty = auto-detect) | empty |

The volume name is the name Finder and Disk Utility show for the attached
backup image — **not** the image file name (you are asked for that separately).
The volume does not need to be mounted while installing, so the installer only
lists the currently mounted volumes as a hint. If you do not know the name yet,
mount the image once by hand, run `ls /Volumes`, and re-run the installer with
the name that appeared.

Then it prints a summary, asks for confirmation, verifies the downloaded
files, installs the script and the two `*-autobackup` helpers to
`/usr/local/bin` (using `sudo` only if needed) and the LaunchAgent to
`~/Library/LaunchAgents`, optionally stores the image passphrase in your login
keychain, and runs `launchctl bootout` / `launchctl bootstrap`. Re-running it
upgrades an existing installation.

Options (pass them after `-s --`):

```bash
curl -fsSL https://raw.githubusercontent.com/qbicsoftware/auto-mount-on-login/main/install.sh | bash -s -- --dry-run
```

| Option | Meaning |
| --- | --- |
| `--ref REF` | Branch, tag or commit to download from (default `main`) |
| `--repo OWNER/REPO` | Repository to download from (default `qbicsoftware/auto-mount-on-login`) |
| `--dry-run` | Validate and print the steps without changing anything |
| `--yes`, `-y` | Skip the final confirmation (the optional passphrase question is still asked) |
| `--help`, `-h` | Show usage |

Every prompt can be answered in advance through the environment variables from
the [configuration table](#configuration) (`TM_VOLUME`, `SMB_USER`,
`SMB_SERVER`, `SMB_SHARE`, `SUBNET`, `IMAGE_NAME`). Together with `--yes` this
gives an unattended install:

```bash
curl -fsSL https://raw.githubusercontent.com/qbicsoftware/auto-mount-on-login/main/install.sh |
  TM_VOLUME="Time Machine" SMB_USER=ab1234 bash -s -- --yes
```

The installer refuses to run as `root` and only works on macOS (`--dry-run` is
allowed anywhere). Because `curl | bash` executes whatever the server sends,
read the script first if you prefer:

```bash
curl -fsSL https://raw.githubusercontent.com/qbicsoftware/auto-mount-on-login/main/install.sh | less
```

While a change to the installer is under review, point `--ref` at its branch
(`--ref feature/curl-installer`); the script and the plist are always fetched
from the same ref.

### Manual install

```bash
git clone https://github.com/qbicsoftware/auto-mount-on-login.git
cd auto-mount-on-login

# 1. configure
$EDITOR org.kochtobi.mount-time-machine.plist   # replace the REPLACE_WITH_* values
plutil -lint org.kochtobi.mount-time-machine.plist

# 2. install
sudo mkdir -p /usr/local/bin
sudo install -m 755 mount-time-machine.sh start-autobackup stop-autobackup /usr/local/bin/
install -m 644 org.kochtobi.mount-time-machine.plist ~/Library/LaunchAgents/

# 3. (re)load the agent
launchctl bootout gui/$(id -u)/org.kochtobi.mount-time-machine 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.kochtobi.mount-time-machine.plist
```

Try it once without waiting for the timer:

```bash
TM_VOLUME="Time Machine" SMB_USER="ab1234" /usr/local/bin/mount-time-machine.sh
```

The first run may show Apple's password dialogs for the share and/or the image.
Answer them and tick "Remember this password in my keychain" for the share.

## Verify

```bash
launchctl print gui/$(id -u)/org.kochtobi.mount-time-machine | grep -E 'state|last exit'
tail -f ~/Library/Logs/auto-mount-on-login.log
```

`state = not running` between intervals is normal, as is an empty log when the
volume is already mounted or the Mac is outside `SUBNET`.

## Pause and resume backups

Two helpers are installed next to `mount-time-machine.sh`:

```bash
stop-autobackup     # disable the agent and automatic backups
start-autobackup    # enable both again
```

`stop-autobackup`:

1. unloads the LaunchAgent and disables it, so it does not start again at the
   next login (a plain `launchctl bootout` would only last until then),
2. cancels a backup that is currently running,
3. runs `sudo tmutil disable` to switch "Back Up Automatically" off,
4. ejects the Time Machine volume as well if you pass `--unmount`.

`start-autobackup` re-enables the agent, loads it (or restarts it if it is
already loaded) so the share is mounted immediately when the Mac is inside
`SUBNET`, and runs `sudo tmutil enable`.

Run both as **yourself**, not with `sudo`; they call `sudo` only for `tmutil`.
`tmutil` requires Full Disk Access for the terminal you run them in
(System Settings → Privacy & Security → Full Disk Access). `--dry-run` prints
the commands without changing anything.

Without the helpers, the same steps are:

```bash
# pause
launchctl bootout gui/$(id -u)/org.kochtobi.mount-time-machine
launchctl disable gui/$(id -u)/org.kochtobi.mount-time-machine
sudo tmutil stopbackup   # if a backup is running
sudo tmutil disable

# resume
launchctl enable gui/$(id -u)/org.kochtobi.mount-time-machine
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.kochtobi.mount-time-machine.plist
sudo tmutil enable
```

Pausing is not the same as [uninstalling](#uninstall): the agent, the scripts
and (optionally) the keychain entry stay in place, so `start-autobackup` can
restore everything.

## Troubleshooting

- **Nothing happens.** Either you are outside `SUBNET`, or `TM_VOLUME` does not
  match the mounted volume name exactly (check `ls /Volumes` and
  `diskutil info /Volumes/...`).
- **The volume name is unknown.** It only exists while the image is attached,
  so mount it once by hand, compare `ls /Volumes` with the name Finder shows,
  and correct `TM_VOLUME` (re-run the installer or edit the plist). Matching is
  exact and case-sensitive.
- **The image password dialog appears every time.** The passphrase is not in
  the keychain, or it is stored under a different account. Run
  `--store-image-password` with the same `SMB_USER`/`IMAGE_KEYCHAIN_ACCOUNT`
  as the LaunchAgent.
- **The share password is requested every time.** Re-mount the share once and
  tick "Remember this password in my keychain", or add the item in Keychain
  Access (kind: "Internet password", server: the SMB host, account: `SMB_USER`).
- **Keychain access prompt ("security wants to access ...")** appears on the
  first unattended run. Allow it once; choose "Always Allow" so the agent can
  read the image passphrase later.
- **ASIF image does not attach.** `.asif` needs macOS 26 or later; on older
  versions `diskutil image` does not exist and `hdiutil` cannot read ASIF.
- **"more than one image found".** Set `IMAGE_NAME` to the file name.
- **No image found although one exists.** Check the `contents of ...` lines the
  log now prints: `._time-machine.asif` is SMB metadata for
  `time-machine.asif`, not a second image, and is ignored. If the listing is
  empty or `ls` reports an error, the mount is stale; the script ejects it and
  mounts the share again once. As a shortcut, name the image explicitly by
  adding `IMAGE_NAME` to the plist (or set it in the environment when running
  the script by hand).
- **Logs.** `~/Library/Logs/auto-mount-on-login.log`; the previous file is kept
  as `.log.1` after rotation.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/org.kochtobi.mount-time-machine
launchctl disable gui/$(id -u)/org.kochtobi.mount-time-machine 2>/dev/null || true
rm ~/Library/LaunchAgents/org.kochtobi.mount-time-machine.plist
sudo rm /usr/local/bin/mount-time-machine.sh \
        /usr/local/bin/start-autobackup \
        /usr/local/bin/stop-autobackup
```

This removes the agent only. If you previously ran `stop-autobackup`, automatic
backups stay off until you run `sudo tmutil enable` (or tick "Back Up
Automatically" in System Settings → General → Time Machine).

Optionally delete the stored image passphrase:

```bash
security delete-generic-password -s auto-mount-on-login -a ab1234
```

## License

MIT, see [LICENSE](LICENSE).
