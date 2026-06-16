# phpBB Auto Updater

A Bash-based phpBB 3.3.x backup and auto-updater for Linux servers.

The script checks the official phpBB 3.3 release index, compares the latest available version against your installed phpBB version, and only performs an update when a newer release exists. Normal cron runs are intentionally quiet: if no update is available, the script exits without creating a backup, sending email, disabling the board, or touching the forum files.

## Features

- Checks installed phpBB version from `config.php` and the phpBB database.
- Detects the latest phpBB 3.3.x release from `https://download.phpbb.com/pub/release/3.3/`.
- Does nothing when no update is available.
- Creates full database and site-file backups before update, unless `--no-backup` is used.
- Keeps only the last configured number of backups.
- Downloads and verifies the phpBB ZIP before touching the live forum.
- Preserves important phpBB data:
  - `config.php`
  - `files/`
  - `images/`
  - `store/`
  - `ext/`
  - `styles/`
- Supports custom phpBB styles/themes.
- Disables the phpBB board during update and re-enables it after success.
- Runs phpBB database migrations using `bin/phpbbcli.php db:migrate --safe-mode`.
- Clears cache and recreates `cache/production` with writable permissions.
- Runs optional preflight and post-update health checks.
- Attempts rollback if an update fails after backup.
- Sends local `sendmail` reports with the full log attached.
- Supports root or non-root usage, as long as the user has permission to read/write the forum files, run MySQL backups, and use sendmail.

## Requirements

The server needs:

- Bash
- PHP CLI with MySQL support
- MySQL/MariaDB client
- `mysqldump`
- `curl` or `wget`
- `unzip`
- `rsync`
- `tar`
- `gzip`
- `sendmail` or compatible local MTA, optional but recommended

On Debian/Ubuntu, a typical install might be:

```bash
sudo apt update
sudo apt install php-cli php-mysql mariadb-client curl unzip rsync tar gzip sendmail-bin
```

Package names vary by distribution.

## Installation

Clone or download the script:

```bash
sudo mkdir -p /opt/phpbb-auto-updater
sudo cp phpbb-auto-updater.sh /opt/phpbb-auto-updater/phpbb-auto-updater.sh
sudo chmod +x /opt/phpbb-auto-updater/phpbb-auto-updater.sh
```

Edit the top configuration section:

```bash
sudo nano /opt/phpbb-auto-updater/phpbb-auto-updater.sh
```

At minimum, change:

```bash
SITE_DIR="/var/www/forums.domain.tld"
FORUM_URL="https://forums.domain.tld/"
FROM_EMAIL="server@forums.domain.tld"
ADMIN_EMAILS=(
  "admin@example.com"
  "webmaster@example.com"
)
```

Also review:

```bash
BACKUP_ROOT="/var/backups/phpbb-auto-updater"
WORK_ROOT="/tmp/phpbb-upgrade-work"
LOG_DIR="/var/log/phpbb-auto-updater"
KEEP_BACKUPS=4
WEB_USER="www-data"
WEB_GROUP="www-data"
AUTO_DETECT_SITE_OWNER=1
```

## Configuration Variables

### `SITE_DIR`

Absolute path to your phpBB installation.

Example:

```bash
SITE_DIR="/var/www/forums.domain.tld"
```

### `FORUM_URL`

Public URL to the forum root. Used for health checks.

```bash
FORUM_URL="https://forums.domain.tld/"
```

### `PHPBB_BRANCH`

Release branch to track. The script is designed for phpBB 3.3.x.

```bash
PHPBB_BRANCH="3.3"
```

### `BACKUP_ROOT`

Directory where backups are stored. Each run creates a timestamped subdirectory.

```bash
BACKUP_ROOT="/var/backups/phpbb-auto-updater"
```

### `KEEP_BACKUPS`

How many backup directories to keep.

```bash
KEEP_BACKUPS=4
```

### `ADMIN_EMAILS`

Email recipients for reports. Multiple recipients are supported.

```bash
ADMIN_EMAILS=(
  "admin@example.com"
  "webmaster@example.com"
)
```

### `PRESERVE_ITEMS`

Files and directories that survive core replacement.

Default:

```bash
PRESERVE_ITEMS=(
  "config.php"
  "files"
  "images"
  "store"
  "ext"
  "styles"
)
```

Keep `styles` if your forum uses custom themes.

### `WRITABLE_ITEMS`

phpBB paths that must be writable by the web server user.

Default:

```bash
WRITABLE_ITEMS=(
  "cache"
  "files"
  "store"
  "images/avatars/upload"
)
```

The script also recreates and fixes `cache/production`.

## Usage

### Normal update check

```bash
sudo /opt/phpbb-auto-updater/phpbb-auto-updater.sh
```

Behavior:

- If no update is available, it exits quietly.
- If an update is available, it downloads the package, creates a backup, updates phpBB, checks health, and sends a report.

### Backup only

```bash
sudo /opt/phpbb-auto-updater/phpbb-auto-updater.sh --backup-only
```

Backup only without health checks:

