#!/usr/bin/env bash
set -euo pipefail
DB=ota-community-edition-db-1
OUT=~/dr-mig
PRE=~/dr-mig-pre
rm -rf "$PRE"; cp -r "$OUT" "$PRE"

echo "=== migrations present: $(ls "$PRE"/V*.sql | wc -l) (expect 40) ==="
# Only fix: strip the lone inline no-op REFERENCES in V7 (MariaDB 10.11 enforces it; Device stays utf8_bin)
sed -i 's/ REFERENCES Device(uuid)//' "$PRE/V7__group_members.sql"

docker exec -i "$DB" mariadb --skip-ssl -uroot -proot -e "DROP DATABASE IF EXISTS drschema; CREATE DATABASE drschema;"

echo "=== applying V1..V40 in version order ==="
for f in $(ls "$PRE"/*.sql | sort -V); do
  name=$(basename "$f")
  docker exec -i "$DB" mariadb --skip-ssl -uroot -proot drschema < "$f" 2>/tmp/mig.err \
    && echo "  OK  $name" || { echo "  FAIL $name"; cat /tmp/mig.err; exit 1; }
done

echo ""
echo "=== tables (expect 17 incl DeviceHibernationStatus) ==="
docker exec -i "$DB" mariadb --skip-ssl -uroot -proot drschema -e "SHOW TABLES;" | tail -n +2 | tr '\n' ' '; echo
echo "trigger present:"
docker exec -i "$DB" mariadb --skip-ssl -uroot -proot drschema -e "SHOW TRIGGERS\G" | grep -E "Trigger:|Table:" | head

echo ""
echo "=== dump: schema + seed data, compact, NO triggers (Flyway-friendly) ==="
docker exec "$DB" mariadb-dump --skip-ssl -uroot -proot --compact --skip-triggers --no-tablespaces \
  --skip-add-locks --skip-disable-keys drschema > ~/dr_schema_compact.sql
echo "dump lines: $(wc -l < ~/dr_schema_compact.sql), create-tables: $(grep -c 'CREATE TABLE' ~/dr_schema_compact.sql), inserts: $(grep -c 'INSERT INTO' ~/dr_schema_compact.sql)"
