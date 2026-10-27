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
   `smb://workgroup-storage.qbic.uni-tuebingen.de/<SMB_USER>`),
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

```bash
git clone https://github.com/qbicsoftware/auto-mount-on-login.git
cd auto-mount-on-login

# 1. configure
$EDITOR org.kochtobi.mount-time-machine.plist   # replace the REPLACE_WITH_* values
plutil -lint org.kochtobi.mount-time-machine.plist

# 2. install
sudo mkdir -p /usr/local/bin
sudo install -m 755 mount-time-machine.sh /usr/local/bin/mount-time-machine.sh
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

## Troubleshooting

- **Nothing happens.** Either you are outside `SUBNET`, or `TM_VOLUME` does not
  match the mounted volume name exactly (check `ls /Volumes` and
  `diskutil info /Volumes/...`).
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
- **Logs.** `~/Library/Logs/auto-mount-on-login.log`; the previous file is kept
  as `.log.1` after rotation.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/org.kochtobi.mount-time-machine
rm ~/Library/LaunchAgents/org.kochtobi.mount-time-machine.plist
sudo rm /usr/local/bin/mount-time-machine.sh
```

Optionally delete the stored image passphrase:

```bash
security delete-generic-password -s auto-mount-on-login -a ab1234
```

## License

MIT, see [LICENSE](LICENSE).