```bash
sudo /opt/phpbb-auto-updater/phpbb-auto-updater.sh --backup-only --no-checks
```

### Force update/rebuild

```bash
sudo /opt/phpbb-auto-updater/phpbb-auto-updater.sh --force-update
```

This runs the update workflow even if your installed version matches the latest version.

### Force update without backup

```bash
sudo /opt/phpbb-auto-updater/phpbb-auto-updater.sh --force-update --no-backup
```

Warning: rollback will not be possible.

### Skip checks

```bash
sudo /opt/phpbb-auto-updater/phpbb-auto-updater.sh --force-update --no-checks
```

This skips preflight and post-update HTTP/PHP/DB checks.

### Full risky/manual mode

```bash
sudo /opt/phpbb-auto-updater/phpbb-auto-updater.sh --force-update --no-backup --no-checks
```

Use only when you understand the risk.

## Cron Setup

Edit the crontab for the user that will run the script:

```bash
sudo crontab -e
```

Weekly backup every Sunday at 2:00 AM:

```cron
0 2 * * 0 /opt/phpbb-auto-updater/phpbb-auto-updater.sh --backup-only --no-checks >/dev/null 2>&1
```

Daily update check at 3:00 AM:

```cron
0 3 * * * /opt/phpbb-auto-updater/phpbb-auto-updater.sh >/dev/null 2>&1
```

The daily update check will not back up or modify anything unless a newer phpBB release is detected.

## Running Without Root

You do not have to use root, but the script user must be able to:

- Read and write the phpBB site directory.
- Read phpBB `config.php`.
- Create and delete files in the backup, log, and work directories.
- Run `mysql` and `mysqldump` using the credentials in phpBB `config.php`.
- Change ownership/permissions, or the script must be configured so ownership changes are unnecessary.
- Send email using local `sendmail`, if email reports are desired.

For non-root use, you may need to change:

```bash
BACKUP_ROOT="$HOME/phpbb-backups"
WORK_ROOT="$HOME/phpbb-upgrade-work"
LOG_DIR="$HOME/phpbb-update-logs"
AUTO_DETECT_SITE_OWNER=0
WEB_USER="www-data"
WEB_GROUP="www-data"
```

If the non-root user cannot run `chown`, remove or adjust the ownership-changing parts of the script, or run via sudo with limited permissions.

## Backup Layout

Backups are stored like this:

```text
/var/backups/phpbb-auto-updater/
  2026-06-16_02-00-00/
    forum_database_2026-06-16_02-00-00.sql.gz
    site_files_2026-06-16_02-00-00.tar.gz
    backup-info.txt
```

The script keeps only the last `KEEP_BACKUPS` directories.

## Rollback Behavior

If an update fails after a backup was created, the script attempts to:

1. Restore the site files from the tarball.
2. Restore the database from the SQL dump.
3. Fix writable directory permissions.
4. Clear/recreate the phpBB cache.
5. Restore the previous board disable state.

Rollback is not possible if `--no-backup` was used.

## Manual Restore Example

Restore database:

```bash
gzip -dc /var/backups/phpbb-auto-updater/2026-06-16_02-00-00/forum_database_2026-06-16_02-00-00.sql.gz \
  | mysql -u your_phpbb_user -p your_phpbb_database
```

Restore files:

```bash
sudo tar -xzf /var/backups/phpbb-auto-updater/2026-06-16_02-00-00/site_files_2026-06-16_02-00-00.tar.gz -C /var/www
```

Adjust paths to match your server.

## Troubleshooting

### `Unable to write to the cache directory path "./cache/production/"`

Fix permissions:

```bash
sudo mkdir -p /var/www/forums.domain.tld/cache/production
sudo chown -R www-data:www-data /var/www/forums.domain.tld/cache
sudo chmod -R 775 /var/www/forums.domain.tld/cache
```

### Missing custom styles after update

Make sure `styles` is listed in `PRESERVE_ITEMS`:

```bash
PRESERVE_ITEMS=(
  "config.php"
  "files"
  "images"
  "store"
  "ext"
  "styles"
)
```

### Download index works manually but script fails

The script uses plain curl/wget for the phpBB Apache index because some browser-like headers can trigger 403s.

Test manually:

```bash
curl -fsSL https://download.phpbb.com/pub/release/3.3/ \
  | grep -oE 'href="3\.3\.[0-9]+/' \
  | sed -E 's/href="//; s#/##' \
  | sort -V \
  | tail -n 1
```

### Health check false positives

Use:

```bash
sudo /opt/phpbb-auto-updater/phpbb-auto-updater.sh --force-update --no-checks
```

Then refine `HTTP_FATAL_REGEX` if needed.

## Security Notes

- Backups may contain sensitive data, including user emails, password hashes, private messages, uploaded files, and configuration secrets.
- Store backups somewhere protected.
- Do not commit real backups, real `config.php`, credentials, logs, or site-specific values to GitHub.
- Test this on a staging copy before running it against a production forum.

## License

MIT, GPL, or your preferred license. Add a `LICENSE` file before publishing publicly.
