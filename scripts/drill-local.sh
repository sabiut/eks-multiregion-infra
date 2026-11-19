#!/usr/bin/env bash
# Rehearse the database part of the failover on a laptop: no AWS, no cost, about a minute.
#
#   scripts/drill-local.sh
#
# It starts two PostgreSQL containers, a primary and a streaming replica (the same kind of
# replication RDS uses for a read replica), then walks through the steps of
# docs/dr-runbook.md and checks each claim the runbook makes:
#
#   - the read-only setting refuses new writes, but a transaction that was already open
#     still commits, which is why the fence restarts the database
#   - a write transaction that is open across the restart is rolled back
#   - after the restart the database refuses writes
#   - the replica is known to have everything once it has replayed past the primary's
#     final WAL position
#   - the promoted replica accepts writes and the old primary still refuses them
#
# Every SQL statement goes through the exact command scripts/db-psql.sh runs in a pod.
# What this cannot rehearse: RDS parameter groups, security groups, the accelerator,
# Terraform and Vault. Those need the real thing.
set -euo pipefail
cd "$(dirname "$0")/.."

image=postgres:17-alpine
net=drill-$$
password=$(openssl rand -hex 16)
inner=$(DRY_RUN=1 scripts/db-psql.sh local "x" | jq -r '.spec.containers[0].command[2]')

