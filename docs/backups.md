# Automatic encrypted backups

`ops/backup_runner` in a native release, or `scripts/backup_runner` in the repository, runs
three commands: `backup`, `verify` and `status`. It needs the PostgreSQL 18 client programs,
Restic, and `flock` from util-linux on Linux or `lockf` on macOS. In the repository the runner
uses Elixir 1.20 with OTP 29 from mise; in a native release it uses the bundled runtime. It
starts no Phoenix application and needs neither `DATABASE_URL` nor `SECRET_KEY_BASE`.

## Schedule and retention

- **Daily at 03:15 UTC**, delayed by up to 15 minutes: take a consistent PostgreSQL dump, store
  it locally in an encrypted Restic repository, and optionally copy it into a second
  repository. A copy also catches up transfers that failed earlier.
- Only after a successful backup, and after a successful external copy where one is configured:
  keep **7 daily, 4 weekly and 12 monthly** snapshots, plus the most recent one. The rules apply
  together, over Restic's calendar periods. They guarantee no gapless history if the server was
  off on some days.
- **Sundays at 06:15 UTC**: check the repository including its stored data, decrypt this
  instance's newest snapshot, restore it into a freshly created randomly named database, and
  check that the central Sikio tables are there. The check database is removed afterwards, also
  when the restore fails. With an external target this happens for both repositories. The full
  check reads all repository data and can cause traffic and cost at an external provider.
- Ordinary backups need no CREATEDB rights. The restore check needs them on the checking
  server. `SIKIO_VERIFY_PG*` can point it at a separate PostgreSQL instance or a separate
  checking user.

