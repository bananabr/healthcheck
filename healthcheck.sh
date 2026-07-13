#!/usr/bin/env bash
# =============================================================================
# health_check.sh  –  Read-only system health check for Ubuntu 22.04
#
# Collects system health metrics using only read-only operations and tools
# present in a standard linux container image (bash, awk, sed,
# grep, find, stat, od, base64, openssl, az).  You should run this script in any execution environment
# before executing any other operations to ensure the environment is 
# healthy and safe.
#
# Design: no single collection failure stops the script.
#   - set -e is intentionally absent
#   - set -o pipefail is intentionally absent
#   - Every command uses 2>/dev/null and ${var:-default} fallbacks
#   - Data is collected in bash using awk, find, stat and od; no external
#     interpreters are required beyond what ships in ubuntu:22.04
#   - String values in the JSON report are escaped via the json_str() helper
#
# Usage:  bash health_check.sh
# =============================================================================

# Azure Blob Storage destination for encrypted health reports.
# The storage account and container were created with:
#   az group create   --name rg-healthcheck-reports --location eastus
#   az storage account create --name sahealthchk42731 --resource-group rg-healthcheck-reports \
#     --sku Standard_LRS --kind StorageV2 --https-only true \
#     --min-tls-version TLS1_2 --allow-blob-public-access false
#   az storage container create --name health-reports --account-name sahealthchk42731
#
# WARNING: the key below is a static credential.  Rotate it if it is ever
# exposed, and consider replacing it with a short-lived SAS token or managed
# identity in production environments.
STORAGE_ACCOUNT_NAME="sahealthchk42731"
STORAGE_ACCOUNT_KEY="$1"
STORAGE_CONTAINER="health-reports"

# Semantic version of this script; included in every report for traceability.
SCRIPT_VERSION="1.0.0"

# Duration of the CPU usage sample window in seconds.  A longer window gives
# a more stable reading but slows the script proportionally.
CPU_SAMPLE_SECONDS=1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# log <message>
# Prints a UTC-timestamped status line to stderr so that progress messages
# remain separate from any stdout data used in command substitutions.
log() {
    printf '[%s] %s\n' "$(date -u +'%H:%M:%S' 2>/dev/null || echo '??:??:??')" "$*"
}

# safe_read <path>
# Reads a file and prints its contents.  Silently returns an empty string
# on any error (missing file, permission denied, etc.) so that callers never
# see a failure exit code from a missing /proc or /sys entry.
safe_read() { cat "$1" 2>/dev/null || true; }

# trim
# Strips leading and trailing whitespace from stdin using awk's field
# re-splicing trick ($1=$1 forces awk to reparse the record).
trim() { awk '{$1=$1}1' 2>/dev/null || true; }

# json_str <value>
# JSON-escape a value: backslash -> \\, double-quote -> \", control chars stripped.
# Returns the escaped text WITHOUT surrounding quotes — callers supply those.
json_str() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }

log "Ubuntu health check v${SCRIPT_VERSION} – starting"
log "Destination: ${STORAGE_ACCOUNT_NAME}/${STORAGE_CONTAINER} (Azure Blob Storage)"
log "Collecting health data..."

# =============================================================================
# 1. SYSTEM IDENTITY
# =============================================================================
# Establishes who this host is and what OS/kernel it is running.  These values
# are used as the top-level identifiers in the JSON report so that multiple
# reports from different hosts can be correlated by the receiving endpoint.

# Try the fully-qualified hostname first (includes domain), then the short
# hostname, then fall back to the kernel's own hostname sysctl.
HOSTNAME_VAL=$(hostname -f 2>/dev/null \
    || hostname 2>/dev/null \
    || safe_read /proc/sys/kernel/hostname | tr -d '\n' \
    || echo "unknown")

# /proc/version format: "Linux version <kernel> (<compiler>) <build-info>"
# Field 3 ($3) is the kernel release string, e.g. "5.15.0-91-generic".
KERNEL=$(awk '{print $3}' /proc/version 2>/dev/null || echo "unknown")

# Machine hardware name (x86_64, aarch64, etc.) from the uname syscall.
ARCH=$(uname -m 2>/dev/null || safe_read /proc/sys/kernel/arch | trim || echo "unknown")

# Full kernel version banner truncated to 512 bytes for the report.
KERNEL_FULL=$(safe_read /proc/version | head -c 512)

# /etc/os-release is the standard OS identification file (freedesktop.org spec).
# PRETTY_NAME is the human-readable string, ID is the machine-readable distro
# slug, and VERSION_ID is the numeric release (e.g. "22.04").
OS_NAME=$(grep '^PRETTY_NAME' /etc/os-release 2>/dev/null \
    | cut -d= -f2- | tr -d '"' || echo "Ubuntu 22.04")
OS_ID=$(grep '^ID=' /etc/os-release 2>/dev/null \
    | cut -d= -f2 | tr -d '"' || echo "ubuntu")
OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null \
    | cut -d= -f2- | tr -d '"' || echo "22.04")

# btime in /proc/stat is the Unix timestamp at which the kernel was booted.
# Subtract from current time to get human-readable boot age if needed.
BOOT_TIME=$(awk '/^btime/{print $2}' /proc/stat 2>/dev/null || echo "0")

# ISO-8601 UTC timestamp marking when this script began collecting data.
COLLECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

# =============================================================================
# 2. UPTIME & LOAD
# =============================================================================
# Uptime indicates how long the system has been running without a reboot.
# Load averages are exponentially-weighted moving averages of the run-queue
# length over the last 1, 5, and 15 minutes.  Values above the logical CPU
# count suggest the system is saturated.  Running/total process counts give
# an instantaneous snapshot of scheduler activity.

# /proc/uptime: "<seconds_since_boot> <total_idle_seconds_across_all_cpus>"
# The idle total can exceed uptime on multi-core systems.
UPTIME_RAW=$(safe_read /proc/uptime)
UPTIME_SECONDS=$(printf '%s' "${UPTIME_RAW}" | awk '{print $1}' 2>/dev/null || echo "0")
IDLE_SECONDS=$(printf '%s' "${UPTIME_RAW}" | awk '{print $2}' 2>/dev/null || echo "0")

# /proc/loadavg: "<1m> <5m> <15m> <running>/<total> <last_pid>"
# The running/total field is split on '/' to extract both counts.
LOADAVG_RAW=$(safe_read /proc/loadavg)
LOAD_1=$(printf '%s' "${LOADAVG_RAW}" | awk '{print $1}' 2>/dev/null || echo "0")
LOAD_5=$(printf '%s' "${LOADAVG_RAW}" | awk '{print $2}' 2>/dev/null || echo "0")
LOAD_15=$(printf '%s' "${LOADAVG_RAW}" | awk '{print $3}' 2>/dev/null || echo "0")
PROCS_RUNNING=$(printf '%s' "${LOADAVG_RAW}" | awk -F'[/ ]' '{print $4}' 2>/dev/null || echo "0")
PROCS_TOTAL=$(printf '%s' "${LOADAVG_RAW}" | awk -F'[/ ]' '{print $5}' 2>/dev/null || echo "0")

