#!/bin/bash
# Based on / Credit Due: 
#     https://raw.githubusercontent.com/yaronr/dockerfile/master/backup-volume-container/run.sh by "Yaron Rosenbaum" (yaronr)
#
# Note: it's essnetially you have a service keeping good time on the CoreOS host. 
#
# Man page: http://duplicity.nongnu.org/duplicity.1.html
#

BACKUP_SOURCE="$1"
BACKUP_TARGET="$2"
BACKUP_INTERVAL="${3:-600}"
BACKUP_COUNT="${4:-10}"

if [ $# -lt 2 ]; then
  echo "Invalid / incorrect / missing arguments supplied."
  echo "run <source directory> <s3 url> <quiet period> <remove-all-but-n-full>"
  echo
  echo "example:"
  echo "run.sh /etc/ s3://s3.amazonaws.com/my_bucker/my_directory 60 3"
  echo
  echo "This script will first try to restore backup from the given url, and then start backing up to that URL continuously, after every change + quiet period."
  exit 1
fi

if [[   ${AWS_ACCESS_KEY_ID} = "foobar_aws_key_id" || ${AWS_SECRET_ACCESS_KEY} = "foobar_aws_access_key" ]] ; then
  echo "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables MUST be set"
  exit 1
fi

inotifywait_events="modify,attrib,move,create,delete"
echo "Watching $BACKUP_SOURCE for changes"
echo "Using $BACKUP_TARGET as S3 URL"
echo "Using $BACKUP_INTERVAL as required quiet (file system inactivity) period before executing backup"
echo

# Create the backup & restore point if it doesn't already exist
[ -d $BACKUP_SOURCE ] || mkdir -p $BACKUP_SOURCE

cd $BACKUP_SOURCE

function do_restore() {
  echo "Performing restore from most recent backup..."
  duplicity --s3-use-new-style --no-encryption --force $BACKUP_TARGET . && touch .duplicity
}

function do_full_backup() {
  echo "Performing full backup..."
  duplicity full --no-encryption --allow-source-mismatch --s3-use-new-style . $BACKUP_TARGET && touch .duplicity
}

function do_incr_backup() {
  echo "Performing incremental backup..."
  duplicity incr --no-encryption --allow-source-mismatch --s3-use-new-style --full-if-older-than 7D . $BACKUP_TARGET && touch .duplicity
}

function do_cleanup() {
  echo "Cleaning up old backups..."
  duplicity remove-all-but-n-full $BACKUP_COUNT --force --s3-use-new-style --no-encryption --allow-source-mismatch $BACKUP_TARGET 
  duplicity cleanup --force --s3-use-new-style --no-encryption $BACKUP_TARGET
}

have_backups=$(duplicity collection-status --s3-use-new-style --no-encryption $BACKUP_TARGET | grep "Found primary backup chain")

if [ -z "$have_backups" ]; then
  # Create the first backup
  echo "Initializing backups..."
  do_full_backup
else
  if [ -f ".duplicity" ]; then
    # If we find the existance of a .duplicty file, we'll assume that we do not need to perform a restore since it's already been done before.
    # Remove the .duplicity file if you want a full restore.
    echo "Found .duplicity timestamp."
    do_incr_backup
  else
    # Start by restoring the last backup. This could fail if there's nothing to restore.
    echo "No previous restore detected."
    do_restore
  fi
fi

# Start waiting for file system events on this path.
while inotifywait -r -e $inotifywait_events . ; do
  # After an event, wait for a quiet period of N seconds before doing a backup
  echo "Change detected."
  while inotifywait -r -t $BACKUP_INTERVAL -e $inotifywait_events . ; do
    echo "Waiting for quiet period ($BACKUP_INTERVAL)..."
  done
  do_incr_backup
  do_cleanup
done
