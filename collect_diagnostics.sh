#!/usr/bin/env bash
# Collects read-only diagnostics from a Hadoop / HDFS / Hive cluster for storage
# capacity assessment and hardware upgrade planning.
# Every command is recorded together with its output and exit code, under section
# headers with stable IDs (H1-H8 per machine, C1-C7 per cluster, M1-M3 monitoring).
#
# Usage:
#   On EACH machine:                         sudo bash collect_diagnostics.sh
#   On ONE machine only (e.g. the NameNode): sudo bash collect_diagnostics.sh --cluster
#   On EACH machine, during a heavy job:     sudo bash collect_diagnostics.sh --monitor <minutes>
#
# The --cluster option adds the HDFS, Hive and YARN checks. They describe the
# whole cluster, so running them once is enough.
#
# The --monitor option only records CPU, memory, disk and network usage every
# INTERVAL seconds for the given number of minutes. Start it on every machine at
# the same time as a representative heavy job, to see which resource limits it.
#
# Settings (override as environment variables if the defaults do not match):
#   HDFS_USER        user with HDFS superuser rights             (default: hdfs)
#   HIVE_USER        user allowed to query Hive                  (default: hive)
#   BEELINE_URL      Hive JDBC URL                               (default: jdbc:hive2://localhost:10000)
#   HADOOP_CONF_DIR  Hadoop configuration directory              (default: /etc/hadoop/conf)
#   ORC_FILE         HDFS path of one ORC file from a main table (optional)
#   TIMEOUT          seconds before a single command is stopped  (default: 900)
#   INTERVAL         seconds between samples in --monitor mode   (default: 5)
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
INTERVAL="${INTERVAL:-5}"

CLUSTER=0
MONITOR_MINUTES=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster) CLUSTER=1 ;;
        --monitor)
            MONITOR_MINUTES="${2:-}"
            [[ "$MONITOR_MINUTES" =~ ^[1-9][0-9]*$ ]] || { echo "Usage: --monitor <minutes>" >&2; exit 1; }
            shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

# Hadoop commands run as HDFS_USER (simple authentication), since some reports need HDFS superuser rights.
export HADOOP_USER_NAME="$HDFS_USER"

OUT="capacity_audit_$(hostname -s)_$(date +%Y%m%d_%H%M).txt"

section() {
    printf '\n\n==================== %s ====================\n' "$1"
    echo "Collecting: $1" >&2
}

# For fixed commands written in this script only; never pass values read from the system.
run() {
    printf '\n$ %s\n' "$1"
    # stdin from /dev/null: tools like beeline otherwise consume the table list being looped over
    timeout "$TIMEOUT" bash -c "$1" </dev/null 2>&1
    printf '[exit code: %s]\n' "$?"
}

# For commands that include values read from the system (table names, HDFS paths).
# The command runs as an argument list, without a shell, so those values cannot inject
# commands. Usage: run_args <filter> cmd arg...  (filter: a fixed pipe stage such as
# "head -40", or "" for none).
run_args() {
    local filter="$1" rc
    shift
    printf '\n$ %s%s\n' "$(printf '%q ' "$@")" "${filter:+| $filter}"
    if [[ -n "$filter" ]]; then
        timeout "$TIMEOUT" "$@" </dev/null 2>&1 | bash -c "$filter"
        rc=${PIPESTATUS[0]}
    else
        timeout "$TIMEOUT" "$@" </dev/null 2>&1
        rc=$?
    fi
    printf '[exit code: %s]\n' "$rc"
}

beeline_q() {
    timeout "$TIMEOUT" beeline -u "$BEELINE_URL" -n "$HIVE_USER" --silent=true --outputformat=tsv2 -e "$1" </dev/null 2>/dev/null
}

run_sql() {
    local filter="$1"
    shift
    run_args "$filter" beeline -u "$BEELINE_URL" -n "$HIVE_USER" --silent=true --outputformat=tsv2 -e "$1"
}