References: [Restic retention](https://restic.readthedocs.io/en/stable/060_forget.html) and
[copying between repositories](https://restic.readthedocs.io/en/stable/045_working_with_repos.html#copying-snapshots-between-repositories).

A repository should serve this backup purpose and nothing else. Retention is additionally
limited to the tag `sikio` and to `SIKIO_BACKUP_ID`. Choose that id uniquely and keep it when
the server moves. Different Sikio instances get different ids and separate state directories.
Do not let two machines back up the same instance at once; the process lock only covers its own
machine and volume.

## What is backed up

The whole database, which includes accounts, passkeys and playback positions. Audio and video
stay with their publishers. The runtime configuration, `SECRET_KEY_BASE` and the Restic
passwords are **not part of the dump**. Keep them separately, in a password manager or another
independent secure place. Without the Restic password there is no restore. The backup machine
needs access to that password in order to decrypt, so the encryption protects nothing on a
backup system that is already fully compromised.

The dump and the decrypted check dump live only briefly in private temporary directories. The
systemd templates use `PrivateTmp`, and the backup container uses a `/tmp` tmpfs. A hard kill
during a manual run can leave temporary files behind, so protect the host disk accordingly. A
hard kill can also leave a check database prefixed `sikio_verify_` behind; remove it
deliberately after looking at it. Finished backups are encrypted.

## Setting up a native release

The release carries the runner, `backup`, `restore`, an example configuration and the systemd
templates under `ops/`. Install Restic, util-linux and the PostgreSQL 18 clients on the target
server. A separate Elixir or Erlang installation is not needed for the release. The bundled
Linux runtime needs the usual Erlang system libraries; the Debian images install
`libstdc++6`, `libncurses6`, OpenSSL and `libsctp1` in particular.

Then create the directories and the configuration as an administrator:

```sh
sudo install -d -m 0700 -o sikio -g sikio /var/lib/sikio-backups /etc/sikio/backup-secrets
sudo cp /opt/sikio/current/ops/backup.env.example /etc/sikio/backup.env
sudo chown sikio:sikio /etc/sikio/backup.env
sudo chmod 600 /etc/sikio/backup.env
# Edit backup.env: the PG connection, a unique instance id and the paths.
# pgpass lines are HOST:PORT:DATABASE:USER:PASSWORD, in a file with mode 0600.
# For the randomly named check databases, use * in the database field of the check pgpass.
sudo -u sikio sh -c 'set -C; umask 077; openssl rand -base64 48 > /etc/sikio/backup-secrets/local-password'
```

Keep that password independently, and never generate a new one for an existing repository.
Initialize once with the **trusted local** configuration file, and run both paths by hand
before enabling the timers:

```sh
sudo -u sikio sh -c 'set -a; . /etc/sikio/backup.env; set +a; restic init'
sudo -u sikio sh -c 'set -a; . /etc/sikio/backup.env; set +a; /opt/sikio/current/ops/backup_runner backup'
sudo -u sikio sh -c 'set -a; . /etc/sikio/backup.env; set +a; /opt/sikio/current/ops/backup_runner verify'
sudo -u sikio sh -c 'set -a; . /etc/sikio/backup.env; set +a; /opt/sikio/current/ops/backup_runner status'

sudo cp /opt/sikio/current/ops/systemd/sikio-backup* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sikio-backup.timer sikio-backup-verify.timer
systemctl list-timers 'sikio-backup*'
```

`Persistent=true` catches up a run missed while the server was off. No timer is installed
automatically by a release build or an application start.

## Setting up Docker

The ordinary Compose file stays as it is. The explicit addition `compose.backup.yaml` builds a
short-lived backup container with the PostgreSQL clients, Elixir with Erlang, and Restic.
Neither the application nor the database is extended with those tools.

```sh
cp deploy/backup-compose.env.example .backup.env
chmod 600 .backup.env
mkdir -p .backup-secrets backups
chmod 700 .backup-secrets backups
# Edit .backup.env: at minimum, set a unique SIKIO_BACKUP_ID.
( set -C; umask 077; openssl rand -base64 48 > .backup-secrets/local-password )

docker compose -f compose.yaml -f compose.backup.yaml build backup
docker compose -f compose.yaml -f compose.backup.yaml run --rm --entrypoint restic backup init
docker compose -f compose.yaml -f compose.backup.yaml run --rm backup backup
docker compose -f compose.yaml -f compose.backup.yaml run --rm backup verify
docker compose -f compose.yaml -f compose.backup.yaml run --rm backup status
```

To schedule this on a Linux Docker host, use the same timers but adapt the two services. An
example for the backup service with the repository at `/opt/sikio`:

```ini
[Service]
Type=oneshot
WorkingDirectory=/opt/sikio
ExecStart=/usr/bin/docker compose -f compose.yaml -f compose.backup.yaml run --rm backup backup
TimeoutStartSec=6h
UMask=0077
```

For the verify service, replace the last argument with `verify` and use a 12h timeout. Do
**not** carry over the native `EnvironmentFile` and `User=sikio` configuration here: Compose
reads `.env` and `.backup.env`, and the executing system service needs access to Docker. Give
those rights only to the service meant to have them. systemd holds back a service that is
already running, and the runner additionally prevents parallel backup and verify runs. A
collision or a network error fails the service; after fixing it, run it again with
`systemctl start ...service`.

## Adding an external copy

Without `SIKIO_REMOTE_REPOSITORY` everything stays explicitly **local** (`offsite: false`).
That does not yet protect against losing the server.

Restic supports SFTP and S3-compatible storage among others. Set this in the relevant backup
configuration:

```text
SIKIO_REMOTE_REPOSITORY=sftp:backup@backup.example.org:/backups/sikio
SIKIO_REMOTE_PASSWORD_FILE=/etc/sikio/backup-secrets/remote-password
```

Under Docker the password file lives at `/secrets/remote-password` instead. For S3, use
something like `s3:https://ENDPOINT/BUCKET/PREFIX` and set `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` in the protected environment. For SFTP, provide a dedicated SSH key and
a checked `known_hosts`, and do not disable host checking. Under Docker, mount those dedicated
SSH files read-only into `/root/.ssh` as well. Do not write credentials into the repository URL.

Initialize the second repository once with the target environment, locally for example after
loading `backup.env`:

```sh
restic -r "$SIKIO_REMOTE_REPOSITORY" --password-file "$SIKIO_REMOTE_PASSWORD_FILE" \
  init --from-repo "$RESTIC_REPOSITORY" \
  --from-password-file "$RESTIC_PASSWORD_FILE" --copy-chunker-params
```

Then repeat `backup`, `verify` and `status`. The external copy is checked only once both
repositories have passed. The runner needs read rights for the check and delete rights for
retention, so limit the external target to a dedicated path or bucket prefix. This template is
not an immutable offline archive.

## Noticing failures and recovering

`status.json` holds timestamps and snapshot ids, no credentials. `status` exits with an error
when the backup is older than 36 hours, the check older than 8 days, the last run failed, or a
configured external copy is still unchecked. Put that command into the target server's
monitoring. No mail and no external notification is set up automatically.

```sh
systemctl --failed
journalctl -u sikio-backup.service -u sikio-backup-verify.service
# With the backup environment loaded:
restic snapshots --host "$SIKIO_BACKUP_ID" --tag sikio
( set -C; umask 077; restic dump SNAPSHOT_ID /sikio.dump > recovered.dump )
# Into a separately created EMPTY database only, with no application running against it:
PGDATABASE=sikio_recovered /opt/sikio/current/ops/restore recovered.dump
```

Check the exit code of the decryption before using the dump; on failure the manually redirected
file can be incomplete. To recover from the external copy, point `RESTIC_REPOSITORY` and
`RESTIC_PASSWORD_FILE` at its values. Check the data afterwards, and only then point the
application at the restored database. The runner overwrites no existing production database.

## What has been verified here

`mise run check` runs the tests for aborting on dump and copy failures, retention order, the
process lock, status age, and cleaning up after a failed restore check.

`mise exec -- elixir scripts/smoke_backups.exs` passes here against Restic 0.19.1 and a local
PostgreSQL 18. It uses only its own temporary database and two local test repositories, and it
checked real encryption, the copy into the second repository, retention, two restores with the
test data compared, the status command, and the refusal of a wrong password. The packaged
`ops/backup_runner` ran it from the release, on the bundled runtime and without any Phoenix
configuration. It needs Restic on PATH and local `PG*` credentials with CREATEDB.

The backup image was built from this checkout and `scripts/smoke_containers.exs` exercised it
under Linux on ARM64 with Apple's `container` runtime: two local encrypted repositories, a
backup, restore checks against a freshly created database, retention and the status command.

Docker Compose and systemd have not been run, and no SFTP or S3 transfer has happened. Run the
schedules and the external copy on the target machine before relying on them.
