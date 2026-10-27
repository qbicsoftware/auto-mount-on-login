#!/usr/bin/env bash
#
# auto-mount-on-login installer
#
#   curl -fsSL https://raw.githubusercontent.com/qbicsoftware/auto-mount-on-login/main/install.sh | bash
#
# The installer asks for the settings that mount-time-machine.sh needs, then
# downloads the script and the LaunchAgent template from the same repo/ref,
# installs both and loads the agent. Run with --help for options.
#
# The script is meant to be piped into bash, so stdin is the script itself.
# All prompts therefore read from /dev/tty.

set -euo pipefail

PROG=${0##*/}
case $PROG in
  bash | sh | dash | zsh) PROG='install.sh' ;;
esac
REPO=${AMOL_REPO:-qbicsoftware/auto-mount-on-login}
REF=${AMOL_REF:-main}

LABEL='org.kochtobi.mount-time-machine'
SCRIPT_NAME='mount-time-machine.sh'
PLIST_NAME='org.kochtobi.mount-time-machine.plist'
APPLESCRIPT_NAME='mount-time-machine.applescript'
INFO_PLIST_NAME='MountTimeMachine-Info.plist'
HELPERS=(start-autobackup stop-autobackup)
BIN_DST="/usr/local/bin/$SCRIPT_NAME"
BIN_DIR=${BIN_DST%/*}
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST_DST="$AGENT_DIR/$PLIST_NAME"
LOG_DIR="$HOME/Library/Logs"

# The wrapper app gives the LaunchAgent a TCC application identity so macOS can
# ask for "Network Volumes" consent. See README, "Network volume permission".
APP_DIR="$HOME/Applications/MountTimeMachine.app"
APP_EXEC="$APP_DIR/Contents/MacOS/applet"

DEFAULT_SERVER='smb://workgroup-storage.qbic.uni-tuebingen.de'
DEFAULT_SUBNET='134.2.0.0/16'

DRY_RUN=0
ASSUME_YES=0
USE_APP=1
TTY_AVAILABLE=0
TMP_DIR=''

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $PROG [options]

Installs mount-time-machine.sh and its LaunchAgent for the current user.
Usually run as:

  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash

Options:
  --ref REF        Git ref (branch, tag or commit) to download from [$REF]
  --repo OWNER/REPO
                   Repository to download from [$REPO]
  --no-app         Do not build the MountTimeMachine.app wrapper; run the
                   script directly (then grant /bin/bash Full Disk Access)
  --dry-run        Validate everything and print the planned steps, change nothing
  --yes, -y        Do not ask for confirmation at the end
  --help, -h       Show this help

Environment variables (used instead of prompting when set):
  TM_VOLUME, SMB_USER, SMB_SERVER, SMB_SHARE, SUBNET, IMAGE_NAME
EOF
}

cleanup() {
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
    rm -rf "$TMP_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Prompts (stdin is the piped script, so read from /dev/tty)
# ---------------------------------------------------------------------------

open_tty() {
  if { exec 3<>/dev/tty; } 2>/dev/null; then
    TTY_AVAILABLE=1
  fi
}

# ask PROMPT [DEFAULT] -> prints the answer
ask() {
  local prompt=$1 default=${2:-} answer=''

  if (( ! TTY_AVAILABLE )); then
    printf '%s' "$default"
    return 0
  fi

  if [[ -n $default ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi

  IFS= read -r answer <&3 || answer=''
  # trim surrounding whitespace so a stray space does not become part of a name
  answer=${answer#"${answer%%[![:space:]]*}"}
  answer=${answer%"${answer##*[![:space:]]}"}
  printf '%s' "${answer:-$default}"
}

# ask_until_valid PROMPT DEFAULT VALIDATOR -> prints a value that passes
ask_until_valid() {
  local prompt=$1 default=$2 validator=$3 value

  while :; do
    value=$(ask "$prompt" "$default")
    if "$validator" "$value"; then
      printf '%s' "$value"
      return 0
    fi
    if (( ! TTY_AVAILABLE )); then
      die "invalid value: '$value'"
    fi
    warn "invalid value: '$value'"
  done
}

confirm() {
  local prompt=$1 default=${2:-n} answer
  if (( ! TTY_AVAILABLE )); then
    [[ $default == [yY]* ]]
    return
  fi
  answer=$(ask "$prompt" "$default")
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

# Only used for the final "install now?" question, so that --yes cannot
# answer optional questions such as the passphrase prompt.
confirm_install() {
  (( ASSUME_YES )) && return 0
  confirm "$@"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

valid_component() {
  [[ -n $1 && $1 != */* ]]
}