# Hive identifiers and HDFS paths come from other users' data; skip anything unusual
# rather than risk passing it on.
valid_identifier() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }
valid_hdfs_path() { [[ "$1" =~ ^(hdfs://[A-Za-z0-9._:-]+)?/[A-Za-z0-9._/=:@+,-]*$ ]]; }

monitor() {
    local samples=$(( MONITOR_MINUTES * 60 / INTERVAL ))
    local out="capacity_audit_monitor_$(hostname -s)_$(date +%Y%m%d_%H%M).txt"
    local tmp
    tmp=$(mktemp -d)
    echo "Monitoring for $MONITOR_MINUTES minutes ($samples samples every ${INTERVAL}s). Start the heavy job now." >&2

    vmstat -t "$INTERVAL" "$samples" > "$tmp/m1" 2>&1 &
    if command -v iostat >/dev/null; then
        iostat -dxmt "$INTERVAL" "$samples" > "$tmp/m2" 2>&1 &
        M2_CMD="iostat -dxmt $INTERVAL $samples"
    else
        (for ((i = 0; i < samples; i++)); do date '+%F %T'; cat /proc/diskstats; sleep "$INTERVAL"; done) > "$tmp/m2" 2>&1 &
        M2_CMD="(iostat not installed) /proc/diskstats every ${INTERVAL}s"
    fi
    if command -v sar >/dev/null; then
        sar -n DEV "$INTERVAL" "$samples" > "$tmp/m3" 2>&1 &
        M3_CMD="sar -n DEV $INTERVAL $samples"
    else
        (for ((i = 0; i < samples; i++)); do date '+%F %T'; cat /proc/net/dev; sleep "$INTERVAL"; done) > "$tmp/m3" 2>&1 &
        M3_CMD="(sar not installed) /proc/net/dev every ${INTERVAL}s"
    fi
    wait

    {
        echo "Hadoop capacity audit: resource usage during a job"
        echo "Host: $(hostname -f 2>/dev/null || hostname)"
        echo "Started: $(date -d "-$MONITOR_MINUTES min" 2>/dev/null || echo "$MONITOR_MINUTES minutes before end")"
        echo "Ended: $(date)"
        section "M1 CPU and memory" 2>/dev/null
        printf '\n$ vmstat -t %s %s\n' "$INTERVAL" "$samples"
        cat "$tmp/m1"
        section "M2 Disk activity" 2>/dev/null
        printf '\n$ %s\n' "$M2_CMD"
        cat "$tmp/m2"
        section "M3 Network traffic" 2>/dev/null
        printf '\n$ %s\n' "$M3_CMD"
        cat "$tmp/m3"
        echo
        echo "==================== Done ===================="
    } > "$out"
    rm -rf "$tmp"
    echo "Finished. Output saved to: $out" >&2
}

if [[ -n "$MONITOR_MINUTES" ]]; then
    monitor
    exit 0
fi

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
    run "for i in \$(ls /sys/class/net | grep -v '^lo$'); do echo \"--- \$i\"; ethtool \$i 2>/dev/null | grep -E 'Supported ports|Port:|Speed|Duplex|Link detected'; ethtool -i \$i 2>/dev/null | grep -E 'driver|bus-info'; done"
    run "lspci | grep -iE 'ethernet|network'"
    run "dmidecode -t slot | grep -E 'Designation|Type|Current Usage'"
    run "lldpctl 2>/dev/null || echo 'lldpctl not available (switch neighbour details not collected)'"

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

    section "H8 Memory modules and slots"
    run "dmidecode -t memory | grep -E '^\\s+(Size|Locator|Type|Speed|Configured Memory Speed|Part Number):' | grep -vE 'Bank Locator|Error'"
    run "echo \"Slots filled: \$(dmidecode -t 17 | grep -cE '^\\s+Size: [0-9]')  Slots empty: \$(dmidecode -t 17 | grep -cE '^\\s+Size: No Module')\""
    run "dmidecode -t 16 | grep -E 'Maximum Capacity|Number Of Devices'"

    if [[ $CLUSTER -eq 1 ]]; then
        section "C1 HDFS capacity and replication"
        run "hdfs dfsadmin -report"
        run "hdfs getconf -confKey dfs.replication"
        run "hdfs fsck / | tail -30"

        section "C2 HDFS space by directory, raw copies and leftovers"
        run "hdfs dfs -du -h /"
        run "hdfs dfs -ls / | awk '/^d/{print \$NF}' | while read -r d; do echo \"--- \$d\"; hdfs dfs -du -h \"\$d\" </dev/null; done"
        run "hdfs dfs -du -s -h /tmp '/user/*/.Trash'"
        run "hdfs dfs -ls -R / 2>/dev/null | grep -iE '\\.(csv|txt|gz|zip)\$' | head -50"

        section "C3 Hive databases and tables"
        TABLE_LIST=$(mktemp)
        beeline_q "SHOW DATABASES;" | grep -v '^database_name$' | while read -r db; do
            valid_identifier "$db" || { printf 'Skipping database with unexpected name: %q\n' "$db" >&2; continue; }
            beeline_q "SHOW TABLES IN \`$db\`;" | grep -v '^tab_name$' | while read -r t; do
                if valid_identifier "$t"; then echo "$db.$t"; else printf 'Skipping table with unexpected name: %q\n' "$db.$t" >&2; fi
            done
        done > "$TABLE_LIST"
        run_sql "" "SHOW DATABASES;"
        printf '\nTables found:\n'
        cat "$TABLE_LIST"
        while read -r tbl; do
            run_sql "" "DESCRIBE FORMATTED \`${tbl%%.*}\`.\`${tbl#*.}\`;"
            run_sql "sed -n '1,3p;\$p'" "SHOW PARTITIONS \`${tbl%%.*}\`.\`${tbl#*.}\`;"
        done < "$TABLE_LIST"

        section "C4 ORC compression"
        if [[ -z "$ORC_FILE" ]]; then
            ORC_FILE=$(timeout "$TIMEOUT" hdfs dfs -ls -R /user/hive/warehouse /warehouse </dev/null 2>/dev/null \
                | awk '!/^d/ && $5 > 1000000 {print $NF; exit}')
            printf 'ORC_FILE not set; using the first data file over 1MB found (may not be from a main table): %q\n' "${ORC_FILE:-none}"
        fi
        if [[ -n "$ORC_FILE" ]]; then
            if valid_hdfs_path "$ORC_FILE"; then
                run_args "head -40" hive --orcfiledump "$ORC_FILE"
            else
                printf 'Skipping ORC file with unexpected characters in its path: %q\n' "$ORC_FILE"
            fi
        fi

        section "C5 Hive execution engine and join settings"
        run_sql "" "SET hive.execution.engine; SET hive.auto.convert.join; SET hive.auto.convert.join.noconditionaltask.size; SET hive.stats.autogather;"

        section "C6 Failed and killed jobs"
        run "yarn application -list -appStates FAILED,KILLED 2>/dev/null | head -50"

        section "C7 Size per partition (daily volume and growth)"
        while read -r tbl; do
            loc=$(beeline_q "DESCRIBE FORMATTED \`${tbl%%.*}\`.\`${tbl#*.}\`;" | awk -F'\t' '/^Location/{print $2; exit}' | tr -d ' ')
            [[ -z "$loc" ]] && continue
            if valid_hdfs_path "$loc"; then
                run_args "" hdfs dfs -du "$loc"
            else
                printf '\nSkipping %s: location has unexpected characters: %q\n' "$tbl" "$loc"
            fi
        done < "$TABLE_LIST"
        rm -f "$TABLE_LIST"
    fi

    echo
    echo "==================== Done ===================="
} > "$OUT"

echo "Finished. Output saved to: $OUT" >&2
