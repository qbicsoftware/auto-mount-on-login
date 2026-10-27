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
BIN_DST="/usr/local/bin/$SCRIPT_NAME"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST_DST="$AGENT_DIR/$PLIST_NAME"
LOG_DIR="$HOME/Library/Logs"

DEFAULT_SERVER='smb://workgroup-storage.qbic.uni-tuebingen.de'
DEFAULT_SUBNET='134.2.0.0/16'

DRY_RUN=0
ASSUME_YES=0
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

list_volumes() {
  local volume
  info "Currently mounted volumes:"
  for volume in /Volumes/*; do
    if [[ -e $volume ]]; then
      info "  ${volume##*/}"
    fi
  done
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
    list_volumes
    TM_VOLUME=$(ask_until_valid "Time Machine volume name (see list above)" "" valid_component)
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
}

show_summary() {
  info ""
  info "Configuration:"
  info "  Time Machine volume : $TM_VOLUME"
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
}

# set_plist KEYPATH VALUE FILE
set_plist() {
  local keypath=$1 value=$2 plist=$3
  if plutil -replace "$keypath" -string "$value" "$plist" 2>/dev/null; then
    return 0
  fi
  plutil -insert "$keypath" -string "$value" "$plist" >/dev/null
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

  if ! plutil -lint "$plist" >/dev/null 2>&1; then
    die "generated LaunchAgent is not a valid plist"
  fi
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
  install_file "$TMP_DIR/$SCRIPT_NAME" "$BIN_DST" 755

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

load_agent() {
  if (( DRY_RUN )); then
    info "would run: launchctl bootout gui/$(id -u)/$LABEL"
    info "would run: launchctl bootstrap gui/$(id -u) $PLIST_DST"
    return 0
  fi

  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
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
  info "Verify : launchctl print gui/$(id -u)/$LABEL"
  info "Logs   : $LOG_DIR/auto-mount-on-login.log"
  info "Uninstall:"
  info "  launchctl bootout gui/$(id -u)/$LABEL"
  info "  rm '$PLIST_DST'"
  info "  sudo rm '$BIN_DST'"
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