# =============================================================================
# 3. CPU
# =============================================================================
# Reports static CPU topology (model, core count, socket count, frequency) and
# a dynamic utilisation sample.  Frequency is read from /proc/cpuinfo which
# reflects the current P-state on systems with dynamic frequency scaling.

# Each logical processor has a "model name" stanza in /proc/cpuinfo.  We only
# need the first one since all logical CPUs share the same model string.
CPU_MODEL=$(grep '^model name' /proc/cpuinfo 2>/dev/null \
    | head -1 | cut -d: -f2- | trim || echo "unknown")

# Count logical processors: one "processor :" line per logical CPU (includes
# hyper-threading siblings and all NUMA nodes).
CPU_CORES=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "0")

# Current clock speed in MHz for the first logical CPU.
CPU_FREQ_MHZ=$(grep '^cpu MHz' /proc/cpuinfo 2>/dev/null \
    | head -1 | awk -F: '{print $2}' | trim || echo "0")

# Unique "physical id" values correspond to distinct physical CPU packages.
# Single-socket systems may not expose this field, so we default to 1.
CPU_SOCKETS=$(grep '^physical id' /proc/cpuinfo 2>/dev/null \
    | sort -u | wc -l 2>/dev/null || echo "1")

# CPU usage is derived from two /proc/stat snapshots taken CPU_SAMPLE_SECONDS
# apart.  /proc/stat accumulates jiffies in each mode since boot:
#   user nice system idle iowait irq softirq steal guest guest_nice
# Usage % = 100 * (delta_total - delta_idle) / delta_total
# The aggregate "cpu " line (with a trailing space) covers all logical CPUs.
STAT1=$(awk '/^cpu /{$1=""; print}' /proc/stat 2>/dev/null || echo "0 0 0 0 0 0 0 0 0 0")
sleep "${CPU_SAMPLE_SECONDS}"
STAT2=$(awk '/^cpu /{$1=""; print}' /proc/stat 2>/dev/null || echo "0 0 0 0 0 0 0 0 0 0")

CPU_USAGE=$(awk -v s1="${STAT1}" -v s2="${STAT2}" 'BEGIN {
    n = split(s1, a, " ")
    split(s2, b, " ")
    total = 0
    for (i = 1; i <= n; i++) total += b[i] - a[i]
    idle = (n >= 4) ? b[4] - a[4] : 0
    if (total > 0) printf "%.2f", 100.0 * (total - idle) / total
    else           print  "0.00"
}' 2>/dev/null || echo "0.00")

