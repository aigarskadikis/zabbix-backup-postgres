#!/bin/bash

year=$(date +%Y)
month=$(date +%m)
day=$(date +%d)
clock=$(date +%H%M)
volume=/backup/postgres
dest=$volume/$year/$month/$day/$clock

if [ ! -d "$dest" ]; then
  mkdir -p "$dest"
fi

echo "
pg16.int:7416
pg13.ext:7413
" | \
grep -v "^$" | \
while IFS= read -r DBSERVER
do {

DBHOST=$(echo "$DBSERVER" | grep -Eo "^[^:]+")
DBPORT=$(echo "$DBSERVER" | grep -Eo "[0-9]+$")

# grep only DB names which starts with 'z' and contains 2 digits
# all the other DB names are temporary
for DB in $(
PGHOST=$DBHOST \
PGPORT=$DBPORT \
PGPASSWORD=zabbix \
PGUSER=postgres \
psql \
--tuples-only \
--no-align \
--command="
SELECT datname FROM pg_database 
WHERE datname NOT IN ('template0','template1','postgres','dummy_db')
" | \
grep "^z[0-9][0-9]$"
) ; do
echo $DB

# clean not an exciting data
PGHOST=$DBHOST \
PGPORT=$DBPORT \
PGUSER=postgres \
PGPASSWORD=zabbix \
psql $DB \
--command="

DELETE FROM events WHERE events.source=3 AND events.object=4 AND events.objectid NOT IN (SELECT itemid FROM items);

DELETE FROM events WHERE source=0 AND object=0 AND objectid NOT IN (SELECT triggerid FROM triggers);

DELETE FROM events WHERE source = 3 AND object = 0 AND objectid NOT IN (SELECT triggerid FROM triggers);

DELETE FROM events WHERE source > 0;

DELETE FROM auditlog;

DELETE FROM history WHERE itemid NOT IN (SELECT itemid FROM items);
DELETE FROM history_uint WHERE itemid NOT IN (SELECT itemid FROM items);
DELETE FROM history_str WHERE itemid NOT IN (SELECT itemid FROM items);
DELETE FROM history_log WHERE itemid NOT IN (SELECT itemid FROM items);
DELETE FROM history_text WHERE itemid NOT IN (SELECT itemid FROM items);
DELETE FROM trends WHERE itemid NOT IN (SELECT itemid FROM items);
DELETE FROM trends_uint WHERE itemid NOT IN (SELECT itemid FROM items);

"

# backup database without hypertables
# use contom format (which is compressed by default
PGHOST=$DBHOST \
PGPORT=$DBPORT \
PGUSER=postgres \
PGPASSWORD=zabbix \
pg_dump \
--dbname=$DB \
--format=custom \
--blobs \
--exclude-table-data '*.history*' \
--exclude-table-data '*.trends*' \
--exclude-table-data='_timescaledb_internal._hyper*' \
--file=$dest/$DB.pg_dump.custom

# backup raw data individually
echo "
history_str
history_text
trends
trends_uint
" | \
grep -v "^$" | \
while IFS= read -r TABLE
do {
PGHOST=$DBHOST \
PGPORT=$DBPORT \
PGUSER=postgres \
PGPASSWORD=zabbix \
psql --dbname=$DB \
-c "COPY (SELECT * FROM $TABLE) TO stdout DELIMITER ',' CSV" | \
xz > $dest/$DB.$TABLE.csv.xz
} done
# end of table by table

# end per database
done

} done
# end per PostgreSQ server

# remove older files than 30 days
echo -e "\nThese files will be deleted:"
find /backup/postgres -type f -mtime +25
# delete files
find /backup/postgres -type f -mtime +25 -delete

echo -e "\nRemoving empty directories:"
find /backup/postgres -type d -empty -print
# delete empty directories
find /backup/postgres -type d -empty -print -delete


