# shellcheck shell=sh
# Backup target driver "local" (REQ-072): the target is a folder, `/backups` by default. Sourced by backup.sh, never run.
# A driver gives backup.sh these functions and nothing else; a new kind of target is one new file like this one:
#   driver_check             fail (via die) when the target cannot be used
#   driver_put <file> <id>   store <file> as <id>/<its name>
#   driver_get <id> <name> <destination file>
#   driver_ids               print the ids of the complete backups (those that hold COMPLETE), oldest first
#   driver_delete <id>       remove one backup

driver_check() {
  [ -d "$TARGET" ] || die "the backup folder $TARGET does not exist or is not writable"
  [ -w "$TARGET" ] || die "the backup folder $TARGET does not exist or is not writable"
}

driver_put() {
  mkdir -p "$TARGET/$2" && cp "$1" "$TARGET/$2/.$(basename "$1").part" && mv "$TARGET/$2/.$(basename "$1").part" "$TARGET/$2/$(basename "$1")"
}

driver_get() { cp "$TARGET/$1/$2" "$3"; }

driver_ids() {
  for dir in "$TARGET"/*/; do
    [ -f "${dir}COMPLETE" ] && basename "$dir"
  done | sort
}

driver_delete() { rm -rf "${TARGET:?}/$1"; }