valid_smb_url() {
  [[ $1 =~ ^smb://[^/]+/?$ ]]
}

valid_subnet() {
  local cidr=$1 network prefix octet
  [[ $cidr =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || return 1

  network=${cidr%/*}
  prefix=${cidr#*/}
  (( prefix <= 32 )) || return 1

  local IFS=.
  # shellcheck disable=SC2086
  set -- $network
  for octet in "$@"; do
    (( octet <= 255 )) || return 1
  done
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

explain_volume_name() {
  local volume found=0
  for volume in /Volumes/*; do
    [[ -e $volume ]] || continue
    if (( ! found )); then
      info "Mounted right now (only a hint - the backup is usually not attached):"
    fi
    found=1
    info "  ${volume##*/}"
  done
  if (( ! found )); then
    info "Nothing is mounted under /Volumes right now. That is normal: the backup"
    info "image is only attached on the university network."
  fi
  info ""
  info "Enter the name the Time Machine volume gets in /Volumes once the image is"
  info "attached - Finder and Disk Utility show the same name. This is the volume"
  info "name, not the image file name (you are asked for that later)."
  info ""
}

# Warn once, after all questions, if the volume does not exist yet. This is the
# normal case while the image is not attached, so it is a hint, not an error.
check_volume_presence() {
  local volume="/Volumes/$TM_VOLUME"
  if [[ -d $volume ]]; then
    return 0
  fi
  info "Note: $volume does not exist yet. That is expected while the backup image"
  info "is not attached. If the agent later fails to find the volume, mount the"
  info "image once by hand, compare with the name Finder shows, and re-run this"
  info "installer with the corrected name."
}

collect_config() {
  TM_VOLUME=${TM_VOLUME:-}
  SMB_USER=${SMB_USER:-}
  SMB_SERVER=${SMB_SERVER:-}
  SMB_SHARE=${SMB_SHARE:-}
  SUBNET=${SUBNET:-}
  IMAGE_NAME=${IMAGE_NAME:-}

  if [[ -z $TM_VOLUME ]]; then
    if (( ! TTY_AVAILABLE )); then
      die "TM_VOLUME is not set and no terminal is available for prompts"
    fi
    explain_volume_name
    TM_VOLUME=$(ask_until_valid "Time Machine volume name (as it appears in /Volumes)" "" valid_component)
  elif ! valid_component "$TM_VOLUME"; then
    die "TM_VOLUME must be a volume name without '/' (got '$TM_VOLUME')"
  fi

  if [[ -z $SMB_USER ]]; then
    if (( ! TTY_AVAILABLE )); then
      die "SMB_USER is not set and no terminal is available for prompts"
    fi
    SMB_USER=$(ask_until_valid "SMB user id" "" valid_component)
  elif ! valid_component "$SMB_USER"; then
    die "SMB_USER must not contain '/' (got '$SMB_USER')"
  fi

  if [[ -z $SMB_SERVER ]]; then
    SMB_SERVER=$(ask_until_valid "SMB server URL" "$DEFAULT_SERVER" valid_smb_url)
  elif ! valid_smb_url "$SMB_SERVER"; then
    die "SMB_SERVER must look like smb://host (got '$SMB_SERVER')"
  fi

  if [[ -z $SMB_SHARE ]]; then
    SMB_SHARE=$(ask_until_valid "SMB share name" "$SMB_USER" valid_component)
  elif ! valid_component "$SMB_SHARE"; then
    die "SMB_SHARE must not contain '/' (got '$SMB_SHARE')"
  fi

  if [[ -z $SUBNET ]]; then
    SUBNET=$(ask_until_valid "Allowed subnet (CIDR)" "$DEFAULT_SUBNET" valid_subnet)
  elif ! valid_subnet "$SUBNET"; then
    die "SUBNET must be a CIDR block such as 134.2.0.0/16 (got '$SUBNET')"
  fi

  if [[ -z $IMAGE_NAME ]]; then
    IMAGE_NAME=$(ask "Image file name inside the share (optional, empty = auto-detect)" "")
  fi
  if [[ -n $IMAGE_NAME ]] && ! valid_component "$IMAGE_NAME"; then
    die "IMAGE_NAME must be a plain file name (got '$IMAGE_NAME')"
  fi

  check_volume_presence
}

show_summary() {
  local volume_note=''
  if [[ ! -d /Volumes/$TM_VOLUME ]]; then
    volume_note=' (not mounted right now)'
  fi
  info ""
  info "Configuration:"
  info "  Time Machine volume : $TM_VOLUME$volume_note"
  info "  SMB URL             : ${SMB_SERVER%/}/$SMB_SHARE"
  info "  SMB user            : $SMB_USER"
  info "  Allowed subnet      : $SUBNET"
  if [[ -n $IMAGE_NAME ]]; then
    info "  Image               : $IMAGE_NAME"
  else
    info "  Image               : auto-detect in the share"
  fi
  info ""
  info "Will install:"
  info "  script : $BIN_DST"
  info "  helper : $BIN_DIR/${HELPERS[0]}"
  info "  helper : $BIN_DIR/${HELPERS[1]}"
  if (( USE_APP )); then
    info "  app    : $APP_DIR   (for Network Volumes consent)"
  else
    info "  wrapper: none (runs the script directly; needs Full Disk Access)"
  fi
  info "  agent  : $PLIST_DST"
  if (( DRY_RUN )); then
    info ""
    info "Dry run: nothing will be changed."
  fi
  info ""
}

# ---------------------------------------------------------------------------
# Download and install
# ---------------------------------------------------------------------------

fetch() {
  local path=$1 dest=$2 url
  url="https://raw.githubusercontent.com/$REPO/$REF/$path"
  info "downloading $url"
  if ! curl -fsSL "$url" -o "$dest"; then
    die "could not download $url"
  fi
}

fetch_files() {
  local helper
  fetch "$SCRIPT_NAME" "$TMP_DIR/$SCRIPT_NAME"
  fetch "$PLIST_NAME" "$TMP_DIR/$PLIST_NAME"

  if ! bash -n "$TMP_DIR/$SCRIPT_NAME"; then
    die "downloaded script has a syntax error"
  fi
  if ! grep -q 'auto-mount-on-login' "$TMP_DIR/$SCRIPT_NAME"; then
    die "downloaded file does not look like $SCRIPT_NAME"
  fi
  if ! plutil -lint "$TMP_DIR/$PLIST_NAME" >/dev/null 2>&1; then
    die "downloaded LaunchAgent is not a valid plist"
  fi

  for helper in "${HELPERS[@]}"; do
    fetch "$helper" "$TMP_DIR/$helper"
    if ! bash -n "$TMP_DIR/$helper"; then
      die "downloaded $helper has a syntax error"
    fi
    if ! grep -q 'auto-mount-on-login' "$TMP_DIR/$helper"; then
      die "downloaded file does not look like $helper"
    fi
  done

  if (( USE_APP )); then
    fetch "$APPLESCRIPT_NAME" "$TMP_DIR/$APPLESCRIPT_NAME"
    fetch "$INFO_PLIST_NAME" "$TMP_DIR/$INFO_PLIST_NAME"
    if ! grep -q 'MountTimeMachine' "$TMP_DIR/$APPLESCRIPT_NAME"; then
      die "downloaded $APPLESCRIPT_NAME does not look like the wrapper"
    fi
    if ! plutil -lint "$TMP_DIR/$INFO_PLIST_NAME" >/dev/null 2>&1; then
      die "downloaded $INFO_PLIST_NAME is not a valid plist"
    fi
    if command -v osacompile >/dev/null 2>&1; then
      if ! osacompile -o "$TMP_DIR/compile-check.app" "$TMP_DIR/$APPLESCRIPT_NAME" >/dev/null 2>&1; then
        die "the wrapper AppleScript does not compile"
      fi
    elif (( ! DRY_RUN )); then
      die "osacompile is missing; re-run with --no-app or install the Command Line Tools"
    fi
  fi
}

# set_plist KEYPATH VALUE FILE
set_plist() {
  local keypath=$1 value=$2 plist=$3
  if plutil -replace "$keypath" -string "$value" "$plist" 2>/dev/null; then
    return 0
  fi
  plutil -insert "$keypath" -string "$value" "$plist" >/dev/null
}

# set_plist_bool KEYPATH true|false FILE
set_plist_bool() {
  local keypath=$1 value=$2 plist=$3
  if plutil -replace "$keypath" -bool "$value" "$plist" 2>/dev/null; then
    return 0
  fi
  plutil -insert "$keypath" -bool "$value" "$plist" >/dev/null
}

configure_plist() {
  local plist=$TMP_DIR/$PLIST_NAME

  set_plist 'EnvironmentVariables.TM_VOLUME' "$TM_VOLUME" "$plist"
  set_plist 'EnvironmentVariables.SMB_USER' "$SMB_USER" "$plist"
  set_plist 'EnvironmentVariables.SMB_SERVER' "$SMB_SERVER" "$plist"
  set_plist 'EnvironmentVariables.SMB_SHARE' "$SMB_SHARE" "$plist"
  set_plist 'EnvironmentVariables.SUBNET' "$SUBNET" "$plist"
  if [[ -n $IMAGE_NAME ]]; then
    set_plist 'EnvironmentVariables.IMAGE_NAME' "$IMAGE_NAME" "$plist"
  fi

  # Point the job at the wrapper app (or the plain script with --no-app).
  if (( USE_APP )); then
    set_plist 'ProgramArguments.0' "$APP_EXEC" "$plist"
  else
    set_plist 'ProgramArguments.0' "$BIN_DST" "$plist"
  fi
  write_config_env

  if ! plutil -lint "$plist" >/dev/null 2>&1; then
    die "generated LaunchAgent is not a valid plist"
  fi
}

# shell_quote VALUE -> VALUE wrapped in single quotes, safe for `sh -c`.
shell_quote() {
  local value=$1
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

# The wrapper app cannot read the LaunchAgent's EnvironmentVariables: AppleScript
# runs `do shell script` with a fixed minimal environment. So the same settings
# are written to Resources/config.env inside the bundle and sourced there.
write_config_env() {
  local dst=$TMP_DIR/config.env
  {
    printf '# Generated by install.sh - settings for mount-time-machine.sh.\n'
    printf '# Sourced by MountTimeMachine.app; editing it by hand works until the\n'
    printf '# next install.sh run.\n'
    printf 'TM_VOLUME=%s\n' "$(shell_quote "$TM_VOLUME")"
    printf 'SMB_USER=%s\n' "$(shell_quote "$SMB_USER")"
    printf 'SMB_SERVER=%s\n' "$(shell_quote "$SMB_SERVER")"
    printf 'SMB_SHARE=%s\n' "$(shell_quote "$SMB_SHARE")"
    printf 'SUBNET=%s\n' "$(shell_quote "$SUBNET")"
    if [[ -n $IMAGE_NAME ]]; then
      printf 'IMAGE_NAME=%s\n' "$(shell_quote "$IMAGE_NAME")"
    fi
  } >"$dst"
}

install_file() {
  local src=$1 dst=$2 mode=$3 dir
  dir=$(dirname "$dst")

  if (( DRY_RUN )); then
    info "would install $src -> $dst (mode $mode)"
    return 0
  fi

  if [[ ! -d $dir ]]; then
    info "creating $dir (sudo may ask for your password)"
    sudo mkdir -p "$dir"
  fi

  if [[ -w $dir ]]; then
    install -m "$mode" "$src" "$dst"
  else
    info "root is needed to write $dst (sudo may ask for your password)"
    sudo install -m "$mode" "$src" "$dst"
  fi
}

install_files() {
  local helper

  install_file "$TMP_DIR/$SCRIPT_NAME" "$BIN_DST" 755
  for helper in "${HELPERS[@]}"; do
    install_file "$TMP_DIR/$helper" "$BIN_DIR/$helper" 755
  done

  if (( USE_APP )); then
    build_app
  fi

  if (( ! DRY_RUN )); then
    mkdir -p "$AGENT_DIR"
  elif [[ ! -d $AGENT_DIR ]]; then
    info "would create $AGENT_DIR"
  fi
  install_file "$TMP_DIR/$PLIST_NAME" "$PLIST_DST" 644

  if (( ! DRY_RUN )); then
    mkdir -p "$LOG_DIR"
  fi
}

# Build ~/Applications/MountTimeMachine.app around the shell script. It is an
# osacompile applet with the script in its Resources, so the job has an
# application identity and macOS can ask for "Network Volumes" consent.
build_app() {
  local src_script=$TMP_DIR/$SCRIPT_NAME
  local src_config=$TMP_DIR/config.env
  local src_as=$TMP_DIR/$APPLESCRIPT_NAME
  local src_info=$TMP_DIR/$INFO_PLIST_NAME
  local contents="$APP_DIR/Contents"
  local info="$contents/Info.plist"
  local res="$contents/Resources"
  local changed=0 same_as=0

  if (( DRY_RUN )); then
    info "would run: osacompile -o '$APP_DIR' '$src_as'"
    info "would copy $SCRIPT_NAME, config.env and the wrapper source into $res"
    info "would set CFBundleIdentifier and NSNetworkVolumesUsageDescription in $info"
    return 0
  fi

  command -v osacompile >/dev/null 2>&1 ||
    die "osacompile is missing; install the Command Line Tools or re-run with --no-app"

  # TCC keys the "Network Volumes" grant to the bundle, and recompiling the
  # applet changes it (which can reset the grant). So only rewrite what really
  # changed: settings/script are refreshed in place, while a new wrapper source
  # needs a rebuild.
  if [[ -x $APP_EXEC && -f "$res/$SCRIPT_NAME" && -f "$res/config.env" &&
    -f "$res/$APPLESCRIPT_NAME" ]]; then
    cmp -s "$src_script" "$res/$SCRIPT_NAME" || changed=1
    cmp -s "$src_config" "$res/config.env" || changed=1
    cmp -s "$src_as" "$res/$APPLESCRIPT_NAME" && same_as=1

    if (( ! changed && same_as )); then
      info "  $APP_DIR is up to date; keeping it (and its privacy grant)"
      return 0
    fi
    if (( same_as )); then
      # Only settings changed: refresh the resources without recompiling.
      install -m 755 "$src_script" "$res/$SCRIPT_NAME"
      install -m 644 "$src_config" "$res/config.env"
      return 0
    fi
  fi

  mkdir -p "$HOME/Applications"
  # osacompile refuses to write into an existing bundle.
  rm -rf "$APP_DIR"
  if ! osacompile -o "$APP_DIR" "$src_as"; then
    die "could not build $APP_DIR with osacompile"
  fi

  mkdir -p "$res"
  install -m 755 "$src_script" "$res/$SCRIPT_NAME"
  install -m 644 "$src_config" "$res/config.env"
  install -m 644 "$src_as" "$res/$APPLESCRIPT_NAME"

  # Start from the app's own Info.plist and layer our keys on top, so the keys
  # osacompile wrote (CFBundleExecutable, ...) are kept.
  # osacompile does not always write CFBundleIdentifier; add it if missing.
  if ! plutil -replace CFBundleIdentifier -string "$LABEL" "$info" 2>/dev/null; then
    plutil -insert CFBundleIdentifier -string "$LABEL" "$info"
  fi
  set_plist CFBundleName 'MountTimeMachine' "$info"
  set_plist_bool LSUIElement true "$info"
  set_plist_from_file "$src_info" "$info"

  # Nudge LaunchServices so the fresh bundle is known, and the consent dialog
  # is attributed to it rather than to an "unknown" process.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DIR" >/dev/null 2>&1 || true
}

# Copy the string keys of $1 over the same keys in $2.
set_plist_from_file() {
  local src=$1 dst=$2 key value
  for key in CFBundleIdentifier CFBundleName CFBundleDisplayName \
    NSNetworkVolumesUsageDescription CFBundleShortVersionString CFBundleVersion; do
    value=$(plutil -extract "$key" raw -o - "$src" 2>/dev/null) || continue
    if plutil -replace "$key" -string "$value" "$dst" 2>/dev/null; then
      continue
    fi
    plutil -insert "$key" -string "$value" "$dst" >/dev/null
  done
  set_plist_bool LSUIElement true "$dst"
}

load_agent() {
  if (( DRY_RUN )); then
    info "would run: launchctl bootout gui/$(id -u)/$LABEL"
    info "would run: launchctl enable gui/$(id -u)/$LABEL"
    info "would run: launchctl bootstrap gui/$(id -u) $PLIST_DST"
    return 0
  fi

  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  # A previous stop-autobackup may have disabled the service; bootstrap would
  # fail until it is enabled again.
  launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true
  if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"; then
    die "launchctl bootstrap failed; inspect with: launchctl print gui/$(id -u)/$LABEL"
  fi
  if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    warn "agent was bootstrapped but is not visible in launchctl print"
  fi
}

maybe_store_passphrase() {
  if (( ! TTY_AVAILABLE )); then
    return 0
  fi
  if ! confirm "Store the Time Machine image passphrase in the login keychain now?" n; then
    info "Skipped; macOS will show its password dialog when the image is needed."
    return 0
  fi

  if (( DRY_RUN )); then
    info "would run: $SCRIPT_NAME --store-image-password (service auto-mount-on-login, account $SMB_USER)"
    return 0
  fi

  if ! SMB_USER=$SMB_USER bash "$BIN_DST" --store-image-password </dev/tty; then
    warn "the passphrase was not stored; macOS will prompt on the next mount"
  fi
}

print_done() {
  info ""
  if (( DRY_RUN )); then
    info "Dry run complete. Re-run without --dry-run to install."
    return 0
  fi

  info "Installed and loaded $LABEL."
  info ""
  info "The agent runs at login and every 60 seconds, and only mounts the"
  info "share when '$TM_VOLUME' is not mounted and you are inside $SUBNET."
  info ""
  if (( USE_APP )); then
    info "IMPORTANT - one-time permission:"
    info "  1. Run the agent once so macOS asks:"
    info "       launchctl kickstart -k gui/$(id -u)/$LABEL"
    info "  2. Answer 'Allow' when 'MountTimeMachine would like to access files"
    info "     on a network volume' appears (or enable MountTimeMachine under"
    info "     System Settings -> Privacy & Security -> Files and Folders)."
    info "  Until this is granted the log shows 'Operation not permitted' and no"
    info "  backup can run."
    info ""
  else
    info "IMPORTANT - Full Disk Access required:"
    info "  Add /bin/bash under System Settings -> Privacy & Security ->"
    info "  Full Disk Access, or reinstall without --no-app to get a scoped"
    info "  'Network Volumes' prompt instead."
    info ""
  fi
  info "Verify : launchctl print gui/$(id -u)/$LABEL"
  info "Logs   : $LOG_DIR/auto-mount-on-login.log"
  info "Pause  : $BIN_DIR/stop-autobackup   (also turns automatic backups off)"
  info "Resume : $BIN_DIR/start-autobackup"
  info "Uninstall:"
  info "  launchctl bootout gui/$(id -u)/$LABEL"
  info "  rm '$PLIST_DST'"
  info "  sudo rm '$BIN_DST' '$BIN_DIR/${HELPERS[0]}' '$BIN_DIR/${HELPERS[1]}'"
  if (( USE_APP )); then
    info "  rm -rf '$APP_DIR'"
  fi
  info ""
  info "The first mount may show Apple's password dialog for the share or the"
  info "image; tick 'Remember password in my keychain' when offered."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  while (( $# )); do
    case $1 in
      --ref)
        [[ -n ${2:-} ]] || die "--ref needs a value"
        REF=$2
        shift 2
        ;;
      --repo)
        [[ -n ${2:-} ]] || die "--repo needs a value"
        REPO=$2
        shift 2
        ;;
      --no-app)
        USE_APP=0
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -y | --yes)
        ASSUME_YES=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown option: $1"
        ;;
    esac
  done

  [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid --repo '$REPO'"
  [[ -n $REF ]] || die "--ref must not be empty"
  [[ $REF =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid --ref '$REF'"
  command -v curl >/dev/null 2>&1 || die "curl is required"

  # --dry-run is allowed anywhere so the script can be inspected; a real
  # install only makes sense on macOS.
  if (( ! DRY_RUN )) && [[ $(uname -s) != Darwin ]]; then
    die "this installer targets macOS"
  fi
  if (( ! DRY_RUN )) && [[ $EUID -eq 0 ]]; then
    die "run this as your normal user, not with sudo; the installer uses sudo where needed"
  fi

  open_tty

  info "auto-mount-on-login installer"
  info ""

  collect_config
  show_summary
  if ! confirm_install "Proceed with the installation?" y; then
    info "Aborted."
    exit 0
  fi

  TMP_DIR=$(mktemp -d)
  trap cleanup EXIT

  fetch_files
  configure_plist
  install_files
  maybe_store_passphrase
  load_agent
  print_done
}

main "$@"
