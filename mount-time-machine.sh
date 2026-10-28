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

TM_VOLUME=${TM_VOLUME:-}                              # expected volume name (optional)
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

# TM_VOLUME is only an expectation. The name a disk image actually mounts as is
# decided by the image, so the first run learns it from the attach and stores it
# here; later runs use it to exit early. Kept outside the LaunchAgent and
# config.env, which install.sh rewrites.
STATE_FILE=${STATE_FILE:-${HOME:-/tmp}/Library/Application Support/auto-mount-on-login/volume}

# Set in main() right before attaching; used to spot a volume that only shows up
# after an asynchronous attach (the `open` fallback).
volumes_before=''

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

  TM_VOLUME               expected volume name (optional; otherwise learned from
                          the first successful attach and cached in
                          ~/Library/Application Support/auto-mount-on-login/volume)
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

release_lock() { rm -rf "$LOCK_DIR"; }

# One run at a time. A run can sit on Apple's password dialog while the agent
# fires again every 60 seconds; without this, dialogs would stack up.
acquire_lock() {
  local pid=''

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    [[ -r $LOCK_DIR/pid ]] && pid=$(<"$LOCK_DIR/pid")
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
      log "previous run (pid $pid) is still busy, skipping this interval"
      exit 0
    fi
    warn "removing stale lock $LOCK_DIR"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
  fi

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
  # A /0 mask needs no special case: bash evaluates (0xFFFFFFFF << 32) as 0.
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))

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
  local name=${1-${TM_VOLUME:-}} volume
  [[ -n $name ]] || return 1
  while IFS= read -r volume; do
    if [[ $volume == "/Volumes/$name" ]]; then
      return 0
    fi
  done < <(mounted_volumes)
  return 1
}

# Volume name remembered from the last successful attach. Kept outside the
# LaunchAgent and config.env: install.sh rewrites those, and this value is a
# result, not a setting.
learned_volume() {
  [[ -r $STATE_FILE ]] || return 1
  head -n 1 "$STATE_FILE" 2>/dev/null
}

remember_volume() {
  if ! { mkdir -p "${STATE_FILE%/*}" && printf '%s\n' "$1" >"$STATE_FILE"; } 2>/dev/null; then
    warn "could not remember the volume name in $STATE_FILE"
  fi
}

# Volumes that are mounted now but were not when volumes_before was taken.
new_volumes() {
  comm -13 \
    <(printf '%s\n' "$volumes_before" | sort) \
    <(mounted_volumes | sort)
}

new_volume_appeared() {
  [[ -n $(new_volumes) ]]
}

