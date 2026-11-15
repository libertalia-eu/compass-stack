# shellcheck shell=sh
# Backup target driver "s3" (REQ-072): the target is s3://<bucket>[/<prefix>] on an S3-compatible server. The bucket must exist.
# Settings: COMPASS_BACKUP_S3_ENDPOINT, COMPASS_BACKUP_S3_KEY_ID, COMPASS_BACKUP_S3_KEY, COMPASS_BACKUP_S3_REGION.
# The keys have no default: a customer system never gets one from this repository. Contract of a driver: see local.sh.

driver_check() {
  [ -n "${COMPASS_BACKUP_S3_ENDPOINT:-}" ] || die "COMPASS_BACKUP_S3_ENDPOINT is empty"
  [ -n "${COMPASS_BACKUP_S3_KEY_ID:-}" ] || die "COMPASS_BACKUP_S3_KEY_ID is empty"
  [ -n "${COMPASS_BACKUP_S3_KEY:-}" ] || die "COMPASS_BACKUP_S3_KEY is empty"
  # rclone reads its remote "backup" from these variables, so no key lands in a file or on a command line.
  export RCLONE_CONFIG_BACKUP_TYPE=s3 RCLONE_CONFIG_BACKUP_PROVIDER=Other
  export RCLONE_CONFIG_BACKUP_ENDPOINT="$COMPASS_BACKUP_S3_ENDPOINT"
  export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="$COMPASS_BACKUP_S3_KEY_ID"
  export RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="$COMPASS_BACKUP_S3_KEY"
  export RCLONE_CONFIG_BACKUP_REGION="${COMPASS_BACKUP_S3_REGION:-us-east-1}"
  export RCLONE_CONFIG_BACKUP_NO_CHECK_BUCKET=true # the bucket is the customer's to create; a typo must not make a new one
  bucket_path="backup:${TARGET#s3://}"
  bucket_path="${bucket_path%/}"
  rclone lsf --max-depth 1 "$bucket_path" >/dev/null || die "cannot read $TARGET (endpoint, keys or bucket wrong)"
}

driver_put() { rclone copyto "$1" "$bucket_path/$2/$(basename "$1")"; }

driver_get() { rclone copyto "$bucket_path/$1/$2" "$3"; }

driver_ids() { rclone lsf -R --files-only --include COMPLETE "$bucket_path" | sed 's|/COMPLETE$||' | sort; }

driver_delete() { rclone purge "$bucket_path/$1"; }
