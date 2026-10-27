#!/usr/bin/env bash
#
# auto-mount-on-login
#
# Mount the SMB share that holds the Time Machine image and attach that image,
# but only when
#   1. the Time Machine volume is not mounted, and
#   2. this Mac currently has an address in the configured subnet.
#
# Designed to be run every minute by the LaunchAgent in this repository.
# Configuration is taken from the environment; see README.md.
#
# Credentials:
#   - The SMB share is mounted through `osascript`/`mount volume`, so macOS
#     uses the "Internet password" from the login keychain and shows its own
#     authentication dialog when no password is stored yet.
#   - The image passphrase is read from the login keychain when it has been
#     stored with `--store-image-password`. Otherwise the image is opened via
#     `open`, which lets macOS (DiskImageMounter) show its password dialog.

set -euo pipefail

PROG=$(basename "$0")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TM_VOLUME=${TM_VOLUME:-}                              # required: volume name
SMB_USER=${SMB_USER:-}                                # required: SMB user id
SMB_SERVER=${SMB_SERVER:-smb://workgroup-storage.qbic.uni-tuebingen.de}
SMB_SHARE=${SMB_SHARE:-$SMB_USER}                     # defaults to the user id
SUBNET=${SUBNET:-134.2.0.0/16}                        # 134.2.x.x
IMAGE_NAME=${IMAGE_NAME:-}                            # optional, exact file name

# Where the image passphrase lives in the login keychain.
IMAGE_KEYCHAIN_SERVICE=${IMAGE_KEYCHAIN_SERVICE:-auto-mount-on-login}
IMAGE_KEYCHAIN_ACCOUNT=${IMAGE_KEYCHAIN_ACCOUNT:-$SMB_USER}

LOG_FILE=${LOG_FILE:-${HOME:-/tmp}/Library/Logs/auto-mount-on-login.log}
MOUNT_TIMEOUT=${MOUNT_TIMEOUT:-45}                    # seconds
PROMPT_TIMEOUT=${PROMPT_TIMEOUT:-300}                 # seconds, for GUI prompts

TMP_BASE=${TMPDIR:-/tmp}
LOCK_DIR="${TMP_BASE%/}/auto-mount-on-login.$(id -u).lock"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_write_log() {
  local line
  line="$(date +'%Y-%m-%d %T') $*"
  printf '%s\n' "$line"
  if [[ -n $LOG_FILE ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

log() { _write_log "$*"; }
warn() { _write_log "ERROR: $*" >&2; }
die() { warn "$*"; exit 1; }

rotate_log() {
  if [[ ! -f $LOG_FILE ]]; then
    return 0
  fi
  local size
  size=$(wc -c <"$LOG_FILE" 2>/dev/null || printf 0)
  if (( size > 1048576 )); then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $PROG [--help | --store-image-password]

Without arguments the script checks the subnet and mounts the Time Machine
volume if needed. It is meant to be run by the LaunchAgent.

  --store-image-password [ACCOUNT]
      Store the image passphrase in the login keychain (account defaults to
      IMAGE_KEYCHAIN_ACCOUNT or SMB_USER). Without a stored passphrase the
      script falls back to Apple's password dialog.

Environment variables:

  TM_VOLUME               name of the Time Machine volume (required)
  SMB_USER                user id on the SMB server (required)
  SMB_SERVER              server URL (default: $SMB_SERVER)
  SMB_SHARE               share name (default: SMB_USER)
  SUBNET                  allowed CIDR subnet (default: $SUBNET)
  IMAGE_NAME              exact image file name inside the share (optional)
  IMAGE_KEYCHAIN_SERVICE  keychain service name (default: $IMAGE_KEYCHAIN_SERVICE)
  IMAGE_KEYCHAIN_ACCOUNT  keychain account (default: SMB_USER)
  LOG_FILE                log file (default: ~/Library/Logs/auto-mount-on-login.log)
  MOUNT_TIMEOUT           seconds to wait for mounts (default: $MOUNT_TIMEOUT)
  PROMPT_TIMEOUT          seconds to wait after a password dialog (default: $PROMPT_TIMEOUT)
EOF
}

# ---------------------------------------------------------------------------
# Lock: never let two runs stack up (and stack password dialogs)
# ---------------------------------------------------------------------------

release_lock() {
  if [[ -d $LOCK_DIR ]]; then
    rm -rf "$LOCK_DIR"
  fi
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    trap release_lock EXIT
    return 0
  fi

  local pid=''
  if [[ -r $LOCK_DIR/pid ]]; then
    pid=$(<"$LOCK_DIR/pid")
  fi
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    log "previous run (pid $pid) is still busy, skipping this interval"
    exit 0
  fi

  warn "removing stale lock $LOCK_DIR"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  trap release_lock EXIT
}

# ---------------------------------------------------------------------------
# Subnet check
# ---------------------------------------------------------------------------

ipv4_to_int() {
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  [[ $# -eq 4 ]] || return 1
  printf '%d' $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
}

ip_in_cidr() {
  local ip=$1 cidr=$2 network prefix mask ip_int net_int
  network=${cidr%/*}
  prefix=${cidr#*/}

  if (( prefix == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi

  ip_int=$(ipv4_to_int "$ip") || return 1
  net_int=$(ipv4_to_int "$network") || return 1

  (( (ip_int & mask) == (net_int & mask) ))
}

current_ipv4_addresses() {
  ifconfig 2>/dev/null | awk '$1 == "inet" { print $2 }'
}

on_allowed_subnet() {
  local ip
  while IFS= read -r ip; do
    if ip_in_cidr "$ip" "$SUBNET"; then
      return 0
    fi
  done < <(current_ipv4_addresses)
  return 1
}

# ---------------------------------------------------------------------------
# Mount points
# ---------------------------------------------------------------------------

mounted_volumes() {
  mount | sed -n 's/^.* on \(\/Volumes\/.*\) ([^()]*)$/\1/p'
}

volume_is_mounted() {
  local volume
  while IFS= read -r volume; do
    if [[ $volume == "/Volumes/$TM_VOLUME" ]]; then
      return 0
    fi
  done < <(mounted_volumes)
  return 1
}

share_mount_point() {
  local volume
  while IFS= read -r volume; do
    case $volume in
      "/Volumes/$SMB_SHARE" | "/Volumes/$SMB_SHARE"-[0-9]*)
        printf '%s\n' "$volume"
        return 0
        ;;
    esac
  done < <(mounted_volumes)
  return 1
}

wait_for_volume() {
  local timeout=${1:-$MOUNT_TIMEOUT} elapsed
  for ((elapsed = 0; elapsed < timeout; elapsed++)); do
    if volume_is_mounted; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------------------
# SMB share
# ---------------------------------------------------------------------------

mount_share() {
  local url elapsed
  url="${SMB_SERVER%/}/${SMB_SHARE}"

  log "mounting $url"
  # mount volume uses the login keychain; if no password is stored macOS shows
  # its own authentication dialog. It returns once the mount has finished (or
  # failed), so the loop below only covers slow servers.
  if ! osascript -e "mount volume \"$url\"" >/dev/null 2>&1; then
    warn "could not mount $url"
    return 1
  fi

  for ((elapsed = 0; elapsed < MOUNT_TIMEOUT; elapsed++)); do
    if share_mount_point >/dev/null; then
      return 0
    fi
    sleep 1
  done

  warn "timed out after ${MOUNT_TIMEOUT}s waiting for $url"
  return 1
}

# ---------------------------------------------------------------------------
# Time Machine image
# ---------------------------------------------------------------------------

find_image() {
  local dir=$1
  local -a matches=()

  if [[ -n $IMAGE_NAME ]]; then
    if [[ -e "$dir/$IMAGE_NAME" ]]; then
      printf '%s\n' "$dir/$IMAGE_NAME"
      return 0
    fi
    warn "IMAGE_NAME '$IMAGE_NAME' not found in $dir"
    return 1
  fi

  # Images are expected in the share root (the user id folder) or directly
  # below it. bash 3.2 (macOS) has no mapfile and BSD find has no -maxdepth,
  # so plain globs are the portable option here.
  shopt -s nullglob nocaseglob
  matches=(
    "$dir"/*.dmg "$dir"/*.asif "$dir"/*.sparseimage "$dir"/*.sparsebundle
    "$dir"/*/*.dmg "$dir"/*/*.asif "$dir"/*/*.sparseimage "$dir"/*/*.sparsebundle
  )

  if [[ ${#matches[@]} -eq 0 ]]; then
    warn "no Time Machine image (*.dmg, *.asif, *.sparseimage, *.sparsebundle) found in $dir"
    return 1
  fi
  if [[ ${#matches[@]} -gt 1 ]]; then
    warn "found more than one image in $dir, please set IMAGE_NAME:"
    printf '  %s\n' "${matches[@]}" >&2
    return 1
  fi

  printf '%s\n' "${matches[0]}"
}

keychain_passphrase() {
  security find-generic-password \
    -s "$IMAGE_KEYCHAIN_SERVICE" \
    -a "$IMAGE_KEYCHAIN_ACCOUNT" \
    -w 2>/dev/null
}

attach_with_passphrase() {
  local image=$1 passphrase=$2
  case $image in
    *.[aA][sS][iI][fF])
      # ASIF is only supported by `diskutil image`; hdiutil cannot attach it.
      printf '%s' "$passphrase" | diskutil image --stdinpassphrase attach "$image"
      ;;
    *)
      printf '%s' "$passphrase" | hdiutil attach -stdinpass "$image"
      ;;
  esac
}

attach_from_terminal() {
  local image=$1
  case $image in
    *.[aA][sS][iI][fF])
      diskutil image attach "$image"
      ;;
    *)
      hdiutil attach "$image"
      ;;
  esac
}

attach_image() {
  local image=$1 base passphrase=''
  base=$(basename "$image")

  if passphrase=$(keychain_passphrase); then
    log "using the passphrase stored in the login keychain for $base"
    if attach_with_passphrase "$image" "$passphrase"; then
      passphrase=''
      ATTACH_MODE=keychain
      return 0
    fi
    passphrase=''
    warn "the stored passphrase did not unlock $base"
  else
    log "no passphrase stored for $base (service '$IMAGE_KEYCHAIN_SERVICE', account '$IMAGE_KEYCHAIN_ACCOUNT')"
  fi

  # No usable keychain entry. When run from a terminal, let hdiutil/diskutil
  # prompt there; from launchd there is no terminal, so ask the GUI to open
  # the image and macOS shows its standard password dialog.
  if [[ -t 0 && -t 1 ]]; then
    attach_from_terminal "$image"
  else
    log "asking macOS for the passphrase of $base"
    open "$image"
  fi
  ATTACH_MODE=prompt
}

# ---------------------------------------------------------------------------
# Store the image passphrase in the login keychain
# ---------------------------------------------------------------------------

store_image_passphrase() {
  if [[ -z $IMAGE_KEYCHAIN_ACCOUNT ]]; then
    die "set SMB_USER (or IMAGE_KEYCHAIN_ACCOUNT) so the keychain account is known"
  fi

  printf 'Storing the Time Machine image passphrase\n'
  printf '  service: %s\n  account: %s\n' \
    "$IMAGE_KEYCHAIN_SERVICE" "$IMAGE_KEYCHAIN_ACCOUNT"
  printf 'You will be asked for the passphrase twice.\n'

  if ! security add-generic-password -U \
    -s "$IMAGE_KEYCHAIN_SERVICE" \
    -a "$IMAGE_KEYCHAIN_ACCOUNT" \
    -w; then
    die "could not store the passphrase in the login keychain"
  fi

  printf 'Stored in the login keychain.\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  case ${1:-} in
    -h | --help)
      usage
      exit 0
      ;;
    --store-image-password)
      if [[ -n ${2:-} ]]; then
        IMAGE_KEYCHAIN_ACCOUNT=$2
      fi
      store_image_passphrase
      exit 0
      ;;
    '') ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  [[ -n $TM_VOLUME ]] || die "TM_VOLUME is not set; see --help"
  [[ -n $SMB_USER ]] || die "SMB_USER is not set; see --help"
  if [[ $TM_VOLUME == REPLACE_* || $SMB_USER == REPLACE_* ]]; then
    die "the LaunchAgent still contains REPLACE_* placeholders; edit the plist first"
  fi
  if [[ ! $SUBNET =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    die "SUBNET must be a CIDR block such as 134.2.0.0/16 (got '$SUBNET')"
  fi
  if (( ${SUBNET#*/} > 32 )); then
    die "SUBNET prefix must be between 0 and 32 (got '$SUBNET')"
  fi
  [[ $MOUNT_TIMEOUT =~ ^[0-9]+$ ]] || die "MOUNT_TIMEOUT must be a number"
  [[ $PROMPT_TIMEOUT =~ ^[0-9]+$ ]] || die "PROMPT_TIMEOUT must be a number"

  acquire_lock
  rotate_log

  if volume_is_mounted; then
    # Nothing to do. Stay quiet so the log does not grow every minute.
    exit 0
  fi

  if ! on_allowed_subnet; then
    # Outside the allowed network: leave the share alone.
    exit 0
  fi

  local mount_point image timeout
  if mount_point=$(share_mount_point); then
    log "SMB share already mounted at $mount_point"
  else
    mount_share || die "failed to mount ${SMB_SERVER%/}/${SMB_SHARE}"
    mount_point=$(share_mount_point) || die "share mounted but no mount point found"
  fi

  image=$(find_image "$mount_point") || die "no Time Machine image available in $mount_point"
  log "using image $image"

  attach_image "$image" || die "could not attach $image"

  if [[ $ATTACH_MODE == prompt ]]; then
    timeout=$PROMPT_TIMEOUT
  else
    timeout=$MOUNT_TIMEOUT
  fi

  if wait_for_volume "$timeout"; then
    log "Time Machine volume '$TM_VOLUME' is mounted"
  else
    warn "image $image was attached, but volume '$TM_VOLUME' did not appear"
    warn "currently mounted volumes:"
    mounted_volumes >&2 || true
    if [[ $ATTACH_MODE == prompt ]]; then
      warn "if macOS is still showing a password dialog, answer it before the next run"
    fi
    exit 1
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
