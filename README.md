# hadoop-capacity-audit

A read-only diagnostics script for on-premises Hadoop / HDFS / Hive clusters. It collects the information needed to assess storage capacity, find space that can be reclaimed, and plan hardware upgrades.

Every command is written to a single text file together with its output and exit code, so the results can be reviewed by someone without access to the servers.

## What it collects

Output is grouped under sections with stable IDs, so results can be mapped to your own checklist.

**On each machine**

| ID | Section |
|---|---|
| H1 | Physical server or virtual machine |
| H2 | OS, Hadoop and Hive versions; distribution |
| H3 | Server model and serial number |
| H4 | Disks, drive bays and RAID layout (HPE Smart Array via `ssacli`) |
| H5 | Network interfaces, link speed, bonding; PCIe slots |
| H6 | Local disk usage, HDFS data directories, temporary file locations |
| H7 | Memory and CPU available to YARN; running Hadoop services |

**Once per cluster (`--cluster`)**

| ID | Section |
|---|---|
| C1 | HDFS capacity, usage per node, replication factor, block health |
| C2 | HDFS space by directory; trash; raw text files (CSV, TXT, GZ, ZIP) |
| C3 | Hive databases and tables, with `DESCRIBE FORMATTED` and partition ranges |
| C4 | ORC compression of a sample file |
| C5 | Hive execution engine and join settings |
| C6 | Failed and killed YARN applications |
| C7 | Size of every partition of every table (for volume and growth estimates) |

## Usage

Review the script first, and set the environment variables below if the defaults do not match your cluster. Adjust commands if needed.

```bash
# On each machine
sudo bash collect_diagnostics.sh

# On one machine only (e.g. the NameNode), add the cluster-wide checks
sudo bash collect_diagnostics.sh --cluster

# With custom settings
sudo HIVE_USER=analyst BEELINE_URL='jdbc:hive2://hive-host:10000' bash collect_diagnostics.sh --cluster
```

Output: `capacity_audit_<hostname>_<date>.txt` in the current directory. Run it from a directory with free space.

| Variable | Default | Purpose |
|---|---|---|
| `HDFS_USER` | `hdfs` | User with HDFS superuser rights (simple authentication only) |
| `HIVE_USER` | `hive` | User passed to beeline |
| `BEELINE_URL` | `jdbc:hive2://localhost:10000` | HiveServer2 JDBC URL |
| `HADOOP_CONF_DIR` | `/etc/hadoop/conf` | Hadoop configuration directory |
| `ORC_FILE` | *(auto)* | HDFS path of one ORC file from a main table; if unset, the first data file over 1MB in the Hive warehouse is used |
| `TIMEOUT` | `900` | Seconds before a single command is stopped |

**Kerberos:** if the cluster uses Kerberos, run `kinit` as an administrative principal before the script; `HDFS_USER` then has no effect.

### Commands not covered by the script

For anything else you run by hand (e.g. `EXPLAIN` on specific queries), record the terminal session so commands and output are both captured:

```bash
script -a manual_$(hostname -s).txt
# ... run commands ...
exit
```

## Safety

- All commands are read-only. Nothing on the system is changed.
- No table rows are read; only metadata, sizes and configuration.
- A failing command does not stop the script: its exit code is recorded and the script continues. Each command is stopped after `TIMEOUT` seconds.
- Only specific configuration keys are read from Hadoop config files, never whole files, to avoid capturing passwords.
- The output contains hostnames, IP addresses, file paths, table names and sizes. Review it before sharing.

## Requirements

Linux with bash and GNU coreutils (`timeout`). Hadoop client tools (`hdfs`, `yarn`, `beeline`, `hive`) on the PATH for the cluster checks. Hardware checks use `dmidecode`, `ethtool` and, on HPE servers, `ssacli`; missing tools are recorded as "not found" and skipped.

## License

MIT