# choose_volume IMAGE MOUNT... -> prints the volume name to use.
#
# An explicit TM_VOLUME wins if it appeared. Otherwise the only new mount point
# is taken, and for multi-volume images the one named like the image file.
choose_volume() {
  local image=$1 base mount
  shift

  if [[ -n ${TM_VOLUME:-} ]]; then
    for mount in "$@"; do
      if [[ ${mount##*/} == "$TM_VOLUME" ]]; then
        printf '%s\n' "$TM_VOLUME"
        return 0
      fi
    done
    warn "the configured TM_VOLUME '$TM_VOLUME' did not appear; using what was attached"
  fi

  if (( $# == 1 )); then
    printf '%s\n' "${1##*/}"
    return 0
  fi

  base=$(basename "$image")
  base=${base%.*}
  for mount in "$@"; do
    if [[ ${mount##*/} == "$base" ]]; then
      printf '%s\n' "$base"
      return 0
    fi
  done

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

# Wait up to TIMEOUT seconds for PREDICATE to succeed.
wait_for() {
  local predicate=$1 timeout=${2:-$MOUNT_TIMEOUT} elapsed
  for ((elapsed = 0; elapsed < timeout; elapsed++)); do
    if "$predicate"; then
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
  local url
  url="${SMB_SERVER%/}/${SMB_SHARE}"

  log "mounting $url"
  # mount volume uses the login keychain; if no password is stored macOS shows
  # its own authentication dialog. It returns once the mount has finished (or
  # failed), so the wait below only covers slow servers.
  if ! osascript -e "mount volume \"$url\"" >/dev/null 2>&1; then
    warn "could not mount $url"
    return 1
  fi

  if ! wait_for share_mount_point >/dev/null; then
    warn "timed out after ${MOUNT_TIMEOUT}s waiting for $url"
    return 1
  fi
}

# listing_error DIR -> prints why DIR cannot be listed, returns non-zero.
# On success it prints nothing and returns 0.
listing_error() {
  local dir=$1 out
  if [[ ! -d $dir ]]; then
    printf 'not a directory\n'
    return 1
  fi
  # stderr is kept, stdout is discarded (we only care about the error text)
  if out=$(ls -1A "$dir" 2>&1 >/dev/null); then
    return 0
  fi
  printf '%s\n' "${out:-unknown error}"
  return 1
}

dir_is_usable() {
  listing_error "$1" >/dev/null 2>&1
}

# A stale SMB mount and a privacy (TCC) denial are both "cannot list", but only
# the first is fixed by remounting. Treat the second as a hard error.
error_is_permission() {
  [[ $1 == *"Operation not permitted"* || $1 == *"Permission denied"* ]]
}

warn_permission() {
  warn "$1"
  warn "macOS is blocking this process from reading network volumes (TCC) -"
  warn "grant 'Network Volumes' access (README: 'Network volume permission'). Not remounting."
}

remount_share() {
  local mount_point=$1

  # A stale SMB mount stays in `mount` output (and in /Volumes) after sleep or
  # a dropped connection, but cannot be listed. Eject it and mount it again.
  # This runs from launchd without a terminal, so it must never call sudo.
  if ! diskutil unmount force "$mount_point" >/dev/null 2>&1; then
    warn "could not eject the unusable mount $mount_point"
    return 1
  fi
  mount_share
}

# ---------------------------------------------------------------------------
# Time Machine image
# ---------------------------------------------------------------------------

# One path per line for every image in DIR (and, with depth > 0, one level
# below it).
#
# `ls -1A` instead of globs on purpose: a glob that cannot read a directory
# (stale SMB mount, permission problem) silently expands to nothing, which is
# indistinguishable from "no image there". `ls` reports the real error, so the
# log can explain what happened.
scan_images() {
  local dir=$1 depth=$2 entries entry name path

  # Quiet on a listing error: find_image diagnoses it once, with the full
  # message, after the retries.
  # `ls -1A` on purpose (see the comment above); names with newlines are not a
  # realistic case for disk image files.
  # shellcheck disable=SC2012
  if ! entries=$(ls -1A "$dir" 2>&1); then
    return 1
  fi

  while IFS= read -r entry; do
    if [[ -z $entry ]]; then
      continue
    fi
    # ._time-machine.asif is the AppleDouble metadata file of
    # time-machine.asif on SMB shares. Skip dot entries, like a glob does.
    if [[ $entry == .* ]]; then
      continue
    fi

    path="$dir/$entry"
    name=$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')
    case $name in
      *.dmg | *.asif | *.sparseimage | *.sparsebundle)
        printf '%s\n' "$path"
        ;;
      *)
        # .sparsebundle is an image and a directory at the same time; never
        # descend into it (handled above), but do look one level down.
        if (( depth > 0 )) && [[ -d $path ]]; then
          scan_images "$path" $((depth - 1)) || true
        fi
        ;;
    esac
  done <<< "$entries"

  return 0
}

# Log what is actually in DIR; bounded, so a huge share cannot flood the log.
log_directory() {
  local dir=$1 out line
  # shellcheck disable=SC2012
  out=$(ls -la "$dir" 2>&1 | head -n 40) || true
  # stderr, because find_image's stdout is the image path
  {
    log "  contents of $dir (first 40 lines):"
    while IFS= read -r line; do
      log "    $line"
    done <<< "$out"
  } >&2
}

find_image() {
  local dir=$1 attempt entry
  local -a images=()

  if [[ -n $IMAGE_NAME ]]; then
    if [[ -e "$dir/$IMAGE_NAME" ]]; then
      printf '%s\n' "$dir/$IMAGE_NAME"
      return 0
    fi
    warn "IMAGE_NAME '$IMAGE_NAME' not found in $dir"
    log_directory "$dir"
    return 1
  fi

  # Images are expected in the share root (the user id folder) or directly
  # below it. Retry once: right after mounting, an SMB directory can still be
  # empty or not ready.
  for attempt in 1 2; do
    images=()
    # bash 3.2 (the stock /bin/bash on macOS) has no mapfile/readarray.
    while IFS= read -r entry; do
      [[ -n $entry ]] && images+=("$entry")
    done < <(scan_images "$dir" 1)

    if [[ ${#images[@]} -gt 0 ]]; then
      break
    fi
    if (( attempt == 1 )); then
      sleep 2
    fi
  done

  if [[ ${#images[@]} -eq 0 ]]; then
    local reason
    reason=$(listing_error "$dir") || true
    if error_is_permission "${reason:-}"; then
      warn_permission "cannot list $dir: $reason"
      return 1
    fi
    if [[ -n $reason ]]; then
      warn "cannot list $dir: $reason"
    fi
    warn "no Time Machine image (*.dmg, *.asif, *.sparseimage, *.sparsebundle) found in $dir"
    log_directory "$dir"
    return 1
  fi
  if [[ ${#images[@]} -gt 1 ]]; then
    warn "found more than one image in $dir, please set IMAGE_NAME:"
    printf '  %s\n' "${images[@]}" >&2
    return 1
  fi

  printf '%s\n' "${images[0]}"
}

keychain_passphrase() {
  security find-generic-password \
    -s "$IMAGE_KEYCHAIN_SERVICE" \
    -a "$IMAGE_KEYCHAIN_ACCOUNT" \
    -w 2>/dev/null
}

# Attach IMAGE. Sets ATTACH_MODE: "keychain" when the stored passphrase worked,
# "prompt" when macOS is asked for it, and — for the non-interactive keychain
# path — ATTACH_OUTPUT to the command's output. hdiutil documents that output as "<device>\t<content hint>\t<mount point>", so
# the mount point of an attach can be known without inspecting /Volumes. ASIF
# needs `diskutil image`; every other format uses hdiutil, and the two want
# their flags in a different place, so both command lines are spelled out.
attach_image() {
  local image=$1 base passphrase=''
  local -a with_pass plain
  ATTACH_OUTPUT=''
  base=$(basename "$image")
  case $image in
    *.[aA][sS][iI][fF])
      with_pass=(diskutil image --stdinpassphrase attach)
      plain=(diskutil image attach)
      ;;
    *)
      with_pass=(hdiutil attach -stdinpass)
      plain=(hdiutil attach)
      ;;
  esac

  if passphrase=$(keychain_passphrase); then
    log "using the passphrase stored in the login keychain for $base"
    if ATTACH_OUTPUT=$(printf '%s' "$passphrase" | "${with_pass[@]}" "$image" 2>&1); then
      ATTACH_MODE=keychain
      return 0
    fi
    warn "the stored passphrase did not unlock $base"
    ATTACH_OUTPUT=''
  else
    log "no passphrase stored for $base (service '$IMAGE_KEYCHAIN_SERVICE', account '$IMAGE_KEYCHAIN_ACCOUNT')"
  fi

  # No usable keychain entry. When run from a terminal, let hdiutil/diskutil
  # prompt there; from launchd there is no terminal, so ask the GUI to open
  # the image and macOS shows its standard password dialog. The output is not
  # captured here: the prompt must stay visible, and the /Volumes diff finds
  # the mount point instead.
  if [[ -t 0 && -t 1 ]]; then
    "${plain[@]}" "$image"
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

  local learned
  learned=$(learned_volume) || learned=''
  if volume_is_mounted "$learned" || volume_is_mounted "${TM_VOLUME:-}"; then
    # Nothing to do. Stay quiet so the log does not grow every minute.
    exit 0
  fi

  if ! on_allowed_subnet; then
    # Outside the allowed network: leave the share alone.
    exit 0
  fi

  local mount_point image timeout reason
  if mount_point=$(share_mount_point); then
    if dir_is_usable "$mount_point"; then
      log "SMB share already mounted at $mount_point"
    else
      reason=$(listing_error "$mount_point") || true
      if error_is_permission "$reason"; then
        warn_permission "share at $mount_point is mounted but cannot be listed: $reason"
        exit 1
      fi
      warn "share at $mount_point is mounted but cannot be listed ($reason); remounting"
      remount_share "$mount_point" || die "share at $mount_point is not usable"
      mount_point=$(share_mount_point) || die "share mounted but no mount point found"
    fi
  else
    mount_share || die "failed to mount ${SMB_SERVER%/}/${SMB_SHARE}"
    mount_point=$(share_mount_point) || die "share mounted but no mount point found"
  fi

  image=$(find_image "$mount_point") || die "no Time Machine image available in $mount_point"
  log "using image $image"

  # Snapshot before attaching: when the attach command's output cannot be parsed
  # (the asynchronous `open` fallback), a new mount point is still detectable as
  # the difference to this snapshot.
  volumes_before=$(mounted_volumes)

  attach_image "$image" || die "could not attach $image"

  timeout=$MOUNT_TIMEOUT
  if [[ $ATTACH_MODE == prompt ]]; then
    timeout=$PROMPT_TIMEOUT
  fi

  # hdiutil documents its attach output as
  # "<device>\t<content hint>\t<mount point>", so use it when present.
  local -a attached=()
  local mount chosen
  while IFS= read -r mount; do
    [[ -n $mount ]] && attached+=("$mount")
  done < <(printf '%s\n' "$ATTACH_OUTPUT" |
    awk -F'\t' 'NF >= 3 && $3 ~ /^\/Volumes\// { print $3 }')

  # Otherwise wait for a volume that was not mounted before the attach. This
  # also covers `open`, where macOS mounts the image after this script returns.
  if (( ${#attached[@]} == 0 )); then
    wait_for new_volume_appeared "$timeout" || true
    while IFS= read -r mount; do
      [[ -n $mount ]] && attached+=("$mount")
    done < <(new_volumes)
  fi

  if (( ${#attached[@]} == 0 )); then
    warn "image $image was attached, but no new volume appeared"
    warn "currently mounted volumes:"
    mounted_volumes >&2 || true
    if [[ $ATTACH_MODE == prompt ]]; then
      warn "if macOS is still showing a password dialog, answer it before the next run"
    fi
    exit 1
  fi

  if ! chosen=$(choose_volume "$image" "${attached[@]}"); then
    warn "found more than one volume after attaching $image:"
    printf '  %s\n' "${attached[@]}" >&2
    die "cannot tell which one is the Time Machine volume; set TM_VOLUME"
  fi

  TM_VOLUME=$chosen
  remember_volume "$TM_VOLUME"
  log "Time Machine volume '$TM_VOLUME' is mounted"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
