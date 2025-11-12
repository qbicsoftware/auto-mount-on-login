#!/usr/bin/env bash
set -euo pipefail

# provide your zdv username as first parameter
# provide the name of your time machine file as second parameter (without the ending of .dmg)
if [[ $# < 4 ]]; then
  echo $(date +"%Y-%m-%d %T")" invalid number of parameters." >> /dev/stderr
  exit 1
fi

SMB_SERVER=$1
DMG_NAME=$2
ZDV_USER=$3
IP_ADDRESS_FILTER=$4


SMB_ADDRESS=$SMB_SERVER/$ZDV_USER

TIME_MACHINE_DMG=/Volumes/$ZDV_USER/$DMG_NAME.dmg
CONNECTED_TO_NETWORK=$(ifconfig | grep $IP_ADDRESS_FILTER) 
if [ -z "$CONNECTED_TO_NETWORK" ]; then
  echo $(date +"%Y-%m-%d %T")" not connected to required network" >> /dev/stderr
  exit 1
fi
if ! [ -f $TIME_MACHINE_DMG ]; then
  echo "Cound not find $TIME_MACHINE_DMG"
  # mount smb share
  echo $(date +"%Y-%m-%d %T")" smb share disconnected. Trying to re-mount $SMB_ADDRESS ..."
  osascript -e "mount volume \"$SMB_ADDRESS\""
else
  echo $(date +"%Y-%m-%d %T")" already connected to smb share."
fi
if ! [ -d /Volumes/$DMG_NAME ]; then
  # mount time machine
  echo $(date +"%Y-%m-%d %T")" time machine disconnected. Trying to re-mount..."
  open $TIME_MACHINE_DMG
else 
  echo $(date +"%Y-%m-%d %T")" the desired volume is mounted already. Nothing left to do."
  exit 0
fi
echo $(date +"%Y-%m-%d %T")" finished execution"