cleanup() { docker rm -f "$net-primary" "$net-replica" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; }
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }
ok()   { printf 'OK    %s\n' "$*"; }
die()  { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

# sql <primary|replica> "<statement>": the same command db-psql.sh runs, in a throwaway container.
sql() {
  docker run --rm --network "$net" -e DB_HOST="$net-$1" -e DB_PORT=5432 -e DB_NAME=postgres -e DB_USER=postgres \
    -e DB_PASSWORD="$password" -e PGSSLMODE=disable -e SQL="$2" "$image" sh -c "$inner"
}
wait_for() { # <primary|replica>
  for _ in $(seq 1 60); do sql "$1" "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done
  die "$1 did not come up"
}

step "Start a primary and a streaming replica"
docker network create "$net" >/dev/null
docker run -d --name "$net-primary" --network "$net" -e POSTGRES_PASSWORD="$password" "$image" >/dev/null
wait_for primary
docker exec "$net-primary" sh -c "echo 'host replication all all scram-sha-256' >> /var/lib/postgresql/data/pg_hba.conf"
sql primary "SELECT pg_reload_conf()" >/dev/null
docker run -d --name "$net-replica" --network "$net" --user postgres -e PGPASSWORD="$password" "$image" \
  sh -c "pg_basebackup -h $net-primary -U postgres -D /var/lib/postgresql/data -R -X stream && chmod 700 /var/lib/postgresql/data && exec postgres" >/dev/null
wait_for replica
[[ $(sql replica "SELECT pg_is_in_recovery()") == t ]] || die "the replica is not a replica"
sql primary "CREATE TABLE visits (note text)" >/dev/null
sql primary "INSERT INTO visits VALUES ('before the fence')" >/dev/null
ok "replica is following the primary"

step "Runbook step 2, part 1: make the database refuse writes"
# A write transaction that is already open when the fence goes up.
sql primary "BEGIN; INSERT INTO visits VALUES ('in flight'); SELECT pg_sleep(6); COMMIT" >/dev/null &
inflight=$!
sleep 2
sql primary "ALTER SYSTEM SET default_transaction_read_only = on" >/dev/null
sql primary "SELECT pg_reload_conf()" >/dev/null
for _ in $(seq 1 10); do [[ $(sql primary "SHOW default_transaction_read_only") == on ]] && break; sleep 1; done
[[ $(sql primary "SHOW default_transaction_read_only") == on ]] || die "the setting did not take effect"
set_at=$(sql primary "SELECT now()")     # the database's own clock, once the setting is in force
if sql primary "INSERT INTO visits VALUES ('after the fence')" >/dev/null 2>&1; then die "a new write was accepted"; fi
ok "a new write is refused"
wait "$inflight" || true
if [[ $(sql primary "SELECT count(*) FROM visits WHERE note = 'in flight'") == 1 ]]; then
  ok "but the transaction that was already open still committed: the setting alone is not a fence"
else
  die "expected the in-flight transaction to commit (the drill did not reproduce the case)"
fi

step "Runbook step 2, part 2: restart, which ends every open session"
# A write transaction that is open, with its INSERT already done, when the restart happens.
# The setting is on by now, so it has to ask for read-write explicitly to get this far.
sql primary "BEGIN READ WRITE; INSERT INTO visits VALUES ('never committed'); SELECT pg_sleep(60); COMMIT" >/dev/null 2>&1 &
open_writer="SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_xid IS NOT NULL AND query LIKE '%never committed%'"
for _ in $(seq 1 15); do [[ $(sql primary "$open_writer") == 1 ]] && break; sleep 1; done
[[ $(sql primary "$open_writer") == 1 ]] || die "the test transaction is not open with a write in progress"
ok "a write transaction is open, its INSERT done and not yet committed"
ok "(it had to ask for READ WRITE: the setting is a default, not a lock, which is why step 5 closes the door)"
docker restart "$net-primary" >/dev/null
wait_for primary

step "Runbook step 3: verify the fence"
[[ $(sql primary "SHOW default_transaction_read_only") == on ]] || die "the setting is not on"
ok "default_transaction_read_only is on"
[[ $(sql primary "SELECT pg_postmaster_start_time() > '$set_at'") == t ]] || die "no restart after the setting was in force"
ok "the database restarted after the setting was in force"
if sql primary "INSERT INTO visits VALUES ('after the restart')" >/dev/null 2>&1; then die "a write was accepted"; fi
ok "a write is refused"
[[ $(sql primary "SELECT count(*) FROM visits WHERE note = 'never committed'") == 0 ]] || die "an open transaction survived the restart"
ok "the transaction that was open across the restart was rolled back"

step "Runbook step 4: the primary's final position, and the replica catching up to it"
# The runbook's check for sessions that are writing or holding a transaction open.
writers="SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() AND (backend_xid IS NOT NULL OR state LIKE 'idle in transaction%')"
[[ $(sql primary "$writers") == 0 ]] || die "a session is still writing"
ok "no session is writing or holding a transaction open"
# The limit the runbook states: a client that explicitly asks for read-write can still
# write. This is why the fence is only complete when no client does that.
sql primary "BEGIN READ WRITE; INSERT INTO visits VALUES ('explicit override'); COMMIT" >/dev/null \
  || die "expected an explicit read-write transaction to succeed"
ok "(limit, shown on purpose: an explicit BEGIN READ WRITE still commits. The demo backend never does this)"
lsn=$(sql primary "SELECT pg_current_wal_lsn()")
[[ $lsn =~ ^[0-9A-F]+/[0-9A-F]+$ ]] || die "not a WAL position: $lsn"
for _ in $(seq 1 30); do
  [[ $(sql replica "SELECT pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn") == t ]] && caught_up=1 && break
  sleep 1
done
[[ ${caught_up:-0} == 1 ]] || die "the replica never reached $lsn"
ok "the replica has replayed past the primary's final position ($lsn)"
[[ $(sql replica "SELECT count(*) FROM visits") == $(sql primary "SELECT count(*) FROM visits") ]] || die "row counts differ"
ok "both hold the same rows ($(sql replica "SELECT count(*) FROM visits"))"

step "Runbook step 6: promote the replica"
sql replica "SELECT pg_promote()" >/dev/null
for _ in $(seq 1 30); do [[ $(sql replica "SELECT pg_is_in_recovery()") == f ]] && break; sleep 1; done
[[ $(sql replica "SELECT pg_is_in_recovery()") == f ]] || die "the replica was not promoted"
sql replica "INSERT INTO visits VALUES ('after the failover')" >/dev/null || die "the promoted database refused a write"
ok "the promoted database accepts writes"
if sql primary "INSERT INTO visits VALUES ('split brain')" >/dev/null 2>&1; then die "the old primary accepted a write"; fi
ok "the old primary still refuses writes: one writer only"

printf '\nThe database steps of the runbook behaved as written.\n'