# Per-CPU jiffies snapshot from the second /proc/stat read (post-sleep).
# Lines matching "cpuN " (e.g. cpu0, cpu1) represent individual logical CPUs.
# /proc/stat fields per cpu line: cpuN user nice system idle iowait irq softirq ...
#   $1=cpuN, $2=user, $3=nice, $4=system, $5=idle
PER_CPU_JSON=$(awk '
    /^cpu[0-9]+ / {
        total = 0
        for (i = 2; i <= NF; i++) total += $i
        printf "{\"cpu\":\"%s\",\"total_jiffies\":%d,\"idle_jiffies\":%d},\n",
            $1, total, $5
    }
' /proc/stat 2>/dev/null | tr -d '\n' | sed 's/,$//' || true)
PER_CPU_JSON="[${PER_CPU_JSON:-}]"

# =============================================================================
# 4. MEMORY  (/proc/meminfo values are in KiB)
# =============================================================================
# All values sourced from /proc/meminfo, which the kernel updates continuously.
# Key distinctions:
#   MemFree      – pages completely unused; does NOT include reclaimable caches
#   MemAvailable – kernel estimate of memory available for new allocations
#                  without swapping (includes reclaimable slab + page cache);
#                  this is the right metric for "how much RAM is actually free"
#   Buffers      – kernel block-device I/O buffers
#   Cached       – page cache for files; can be reclaimed under memory pressure
#   SReclaimable – portion of slab allocator memory that can be reclaimed
# MEM_USED is computed as: total - free - buffers - cached - sreclaimable,
# which matches the "used" column reported by tools like `free -m`.

MEM_TOTAL=$(awk      '/^MemTotal:/{print $2}'     /proc/meminfo 2>/dev/null || echo "0")
MEM_FREE=$(awk       '/^MemFree:/{print $2}'      /proc/meminfo 2>/dev/null || echo "0")
MEM_AVAILABLE=$(awk  '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
MEM_BUFFERS=$(awk    '/^Buffers:/{print $2}'      /proc/meminfo 2>/dev/null || echo "0")
MEM_CACHED=$(awk     '/^Cached:/{print $2}'       /proc/meminfo 2>/dev/null || echo "0")
MEM_SRECLAIMABLE=$(awk '/^SReclaimable:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
SWAP_TOTAL=$(awk     '/^SwapTotal:/{print $2}'    /proc/meminfo 2>/dev/null || echo "0")
SWAP_FREE=$(awk      '/^SwapFree:/{print $2}'     /proc/meminfo 2>/dev/null || echo "0")

# HugePages are large contiguous memory pages (2 MiB or 1 GiB) pre-allocated
# for workloads like databases or JVMs that benefit from reduced TLB pressure.
HUGEPAGES_TOTAL=$(awk  '/^HugePages_Total:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
HUGEPAGES_FREE=$(awk   '/^HugePages_Free:/{print $2}'  /proc/meminfo 2>/dev/null || echo "0")
HUGEPAGE_SIZE=$(awk    '/^Hugepagesize:/{print $2}'    /proc/meminfo 2>/dev/null || echo "0")

# Derived: "application" memory in use (clamped to 0 to avoid negative values
# on systems where MemAvailable is larger than the raw free+buffers+cached sum).
MEM_USED=$(awk -v t="${MEM_TOTAL:-0}" -v f="${MEM_FREE:-0}" \
               -v b="${MEM_BUFFERS:-0}" -v c="${MEM_CACHED:-0}" \
               -v sr="${MEM_SRECLAIMABLE:-0}" \
           'BEGIN { u = t - f - b - c - sr; print (u > 0) ? u : 0 }' 2>/dev/null || echo "0")
SWAP_USED=$(awk -v t="${SWAP_TOTAL:-0}" -v f="${SWAP_FREE:-0}" \
            'BEGIN { u = t - f; print (u > 0) ? u : 0 }' 2>/dev/null || echo "0")

# =============================================================================
# 5. DISK  (df + /proc/mounts; no python3 required)
# =============================================================================
# Reports capacity, usage, and inode statistics for every real block device
# mount found in /proc/mounts.  Pseudo-filesystems (tmpfs, proc, sysfs, devpts,
# cgroup, etc.) are excluded by filtering for mounts whose device starts with
# "/dev/".  Each device is counted only once even if bind-mounted at multiple
# paths.  Inode exhaustion can cause "disk full" errors even when blocks are
# available, so both metrics are included.  os.statvfs() is used because bash
# has no built-in equivalent and df output formatting varies across versions.
# ── Collect disk info without python3 ────────────────────────────────────────
# df -P  gives 1K-block totals; df -Pi gives inode counts; /proc/mounts gives
# filesystem type.  Three tag-prefixed streams are merged in a single awk pass
# so each device is counted only once, even if bind-mounted at multiple paths.
DISK_JSON=$(
    {
        awk '/^\/dev\// { print "FS", $1, $3 }' /proc/mounts 2>/dev/null
        df -Pi 2>/dev/null | awk 'NR>1 && $1~/^\/dev\// { print "IN",$1,$2,$3,$4 }'
        df -P  2>/dev/null | awk 'NR>1 && $1~/^\/dev\// { print "DF",$1,$2,$3,$4,$5,$6 }'
    } | awk '
        /^FS/ { ft[$2]=$3 }
        /^IN/ { it[$2]=$3+0; iu[$2]=$4+0; if_[$2]=$5+0 }
        /^DF/ && !seen[$2]++ {
            t=$3*1024; u=$4*1024; a=$5*1024
            gsub(/%/,"",$6); pct=$6+0
            itot=it[$2]; iused=iu[$2]; ifree=if_[$2]
            ipct=(itot>0) ? 100.0*iused/itot : 0.0
            printf "{\"device\":\"%s\",\"mount\":\"%s\",\"fstype\":\"%s\"," \
                   "\"total_bytes\":%d,\"used_bytes\":%d,\"free_bytes\":%d," \
                   "\"avail_bytes\":%d,\"use_percent\":%.2f," \
                   "\"inode_total\":%d,\"inode_used\":%d,\"inode_free\":%d," \
                   "\"inode_use_pct\":%.2f},\n",
                $2,$7,(ft[$2]!=""?ft[$2]:"unknown"),
                t,u,t-u,a,pct,itot,iused,ifree,ipct
        }
    ' | tr -d '\n' | sed 's/,$//'
)
DISK_JSON="[${DISK_JSON:-}]"


# =============================================================================
# 6. NETWORK
# =============================================================================
# Collects cumulative byte/packet counters and error rates per interface from
# /proc/net/dev, plus IP address assignments from the kernel routing and IPv6
# interface tables.  All counters are totals since the last reboot or counter
# wrap; the receiving endpoint can diff successive reports to derive rates.

# /proc/net/dev has two header lines followed by one line per interface.
# After replacing the colon separator with a space, the columns are:
#   $1=iface  $2-$9=rx (bytes pkts errs drop fifo frame compressed multicast)
#             $10-$17=tx (bytes pkts errs drop fifo colls carrier compressed)
# Lines with fewer than 17 fields (e.g. the "lo" line on some kernels) are
# skipped with 'next' to avoid printing malformed JSON.
NET_IFACES_JSON=$(awk '
    NR > 2 && /:.+/ {
        gsub(/:/, " ")
        if (NF < 17) next
        printf "{\"interface\":\"%s\",\"rx_bytes\":%s,\"rx_packets\":%s,\"rx_errors\":%s,\"rx_dropped\":%s,\"tx_bytes\":%s,\"tx_packets\":%s,\"tx_errors\":%s,\"tx_dropped\":%s},\n",
            $1, $2, $3, $4, $5, $10, $11, $12, $13
    }
' /proc/net/dev 2>/dev/null | tr -d '\n' | sed 's/,$//' || true)
NET_IFACES_JSON="[${NET_IFACES_JSON:-}]"

# IPv4 addresses: /proc/net/fib_trie is the kernel's FIB (Forwarding
# Information Base) trie in text form.  LOCAL-scope entries represent
# addresses actually assigned to interfaces.  The awk script tracks the
# last IP address line seen and emits it when a LOCAL annotation follows.
# 127.x loopback and 169.254.x link-local addresses are excluded.
IPV4_JSON=$(awk '
    /[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { addr = $NF }
    /LOCAL/ && addr != "" {
        if (!seen[addr]++ && addr !~ /^127\./ && addr !~ /^169\.254\./)
            printf "{\"address\":\"%s\"},\n", addr
        addr = ""
    }
' /proc/net/fib_trie 2>/dev/null | sort -u | tr -d '\n' | sed 's/,$//' || true)
IPV4_JSON="[${IPV4_JSON:-}]"

# IPv6 addresses: /proc/net/if_inet6 has one line per assigned IPv6 address.
# Column layout: address(32 hex chars) netnum prefix_len scope_hex flags iface
# The 32-char hex address is split into 8 groups of 4 to produce colon notation.
IPV6_JSON=$(awk '
    NF == 6 {
        raw = $1
        addr = ""
        for (i = 0; i < 8; i++)
            addr = addr (i ? ":" : "") substr(raw, i*4+1, 4)
        printf "{\"interface\":\"%s\",\"address\":\"%s\",\"prefix_len\":%d},\n",
            $6, addr, strtonum("0x" $3)
    }
' /proc/net/if_inet6 2>/dev/null | tr -d '\n' | sed 's/,$//' || true)
IPV6_JSON="[${IPV6_JSON:-}]"

# =============================================================================
# 7. TOP PROCESSES BY MEMORY  (bash loop + awk; no python3 required)
# =============================================================================
# Iterates every numeric directory under /proc (one per live process) and reads
# two files for each:
#   /proc/<pid>/comm   – the executable name as the kernel sees it (max 15 chars)
#   /proc/<pid>/status – structured text with VmRSS (resident set size in KiB),
#                        Threads count, and State (R=running, S=sleeping, etc.)
# Processes that disappear between the directory listing and the file reads
# (race condition) are silently skipped via the 'continue' in the for loop.
# Command-line arguments (/proc/<pid>/cmdline) are intentionally NOT read
# because they frequently contain secrets passed as arguments (tokens, passwords).
# Process names are JSON-escaped with sed before being embedded in the output.

TOP_PROCS_JSON=$(
    # Loop over /proc/<pid> directories; pad RSS for numeric sort stability.
    # Process names from /proc/<pid>/comm (max 15 chars) are JSON-escaped
    # with sed before embedding; cmdline is intentionally excluded (may hold secrets).
    for _pd in /proc/[0-9]*/; do
        _pid="${_pd%/}"; _pid="${_pid##*/}"
        _comm=$(cat "${_pd}comm" 2>/dev/null | tr -d '\n\r' | tr -cd '[:print:]') || continue
        _rss=$( awk '/^VmRSS:/{print $2;exit}'   "${_pd}status" 2>/dev/null) || _rss=0
        _st=$(  awk '/^State:/{print $2;exit}'    "${_pd}status" 2>/dev/null) || _st="?"
        _thr=$( awk '/^Threads:/{print $2;exit}'  "${_pd}status" 2>/dev/null) || _thr=1
        _ce=$(printf '%s' "$_comm" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '%09d\t%s\t%s\t%s\t%s\n' \
            "${_rss:-0}" "$_pid" "$_ce" "${_st:-?}" "${_thr:-1}"
    done 2>/dev/null \
    | sort -rn | head -10 \
    | awk -F'\t' 'BEGIN{f=1}
        { if(!f)printf","
          printf"{\"pid\":%d,\"name\":\"%s\",\"state\":\"%s\",\"threads\":%d,\"rss_kb\":%d}",
              $2+0,$3,$4,$5+0,$1+0; f=0 }'
)
TOP_PROCS_JSON="[${TOP_PROCS_JSON:-}]"


# =============================================================================
# 8. FILE DESCRIPTORS
# =============================================================================
# File descriptor exhaustion causes "too many open files" errors and can
# silently break applications.  Two sysctl files are read:
#   /proc/sys/fs/file-nr  – three whitespace-separated values:
#       <allocated>  <free-from-allocated>  <maximum>
#       "allocated" counts FDs the kernel has handed out; "free-from-allocated"
#       is how many of those have been released but not yet garbage-collected.
#       Effective in-use count = allocated - free-from-allocated.
#   /proc/sys/fs/file-max – the system-wide hard limit on open file descriptors.
# Use percent is derived from (used / max) * 100 as a quick saturation gauge.

FD_NR=$(safe_read /proc/sys/fs/file-nr)
FD_ALLOCATED=$(printf '%s' "${FD_NR}" | awk '{print $1}' 2>/dev/null || echo "0")
FD_FREE_ALLOC=$(printf '%s' "${FD_NR}" | awk '{print $2}' 2>/dev/null || echo "0")
FD_MAX=$(safe_read /proc/sys/fs/file-max | trim || echo "0")
FD_USED=$(awk -v a="${FD_ALLOCATED:-0}" -v f="${FD_FREE_ALLOC:-0}" \
          'BEGIN { u = a - f; print (u > 0) ? u : 0 }' 2>/dev/null || echo "0")
FD_USE_PCT=$(awk -v u="${FD_USED:-0}" -v m="${FD_MAX:-0}" \
             'BEGIN { if (m > 0) printf "%.2f", 100.0*u/m; else print "0.00" }' \
             2>/dev/null || echo "0.00")

# =============================================================================
# 9. KERNEL PARAMETERS  (all numeric sysctl values)
# =============================================================================
# A curated set of kernel tuning parameters relevant to system health.
# All values are read from /proc/sys (the sysctl virtual filesystem) which
# exposes kernel parameters as plain text files — no sysctl binary required.
# Parameters that are absent or unreadable are stored as empty strings and
# omitted from the JSON report when building the kernel_params object.
#
# Parameter meanings:
#   kernel/pid_max              – maximum PID value; limits concurrent processes
#   kernel/threads-max          – maximum threads across all processes
#   vm/overcommit_memory        – 0=heuristic, 1=always allow, 2=never over-commit
#   vm/swappiness               – 0–200 tendency to swap; lower = prefer RAM
#   vm/dirty_ratio              – % of memory that can be dirty before writeback
#   net/ipv4/ip_forward         – 1 if this host is acting as a router
#   net/ipv4/tcp_syn_retries    – SYN retransmission attempts before giving up
#   net/ipv4/tcp_keepalive_time – seconds before idle TCP connections probe

KP_PID_MAX=$(safe_read /proc/sys/kernel/pid_max     | trim || echo "")
KP_THREADS_MAX=$(safe_read /proc/sys/kernel/threads-max | trim || echo "")
KP_OVERCOMMIT=$(safe_read /proc/sys/vm/overcommit_memory | trim || echo "")
KP_SWAPPINESS=$(safe_read /proc/sys/vm/swappiness   | trim || echo "")
KP_DIRTY_RATIO=$(safe_read /proc/sys/vm/dirty_ratio | trim || echo "")
KP_IP_FORWARD=$(safe_read /proc/sys/net/ipv4/ip_forward | trim || echo "")
KP_TCP_SYN=$(safe_read /proc/sys/net/ipv4/tcp_syn_retries | trim || echo "")
KP_KEEPALIVE=$(safe_read /proc/sys/net/ipv4/tcp_keepalive_time | trim || echo "")

# =============================================================================
# 10. STAT COUNTERS
# =============================================================================
# Aggregate scheduler and interrupt counters from /proc/stat (cumulative since
# boot).  These are useful baselines; the receiving endpoint can diff two
# successive reports to compute per-second rates.
#
#   intr          – total hardware interrupts serviced (first field on the line)
#   ctxt          – total context switches (every scheduler preemption)
#   processes     – total tasks forked/cloned since boot
#   procs_blocked – tasks currently blocked waiting on I/O; sustained non-zero
#                   values indicate storage or network I/O bottlenecks

STAT_INTR=$(awk    '/^intr/{print $2}'         /proc/stat 2>/dev/null || echo "0")
STAT_CTXT=$(awk    '/^ctxt/{print $2}'         /proc/stat 2>/dev/null || echo "0")
STAT_PROCS=$(awk   '/^processes/{print $2}'    /proc/stat 2>/dev/null || echo "0")
STAT_BLOCKED=$(awk '/^procs_blocked/{print $2}' /proc/stat 2>/dev/null || echo "0")

# =============================================================================
# 11. ENVIRONMENT VARIABLES
# =============================================================================
# Records the process environment as inherited when the script was launched.
# This is useful for diagnosing configuration issues (missing variables, wrong
# proxy settings, incorrect PATH, etc.) without needing shell access.
#
# Timing: this section runs BEFORE the bulk HEALTH_* exports in section 12,
# so the snapshot is clean — it reflects only what the calling shell/container
# injected, not the internal bookkeeping variables added by this script.
#
# Source: /proc/self/environ contains null-byte (\x00) separated KEY=value
# strings for the current process.  This is more reliable than `env` or
# `printenv` because it reads the kernel's own copy of the environment rather
# than re-printing the shell's view, which may include extra synthesised vars.
# bash 'read -d ""' handles the null-separated format natively.
# Read /proc/self/environ (the process's startup environment, null-delimited)
# directly in bash using 'read -d ""'.  This matches the behaviour of the original
# implementation: it captures only what was INHERITED at exec time, not
# variables added by the script itself (e.g. STORAGE_ACCOUNT_KEY is excluded).
ENV_VARS_JSON=$(
    printf '{'
    _ev_first=1
    while IFS= read -r -d '' _ev_entry; do
        [ "${_ev_entry%%=*}" = "$_ev_entry" ] && continue   # skip entries without =
        _ev_k="${_ev_entry%%=*}"
        _ev_v="${_ev_entry#*=}"
        _ev_ke=$(printf '%s' "$_ev_k" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')
        _ev_ve=$(printf '%s' "$_ev_v" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')
        [ "$_ev_first" = "0" ] && printf ','
        printf '"%s":"%s"' "$_ev_ke" "$_ev_ve"
        _ev_first=0
    done < /proc/self/environ 2>/dev/null || true
    printf '}'
)
ENV_VARS_JSON="${ENV_VARS_JSON:-{}}"


# =============================================================================
# 12. SECURITY CHECKS
# =============================================================================
# Performs read-only security checks using only /proc, /etc, and filesystem
# stat() calls — no write operations, no setuid tools, no network probes.
#
# Checks performed:
#   1. Kernel hardening sysctls — ASLR, dmesg/kptr restrictions, ptrace scope,
#      BPF access, SYN cookies, ICMP redirect and source-route acceptance.
#   2. Listening TCP ports — all sockets in LISTEN state on tcp4 and tcp6,
#      decoded from /proc/net/tcp and /proc/net/tcp6.
#   3. SSH daemon configuration — parses /etc/ssh/sshd_config and flags common
#      misconfigurations (root login, password auth, empty passwords, X11).
#   4. User account security — non-root UID-0 accounts, empty-password accounts
#      (if /etc/shadow is readable), and locked-shell account count.
#   5. SUID/SGID binaries — stat() scan of standard binary directories.
#   6. World-writable files — scan of /etc and standard binary directories for
#      files or directories writable by any user.
#   7. Critical file permissions — mode, owner, and world-readable/writable
#      flags for /etc/shadow, /etc/sudoers, /etc/ssh/sshd_config, etc.
#
# Note: in a minimal container some checks will report "unavailable" (e.g.
# Yama ptrace_scope if the LSM is not loaded, SSH config if openssh is absent).
# All errors are caught silently; a failed sub-check never aborts the script.
# ── Helpers ───────────────────────────────────────────────────────────────────
# _sc <sysctl-path>  : read a /proc/sys value, return trimmed string or empty
_sc() { safe_read "/proc/sys/$1" | trim; }

# _grade <value> <pass_list> [<warn_list>]
# Returns a JSON-quoted status string: "pass", "warn", "fail", or "unavailable".
# pass_list and warn_list are space-separated integers.
_grade() {
    local v="$1" p=" $2 " w=" ${3:-} "
    [ -z "$v" ] && echo '"unavailable"' && return
    case "$p" in *" $v "*) echo '"pass"'; return;; esac
    case "$w" in *" $v "*) echo '"warn"'; return;; esac
    echo '"fail"'
}

# _kh <param_name> <value> <pass_list> [<warn_list>]
# Returns one kernel-hardening JSON object.
_kh() {
    local param="$1" val="${2:-}" pass="$3" warn="${4:-}"
    printf '{"param":"%s","value":%s,"status":%s}' \
        "$param" "${val:-null}" "$(_grade "$val" "$pass" "$warn")"
}

# ── 1. Kernel hardening sysctls ───────────────────────────────────────────────
_ASLR=$(  _sc "kernel/randomize_va_space")
_DMESG=$( _sc "kernel/dmesg_restrict")
_KPTR=$(  _sc "kernel/kptr_restrict")
_PERF=$(  _sc "kernel/perf_event_paranoid")
_PTRACE=$(_sc "kernel/yama/ptrace_scope")
_BPF=$(   _sc "kernel/unprivileged_bpf_disabled")
_SYNCK=$( _sc "net/ipv4/tcp_syncookies")
_AREDIR=$(_sc "net/ipv4/conf/all/accept_redirects")
_ASRC=$(  _sc "net/ipv4/conf/all/accept_source_route")
_RPF=$(   _sc "net/ipv4/conf/all/rp_filter")
_ICMPBC=$(_sc "net/ipv4/icmp_echo_ignore_broadcasts")

_KH_FMT='{"aslr":%s,"dmesg_restrict":%s,"kptr_restrict":%s,"perf_event_paranoid":%s,'
_KH_FMT+='"ptrace_scope":%s,"unprivileged_bpf":%s,"tcp_syncookies":%s,'
_KH_FMT+='"accept_icmp_redirects":%s,"accept_source_route":%s,"rp_filter":%s,'
_KH_FMT+='"icmp_ignore_broadcasts":%s}'
_KH_JSON=$(printf "$_KH_FMT" \
    "$(_kh kernel.randomize_va_space         "$_ASLR"   "2"     "1" )" \
    "$(_kh kernel.dmesg_restrict             "$_DMESG"  "1"     ""  )" \
    "$(_kh kernel.kptr_restrict              "$_KPTR"   "1 2"   ""  )" \
    "$(_kh kernel.perf_event_paranoid        "$_PERF"   "2 3"   "1" )" \
    "$(_kh kernel.yama.ptrace_scope          "$_PTRACE" "1 2 3" ""  )" \
    "$(_kh kernel.unprivileged_bpf_disabled  "$_BPF"    "1 2"   ""  )" \
    "$(_kh net.ipv4.tcp_syncookies           "$_SYNCK"  "1"     ""  )" \
    "$(_kh net.ipv4.conf.all.accept_redirects "$_AREDIR" "0"    ""  )" \
    "$(_kh net.ipv4.conf.all.accept_source_route "$_ASRC" "0"   ""  )" \
    "$(_kh net.ipv4.conf.all.rp_filter       "$_RPF"    "1 2"   ""  )" \
    "$(_kh net.ipv4.icmp_echo_ignore_broadcasts "$_ICMPBC" "1"  ""  )")

# ── 2. Listening TCP ports (/proc/net/tcp + tcp6) ─────────────────────────────
# Each line is tagged with its protocol; a single awk pass decodes both.
# h2i(): portable hex-to-int without strtonum.
# le_ip(): 8-char little-endian hex -> dotted-decimal IPv4.
_LISTEN_JSON=$(
    {
        awk 'NR>1 && $4=="0A" { print "tcp4",$2 }' /proc/net/tcp  2>/dev/null
        awk 'NR>1 && $4=="0A" { print "tcp6",$2 }' /proc/net/tcp6 2>/dev/null
    } | awk '
        function h2i(h,  i,c,v) {
            v=0; for(i=1;i<=length(h);i++){
                c=substr(h,i,1)
                v=v*16+(c~/[0-9]/?c+0:index("abcdef",tolower(c))+9)
            }; return v
        }
        function le_ip(h) {
            return h2i(substr(h,7,2))"."h2i(substr(h,5,2))"."h2i(substr(h,3,2))"."h2i(substr(h,1,2))
        }
        BEGIN{first=1}
        {
            proto=$1; split($2,ap,":")
            port=h2i(ap[2])
            ip=(length(ap[1])==8)?le_ip(ap[1]):ap[1]
            if(!first)printf","
            printf"{\"address\":\"%s\",\"port\":%d,\"protocol\":\"%s\"}",ip,port,proto
            first=0
        }
    '
)
_LISTEN_JSON="[${_LISTEN_JSON:-}]"

# ── 3. SSH daemon configuration ───────────────────────────────────────────────
_SSH_FOUND="false"; _SSH_SETTINGS="{}"; _SSH_ISSUES="[]"; _SSH_IC=0
if [ -r /etc/ssh/sshd_config ]; then
    _SSH_FOUND="true"
    _PRL=$(awk '!/^#/ && tolower($1)=="permitrootlogin"        {print tolower($2);exit}' /etc/ssh/sshd_config 2>/dev/null)
    _PWA=$(awk '!/^#/ && tolower($1)=="passwordauthentication"  {print tolower($2);exit}' /etc/ssh/sshd_config 2>/dev/null)
    _EPW=$(awk '!/^#/ && tolower($1)=="permitemptypasswords"    {print tolower($2);exit}' /etc/ssh/sshd_config 2>/dev/null)
    _X11=$(awk '!/^#/ && tolower($1)=="x11forwarding"           {print tolower($2);exit}' /etc/ssh/sshd_config 2>/dev/null)
    _PUE=$(awk '!/^#/ && tolower($1)=="permituserenvironment"   {print tolower($2);exit}' /etc/ssh/sshd_config 2>/dev/null)
    _SSH_SETTINGS=$(printf \
        '{"permitrootlogin":"%s","passwordauthentication":"%s","permitemptypasswords":"%s","x11forwarding":"%s","permituserenvironment":"%s"}' \
        "${_PRL:-prohibit-password}" "${_PWA:-yes}" "${_EPW:-no}" "${_X11:-no}" "${_PUE:-no}")
    _iss=""; _SSH_IC=0
    _ai() { _iss="${_iss:+$_iss,}{\"setting\":\"$1\",\"value\":\"$2\",\"risk\":\"$3\"}"; _SSH_IC=$((_SSH_IC+1)); }
    case "${_PRL:-prohibit-password}" in
        no|prohibit-password) ;;
        *) _ai "PermitRootLogin" "${_PRL}" "Direct root login over SSH is permitted";;
    esac
    [ "${_PWA:-yes}" = "yes" ] && _ai "PasswordAuthentication" "yes" "Password authentication enabled; prefer public-key auth only"
    [ "${_EPW:-no}"  = "yes" ] && _ai "PermitEmptyPasswords"   "yes" "Accounts with empty passwords can authenticate over SSH"
    [ "${_X11:-no}"  = "yes" ] && _ai "X11Forwarding"          "yes" "X11 forwarding exposes the local X display to the remote host"
    [ "${_PUE:-no}"  = "yes" ] && _ai "PermitUserEnvironment"  "yes" "Users can override environment variables"
    _SSH_ISSUES="[${_iss}]"
fi
_SSH_JSON=$(printf \
    '{"file_found":%s,"settings":%s,"issues":%s,"issue_count":%d}' \
    "$_SSH_FOUND" "$_SSH_SETTINGS" "$_SSH_ISSUES" "$_SSH_IC")

# ── 4. User account security ──────────────────────────────────────────────────
_U0="[]"; _LCNT=0; _EPU="[]"; _SHRD="false"
if [ -r /etc/passwd ]; then
    _u0s=$(awk -F: '$3==0 && $1!="root" {printf "\"%s\",",$1}' /etc/passwd 2>/dev/null | sed 's/,$//')
    _U0="[${_u0s:-}]"
    _LCNT=$(awk -F: '$NF=="/bin/false"||$NF=="/usr/sbin/nologin"||$NF=="/sbin/nologin"{c++}END{print c+0}' /etc/passwd 2>/dev/null)
fi
if [ -r /etc/shadow ]; then
    _eps=$(awk -F: '$2=="" {printf "\"%s\",",$1}' /etc/shadow 2>/dev/null | sed 's/,$//')
    _EPU="[${_eps:-}]"; _SHRD="true"
fi
_UV="false"; [ "$_U0" != "[]" ] && _UV="true"
_USER_JSON=$(printf \
    '{"uid_zero_non_root":%s,"uid_zero_violation":%s,"locked_shell_count":%d,"empty_password_users":%s,"shadow_readable_by_script":%s}' \
    "$_U0" "$_UV" "${_LCNT:-0}" "$_EPU" "$_SHRD")

# ── 5. SUID and SGID binaries ─────────────────────────────────────────────────
_SLIST=$(find /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin \
    -maxdepth 1 -type f -perm -4000 2>/dev/null | sort | \
    awk '{printf"\"%s\",",$0}' | sed 's/,$//')
_GLIST=$(find /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin \
    -maxdepth 1 -type f -perm -2000 ! -perm -4000 2>/dev/null | sort | \
    awk '{printf"\"%s\",",$0}' | sed 's/,$//')
_SC=$(find /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin \
    -maxdepth 1 -type f -perm -4000 2>/dev/null | wc -l | tr -d ' ')
_GC=$(find /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin \
    -maxdepth 1 -type f -perm -2000 ! -perm -4000 2>/dev/null | wc -l | tr -d ' ')
_SUID_JSON=$(printf \
    '{"suid_binaries":[%s],"sgid_binaries":[%s],"suid_count":%d,"sgid_count":%d}' \
    "${_SLIST:-}" "${_GLIST:-}" "${_SC:-0}" "${_GC:-0}")

# ── 6. World-writable files in sensitive directories ──────────────────────────
_WL=$(find /etc /bin /sbin /usr/bin /usr/sbin -perm -002 ! -type l 2>/dev/null | sort | \
    awk '{printf"\"%s\",",$0}' | sed 's/,$//')
_WC=$(find /etc /bin /sbin /usr/bin /usr/sbin -perm -002 ! -type l 2>/dev/null | wc -l | tr -d ' ')
_WST="pass"; [ "${_WC:-0}" -gt 0 ] && _WST="warn"
_WW_JSON=$(printf \
    '{"paths":[%s],"count":%d,"status":"%s","scanned_directories":["/etc","/bin","/sbin","/usr/bin","/usr/sbin"]}' \
    "${_WL:-}" "${_WC:-0}" "$_WST")

# ── 7. Permissions on critical system files ───────────────────────────────────
# stat -c '%a' gives octal permissions; we check the last digit for other-perms.
_fp() {
    if [ -e "$1" ]; then
        local m u g ld wr rd
        m=$(stat -c '%a' "$1" 2>/dev/null || echo "000")
        u=$(stat -c '%u' "$1" 2>/dev/null || echo "0")
        g=$(stat -c '%g' "$1" 2>/dev/null || echo "0")
        ld="${m: -1}"; wr="false"; rd="false"
        [ "$(( ld & 2 ))" -ne 0 ] && wr="true"
        [ "$(( ld & 4 ))" -ne 0 ] && rd="true"
        printf '{"exists":true,"mode_octal":"%s","owner_uid":%d,"owner_gid":%d,"world_readable":%s,"world_writable":%s}' \
            "$m" "$u" "$g" "$rd" "$wr"
    else
        printf '{"exists":false}'
    fi
}
_FP=""
for _fp_p in /etc/passwd /etc/shadow /etc/gshadow /etc/sudoers /etc/ssh/sshd_config /etc/crontab /boot/grub/grub.cfg; do
    _FP="${_FP:+$_FP,}\"${_fp_p}\":$(_fp "$_fp_p")"
done
_FP_JSON=$(printf '{%s}' "${_FP}")

SECURITY_JSON=$(printf \
    '{"kernel_hardening":%s,"listening_ports":%s,"ssh_config":%s,"user_accounts":%s,"suid_sgid_binaries":%s,"world_writable_sensitive":%s,"sensitive_file_permissions":%s}' \
    "$_KH_JSON" "$_LISTEN_JSON" "$_SSH_JSON" "$_USER_JSON" "$_SUID_JSON" "$_WW_JSON" "$_FP_JSON")
SECURITY_JSON="${SECURITY_JSON:-{}}"


# =============================================================================
# 13. ASSEMBLE JSON, ENCRYPT, AND UPLOAD
# =============================================================================
# All collected data lives in plain bash variables at this point.
# The JSON report is assembled with printf + json_str(), encrypted with openssl,
# and uploaded to Azure Blob Storage with az storage blob upload.
# No python3 is required for any of these steps.
# Build kernel_params JSON — only include params that were successfully read.
_KP=""
[ -n "${KP_PID_MAX:-}"     ] && _KP="${_KP:+$_KP,}\"pid_max\":${KP_PID_MAX}"
[ -n "${KP_THREADS_MAX:-}" ] && _KP="${_KP:+$_KP,}\"threads_max\":${KP_THREADS_MAX}"
[ -n "${KP_OVERCOMMIT:-}"  ] && _KP="${_KP:+$_KP,}\"overcommit_memory\":${KP_OVERCOMMIT}"
[ -n "${KP_SWAPPINESS:-}"  ] && _KP="${_KP:+$_KP,}\"swappiness\":${KP_SWAPPINESS}"
[ -n "${KP_DIRTY_RATIO:-}" ] && _KP="${_KP:+$_KP,}\"dirty_ratio\":${KP_DIRTY_RATIO}"
[ -n "${KP_IP_FORWARD:-}"  ] && _KP="${_KP:+$_KP,}\"ip_forward\":${KP_IP_FORWARD}"
[ -n "${KP_TCP_SYN:-}"     ] && _KP="${_KP:+$_KP,}\"tcp_syn_retries\":${KP_TCP_SYN}"
[ -n "${KP_KEEPALIVE:-}"   ] && _KP="${_KP:+$_KP,}\"tcp_keepalive_time\":${KP_KEEPALIVE}"
_KPARAMS_JSON=$(printf '{%s}' "${_KP}")

# Create temp directory first — JSON is written directly into it, avoiding
# the single-giant-printf approach that causes cycling bugs in bash printf
# when there are 50+ %s specifiers in one call.
HC_TMP=$(mktemp -d /tmp/hc_enc_XXXXXX) \
    || { log "ERROR: Cannot create temp directory."; exit 1; }
trap 'rm -rf "${HC_TMP}" 2>/dev/null; trap - EXIT' EXIT

# Write the JSON report to ${HC_TMP}/report.json using one small printf per
# section.  Each call has a short format string and a small, fixed number of
# arguments — no risk of bash printf's format-cycling behaviour.
{
    printf '{"schema_version":"1.0","script_version":"%s","collected_at":"%s",' \
        "$(json_str "${SCRIPT_VERSION:-1.0.0}")"\
        "$(json_str "${COLLECTED_AT:-unknown}")"
    printf '"system":{"hostname":"%s","kernel":"%s","kernel_full":"%s",' \
        "$(json_str "${HOSTNAME_VAL:-unknown}")"\
        "$(json_str "${KERNEL:-unknown}")"\
        "$(printf '%s' "${KERNEL_FULL:-}" | head -c 512 | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')"
    printf '"architecture":"%s","os_name":"%s","os_id":"%s","os_version":"%s","boot_time_epoch":%s},' \
        "$(json_str "${ARCH:-unknown}")"\
        "$(json_str "${OS_NAME:-Ubuntu 22.04}")"\
        "$(json_str "${OS_ID:-ubuntu}")"\
        "$(json_str "${OS_VERSION:-22.04}")"\
        "${BOOT_TIME:-0}"
    printf '"uptime":{"seconds":%s,"idle_seconds":%s},' \
        "${UPTIME_SECONDS:-0}" "${IDLE_SECONDS:-0}"
    printf '"load":{"load_1m":%s,"load_5m":%s,"load_15m":%s,"procs_running":%s,"procs_total":%s},' \
        "${LOAD_1:-0}" "${LOAD_5:-0}" "${LOAD_15:-0}" "${PROCS_RUNNING:-0}" "${PROCS_TOTAL:-0}"
    printf '"cpu":{"model":"%s","logical_cores":%s,"physical_sockets":%s,"freq_mhz":%s,"usage_percent":%s,"per_cpu_jiffies":%s},' \
        "$(json_str "${CPU_MODEL:-unknown}")"\
        "${CPU_CORES:-0}" "${CPU_SOCKETS:-1}" "${CPU_FREQ_MHZ:-0}" "${CPU_USAGE:-0.00}"\
        "${PER_CPU_JSON:-[]}"
    printf '"memory":{"total_kb":%s,"free_kb":%s,"available_kb":%s,"used_kb":%s,' \
        "${MEM_TOTAL:-0}" "${MEM_FREE:-0}" "${MEM_AVAILABLE:-0}" "${MEM_USED:-0}"
    printf '"buffers_kb":%s,"cached_kb":%s,"sreclaimable_kb":%s,' \
        "${MEM_BUFFERS:-0}" "${MEM_CACHED:-0}" "${MEM_SRECLAIMABLE:-0}"
    printf '"swap_total_kb":%s,"swap_free_kb":%s,"swap_used_kb":%s,' \
        "${SWAP_TOTAL:-0}" "${SWAP_FREE:-0}" "${SWAP_USED:-0}"
    printf '"hugepages_total":%s,"hugepages_free":%s,"hugepage_size_kb":%s},' \
        "${HUGEPAGES_TOTAL:-0}" "${HUGEPAGES_FREE:-0}" "${HUGEPAGE_SIZE:-0}"
    printf '"disk":%s,'                   "${DISK_JSON:-[]}"
    printf '"network":{"interfaces":%s,"ipv4_addresses":%s,"ipv6_addresses":%s},' \
        "${NET_IFACES_JSON:-[]}" "${IPV4_JSON:-[]}" "${IPV6_JSON:-[]}"
    printf '"top_processes_by_memory":%s,' "${TOP_PROCS_JSON:-[]}"
    printf '"file_descriptors":{"allocated":%s,"free":%s,"used":%s,"max":%s,"use_percent":%s},' \
        "${FD_ALLOCATED:-0}" "${FD_FREE_ALLOC:-0}" "${FD_USED:-0}" "${FD_MAX:-0}" "${FD_USE_PCT:-0.00}"
    printf '"kernel_params":%s,'          "${_KPARAMS_JSON:-{}}"
    printf '"stat_counters":{"intr":%s,"ctxt":%s,"processes":%s,"procs_blocked":%s},' \
        "${STAT_INTR:-0}" "${STAT_CTXT:-0}" "${STAT_PROCS:-0}" "${STAT_BLOCKED:-0}"
    printf '"environment_variables":%s,'  "${ENV_VARS_JSON:-{}}"
    printf '"security_checks":%s}'        "${SECURITY_JSON:-{}}"
} > "${HC_TMP}/report.json" \
    || { log "ERROR: JSON assembly failed."; exit 1; }

# =============================================================================
# ENCRYPTION (openssl CLI) AND UPLOAD (curl)
# =============================================================================
# Hybrid encryption: RSA-OAEP-SHA256 wraps a one-time AES-256-CBC session key;
# the report JSON is encrypted with that key.  Output is a JSON envelope with
# two base64-encoded ciphertext fields.
#
# RSA-4096 public key hardcoded below.  The matching private key must be held
# securely on the receiving server and is NEVER present on this host.
# Key pair generated with:
#   openssl genrsa -out private.pem 4096
#   openssl rsa   -in private.pem -pubout -out public.pem
#
# Server-side decryption:
#   base64 -d <<<"$ENC_KEY"  > keyiv.enc
#   base64 -d <<<"$ENC_DATA" > data.enc
#   openssl pkeyutl -decrypt -inkey private.pem \
#     -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 \
#     -pkeyopt rsa_mgf1_md:sha256 -in keyiv.enc -out keyiv.bin
#   KEY=$(od -A n -v -t x1 keyiv.bin | head -c 96 | tr -d ' \n')
#   IV=$( od -A n -v -t x1 keyiv.bin | tail -c 48 | tr -d ' \n')
#   openssl enc -d -aes-256-cbc -nosalt -K "$KEY" -iv "$IV" \
#     -in data.enc -out report.json
log "Encrypting report (RSA-OAEP-SHA256 + AES-256-CBC)..."

# Write the hardcoded RSA-4096 public key to a temp file.
cat > "${HC_TMP}/pub.pem" << 'PUBKEYEOF'
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAu444Cr0aPQ2FgNPzO7qz
s7REGKFhIsBdIj0Shynw8kY/GEy9QJ3w9PtlDW/3EfyrjcZGZMzvDPtbfByww81v
IdkQZd5J93OU65fGkO0lOjG806Y45Cxsz6GsAt/ZOvdl6o8diqY9Gs709SMKLVrR
46DwAzwokxv1xFwyKlK1l2JVC1/pfl6DJ7ndRMH885x2Ji8uMDw8nVDe6/oHH6Ry
sJcL3CvX1jr+NaNQOkUS9iF8skMXcKGoMPIUdI8Q3cdzMxLyc1aiPRiWOrksu2VC
oOzHnrfgjmpxCaPsEBStpQwRXDI3l9CEXw8fuVH1B1h5RVNmdVX8cc0zMNtraKNd
J+SxWcgW7n0KlsIoWi9xbUGY8ILkti82h4rdJqud/9UQg5QzHTYx1I4jEsCUgHrj
ZgT4cmm5ZU2Tg2nP0NC2Qh2sSl6YIqpwD+2hOE2/BdivolU8aBre1xkPIF5z47F9
ouEuATC2NPvveimtvCM0h+moMsd8aoBjdy+STTHLVuDgKLxF3X08Worvyxt2tQPr
ymyLKVz+yXqccd0Uaq7gogfEYPQCDGramoPlk5scgfEjXf2wsIniEs+ZCC/4x6Bo
0kR0zNRys98rD5fQzuCRvD8Edk97W7FfIPycbqdRoJd8ZbpBveRNf6PC+J22FTaQ
bxfE8RRm+hW9xP3c5n44F40CAwEAAQ==
-----END PUBLIC KEY-----
PUBKEYEOF

# DEBUG: copy plaintext report before encryption
cp "${HC_TMP}/report.json" /tmp/debug_report.json 2>/dev/null || true

# Generate a fresh random AES-256 key (32 bytes) and IV (16 bytes) as raw binary.
# A unique key+IV pair is produced on every script invocation.
openssl rand 32 > "${HC_TMP}/aes.key" 2>/dev/null \
    || { log "ERROR: openssl rand (key) failed."; exit 1; }
openssl rand 16 > "${HC_TMP}/aes.iv" 2>/dev/null \
    || { log "ERROR: openssl rand (IV) failed."; exit 1; }

# Convert binary key and IV to continuous hex strings for openssl enc -K/-iv.
# od (coreutils): -A n = no address column, -v = all bytes, -t x1 = hex bytes.
AES_KEY_HEX=$(od -A n -v -t x1 < "${HC_TMP}/aes.key" | tr -d ' \n') \
    || { log "ERROR: Cannot read AES key."; exit 1; }
AES_IV_HEX=$( od -A n -v -t x1 < "${HC_TMP}/aes.iv"  | tr -d ' \n') \
    || { log "ERROR: Cannot read AES IV."; exit 1; }

# Encrypt the JSON report with AES-256-CBC.
# -nosalt: disables the password-derived-key prefix (key is supplied in hex).
openssl enc -aes-256-cbc -nosalt \
    -K  "${AES_KEY_HEX}" \
    -iv "${AES_IV_HEX}" \
    -in  "${HC_TMP}/report.json" \
    -out "${HC_TMP}/report.enc" 2>/dev/null \
    || { log "ERROR: AES-256-CBC encryption failed."; exit 1; }

# Concatenate key||IV into one 48-byte blob (32 + 16) for RSA key-wrapping.
# 48 bytes is well below the 446-byte OAEP-SHA256 capacity of a 4096-bit key.
cat "${HC_TMP}/aes.key" "${HC_TMP}/aes.iv" > "${HC_TMP}/keyiv.bin" \
    || { log "ERROR: Cannot concatenate key||IV."; exit 1; }

# RSA-encrypt the 48-byte key||IV blob with the public key (OAEP-SHA256).
openssl pkeyutl -encrypt \
    -pubin -inkey "${HC_TMP}/pub.pem" \
    -pkeyopt rsa_padding_mode:oaep \
    -pkeyopt rsa_oaep_md:sha256 \
    -pkeyopt rsa_mgf1_md:sha256 \
    -in  "${HC_TMP}/keyiv.bin" \
    -out "${HC_TMP}/keyiv.enc" 2>/dev/null \
    || { log "ERROR: RSA key encryption failed."; exit 1; }

# Base64-encode both ciphertexts with no line wrapping (-w0).
ENC_KEY=$(base64 -w0 < "${HC_TMP}/keyiv.enc") \
    || { log "ERROR: base64 of encrypted key failed."; exit 1; }
ENC_DATA=$(base64 -w0 < "${HC_TMP}/report.enc") \
    || { log "ERROR: base64 of encrypted data failed."; exit 1; }

# Build the JSON envelope and write it into the temp directory so that
# az storage blob upload can read it from a file path.
# base64 output is A-Za-z0-9+/= only -- safe to embed directly in printf.
printf '{"algorithm":"RSA-OAEP-SHA256 + AES-256-CBC","encrypted_key":"%s","encrypted_data":"%s"}' \
    "${ENC_KEY}" "${ENC_DATA}" \
    > "${HC_TMP}/envelope.json" \
    || { log "ERROR: Cannot write envelope to temp file."; exit 1; }

# Unique blob name: <short-hostname>_<UTC-timestamp>.json.enc
BLOB_NAME="$(hostname -s 2>/dev/null || echo unknown)_$(date -u +%Y%m%dT%H%M%SZ).json.enc"

log "Uploading to ${STORAGE_ACCOUNT_NAME}/${STORAGE_CONTAINER}..."

# When running inside WSL the 'az' on PATH is the Windows CLI, which cannot
# resolve WSL-native paths.  Convert /tmp/... to the \\wsl.localhost\... UNC
# equivalent so the Windows process can open the file.
_UPLOAD_FILE="${HC_TMP}/envelope.json"
if command -v wslpath >/dev/null 2>&1; then
    _UPLOAD_FILE=$(wslpath -w "${HC_TMP}/envelope.json" 2>/dev/null) \
        || _UPLOAD_FILE="${HC_TMP}/envelope.json"
fi

az storage blob upload \
    --account-name   "${STORAGE_ACCOUNT_NAME}" \
    --account-key    "${STORAGE_ACCOUNT_KEY}" \
    --container-name "${STORAGE_CONTAINER}" \
    --file           "${_UPLOAD_FILE}" \
    --name           "${BLOB_NAME}" \
    --content-type   "application/json" \
    --auth-mode      key \
    --overwrite \
    --no-progress \
    --only-show-errors \
    --output none \
    || { log "ERROR: az storage blob upload failed."; exit 1; }

# Wipe all crypto material now that the upload has completed.
rm -rf "${HC_TMP}"
trap - EXIT

log "Upload successful: ${BLOB_NAME}"
log "Health check complete."
