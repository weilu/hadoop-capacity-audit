#!/usr/bin/env bash
# Collects read-only diagnostics from a Hadoop / HDFS / Hive cluster for storage
# capacity assessment and hardware upgrade planning.
# Every command is recorded together with its output and exit code, under section
# headers with stable IDs (H1-H7 per machine, C1-C7 per cluster).
#
# Usage:
#   On EACH machine:                         sudo bash collect_diagnostics.sh
#   On ONE machine only (e.g. the NameNode): sudo bash collect_diagnostics.sh --cluster
#
# The --cluster option adds the HDFS, Hive and YARN checks. They describe the
# whole cluster, so running them once is enough.
#
# Settings (override as environment variables if the defaults do not match):
#   HDFS_USER        user with HDFS superuser rights             (default: hdfs)
#   HIVE_USER        user allowed to query Hive                  (default: hive)
#   BEELINE_URL      Hive JDBC URL                               (default: jdbc:hive2://localhost:10000)
#   HADOOP_CONF_DIR  Hadoop configuration directory              (default: /etc/hadoop/conf)
#   ORC_FILE         HDFS path of one ORC file from a main table (optional)
#   TIMEOUT          seconds before a single command is stopped  (default: 900)
#
# If the cluster uses Kerberos, run `kinit` as an administrative principal first;
# HDFS_USER then has no effect.
#
# Nothing is changed on the system. No table rows are read. The output contains
# hostnames, IP addresses, paths, table names and sizes; review it before sharing.

set -u

HDFS_USER="${HDFS_USER:-hdfs}"
HIVE_USER="${HIVE_USER:-hive}"
BEELINE_URL="${BEELINE_URL:-jdbc:hive2://localhost:10000}"
HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-/etc/hadoop/conf}"
ORC_FILE="${ORC_FILE:-}"
TIMEOUT="${TIMEOUT:-900}"

CLUSTER=0
[[ "${1:-}" == "--cluster" ]] && CLUSTER=1

# Hadoop commands run as HDFS_USER (simple authentication), since some reports need HDFS superuser rights.
export HADOOP_USER_NAME="$HDFS_USER"

OUT="capacity_audit_$(hostname -s)_$(date +%Y%m%d_%H%M).txt"

section() {
    printf '\n\n==================== %s ====================\n' "$1"
    echo "Collecting: $1" >&2
}

run() {
    printf '\n$ %s\n' "$1"
    # stdin from /dev/null: tools like beeline otherwise consume the table list being looped over
    timeout "$TIMEOUT" bash -c "$1" </dev/null 2>&1
    printf '[exit code: %s]\n' "$?"
}

beeline_q() {
    timeout "$TIMEOUT" beeline -u "$BEELINE_URL" -n "$HIVE_USER" --silent=true --outputformat=tsv2 -e "$1" </dev/null 2>/dev/null
}

hive_sql() {
    echo "beeline -u '$BEELINE_URL' -n $HIVE_USER --silent=true --outputformat=tsv2 -e \"$1\""
}

{
    echo "Hadoop capacity audit: collected output"
    echo "Host: $(hostname -f 2>/dev/null || hostname)"
    echo "Date: $(date)"
    echo "Mode: $([[ $CLUSTER -eq 1 ]] && echo 'host + cluster checks' || echo 'host checks only')"

    section "H1 Virtual machine or physical server"
    run "dmidecode -s system-manufacturer; dmidecode -s system-product-name"
    run "systemd-detect-virt"
    run "virsh list --all"

    section "H2 Software versions"
    run "cat /etc/os-release"
    run "uname -r"
    run "hadoop version"
    run "hive --version"
    run "ls -d /opt/cloudera /usr/hdp /opt/*hadoop* /opt/*hive* /usr/local/*hadoop* /usr/local/*hive* 2>/dev/null"

    section "H3 Server model and serial number"
    run "dmidecode -t system | grep -E 'Manufacturer|Product Name|Serial Number|SKU'"

    section "H4 Disks, bays and RAID (HPE Smart Array via ssacli)"
    run "ssacli ctrl all show config"
    run "ssacli ctrl all show config detail | grep -iE 'Slot|logicaldrive|RAID|physicaldrive|Interface Type|Drive Type|Rotational Speed|Size|Model|Box|Bay'"
    run "lsblk -o NAME,SIZE,TYPE,ROTA,MODEL,MOUNTPOINT"

    section "H5 Network and PCIe slots"
    run "ip -br link"
    run "ip -br addr"
    run "cat /proc/net/bonding/* 2>/dev/null || echo 'No bonded interfaces'"
    run "for i in \$(ls /sys/class/net | grep -v '^lo$'); do echo \"--- \$i\"; ethtool \$i 2>/dev/null | grep -E 'Speed|Duplex|Link detected'; done"
    run "dmidecode -t slot | grep -E 'Designation|Type|Current Usage'"

    section "H6 Local disk usage and temporary file locations"
    run "df -hT"
    run "du -h --max-depth=2 /data /home /mnt /opt /var/log 2>/dev/null | sort -h | tail -30"
    run "grep -A1 -E 'yarn.nodemanager.local-dirs|yarn.nodemanager.log-dirs' $HADOOP_CONF_DIR/yarn-site.xml"
    run "grep -A1 -E 'hadoop.tmp.dir' $HADOOP_CONF_DIR/core-site.xml"
    run "grep -A1 -E 'dfs.datanode.data.dir|dfs.namenode.name.dir' $HADOOP_CONF_DIR/hdfs-site.xml"

    section "H7 Memory and CPU available to YARN on this machine"
    run "free -h"
    run "nproc"
    run "grep -A1 -E 'yarn.nodemanager.resource.memory-mb|yarn.nodemanager.resource.cpu-vcores|yarn.scheduler.maximum-allocation-mb' $HADOOP_CONF_DIR/yarn-site.xml"
    run "jps 2>/dev/null || ps -eo args | grep -oE '(NameNode|DataNode|ResourceManager|NodeManager|HiveServer2|HiveMetaStore)' | sort -u"

    if [[ $CLUSTER -eq 1 ]]; then
        section "C1 HDFS capacity and replication"
        run "hdfs dfsadmin -report"
        run "hdfs getconf -confKey dfs.replication"
        run "hdfs fsck / | tail -30"

        section "C2 HDFS space by directory, raw copies and leftovers"
        run "hdfs dfs -du -h /"
        run "for d in \$(hdfs dfs -ls / | awk '/^d/{print \$NF}'); do echo \"--- \$d\"; hdfs dfs -du -h \$d; done"
        run "hdfs dfs -du -s -h /tmp '/user/*/.Trash'"
        run "hdfs dfs -ls -R / 2>/dev/null | grep -iE '\\.(csv|txt|gz|zip)\$' | head -50"

        section "C3 Hive databases and tables"
        TABLE_LIST=$(mktemp)
        beeline_q "SHOW DATABASES;" | grep -v '^database_name$' | while read -r db; do
            beeline_q "SHOW TABLES IN \`$db\`;" | grep -v '^tab_name$' | sed "s/^/$db./"
        done > "$TABLE_LIST"
        run "$(hive_sql 'SHOW DATABASES;')"
        printf '\nTables found:\n'
        cat "$TABLE_LIST"
        while read -r tbl; do
            run "$(hive_sql "DESCRIBE FORMATTED $tbl;")"
            run "$(hive_sql "SHOW PARTITIONS $tbl;") | sed -n '1,3p;\$p'"
        done < "$TABLE_LIST"

        section "C4 ORC compression"
        if [[ -z "$ORC_FILE" ]]; then
            ORC_FILE=$(timeout "$TIMEOUT" hdfs dfs -ls -R /user/hive/warehouse /warehouse </dev/null 2>/dev/null \
                | awk '!/^d/ && $5 > 1000000 {print $NF; exit}')
            echo "ORC_FILE not set; using the first data file over 1MB found (may not be from a main table): ${ORC_FILE:-none}"
        fi
        [[ -n "$ORC_FILE" ]] && run "hive --orcfiledump $ORC_FILE | head -40"

        section "C5 Hive execution engine and join settings"
        run "$(hive_sql 'SET hive.execution.engine; SET hive.auto.convert.join; SET hive.auto.convert.join.noconditionaltask.size; SET hive.stats.autogather;')"

        section "C6 Failed and killed jobs"
        run "yarn application -list -appStates FAILED,KILLED 2>/dev/null | head -50"

        section "C7 Size per partition (daily volume and growth)"
        while read -r tbl; do
            loc=$(beeline_q "DESCRIBE FORMATTED $tbl;" | awk -F'\t' '/^Location/{print $2; exit}' | tr -d ' ')
            [[ -n "$loc" ]] && run "hdfs dfs -du $loc"
        done < "$TABLE_LIST"
        rm -f "$TABLE_LIST"
    fi

    echo
    echo "==================== Done ===================="
} > "$OUT"

echo "Finished. Output saved to: $OUT" >&2
