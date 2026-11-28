#!/usr/bin/env bash
# End-to-end test of the VPS side through a real SSH connection
# (docs/DESIGN.md, section 6).
#
# A throwaway sshd is started on 127.0.0.1 (free high port, temporary host
# key, temporary client key, its own AuthorizedKeysFile and PidFile). The
# client ssh_config is written by hand below, key by key, as a copy of the
# list of section 4.3 of the design: the PowerShell generator that makes the
# real file cannot run here. A check below compares the keywords of this file
# with section 4.3, and tests/ps-static-check.py compares the generator with
# the same section. The test then replays the exact remote command strings
# sent by the Windows client: upload through stdin + install, heartbeat,
# status, probe-port, a real reverse tunnel (ssh -N -R), a stale heartbeat,
# uninstall.
#
# Nothing leaves 127.0.0.1 and nothing outside the temporary directory is
# written, except /run/sshd (empty privilege separation directory of sshd,
# created when missing and left in place: removing it could break another
# sshd started in the meantime).
#
# Exit code 0 when every check passes, 1 otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SOURCE_HELPER="$REPO_ROOT/vps/bokador-link"
readonly HOST_ALIAS='bokador-link-vps'
readonly CLIENT_LABEL='BOKADOR-TEST'
readonly HELPER_PATH_RE='^/[A-Za-z0-9/._-]{1,200}$'
readonly STALE_SECONDS=3600
# The client's ssh_config and the PATH given to the remote side are fixed here,
# not taken from this machine's environment.
readonly REMOTE_PATH_DIRS='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

PASSED=0
FAILED=0

TMP=''
SSHD_BIN=''
SSHD_PID=''
SSHD_PORT=''
TUNNEL_PID=''
TUNNEL_PORT=''
PICKED_PORT=''
STOPPED_PIDS=''
OUT=''
ERR=''
RC=0

unset SSH_AUTH_SOCK SSH_ASKPASS BL_ROOT BL_NOW BL_NO_SYSTEMD BL_FORCE_CRON

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

section() {
    printf '\n== %s\n' "$1"
}

pass() {
    PASSED=$((PASSED + 1))
    printf '  ok    %s\n' "$1"
}

fail() {
    FAILED=$((FAILED + 1))
    printf '  FAIL  %s\n' "$1"
    shift
    while [[ $# -gt 0 ]]; do
        printf '          %s\n' "$1"
        shift
    done
}

expect_eq() {
    # expect_eq <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "expected: $(printf '%q' "$2")" "actual:   $(printf '%q' "$3")"
    fi
}

expect_match() {
    # expect_match <description> <extended regex> <actual>
    if [[ "$3" =~ $2 ]]; then
        pass "$1"
    else
        fail "$1" "expected to match: $2" "actual: $(printf '%q' "$3")"
    fi
}

expect_exists() {
    if [[ -e "$2" ]]; then
        pass "$1"
    else
        fail "$1" "missing: $2"
    fi
}

expect_absent() {
    if [[ ! -e "$2" && ! -L "$2" ]]; then
        pass "$1"
    else
        fail "$1" "should not exist: $2"
    fi
}

expect_result() {
    # expect_result <description> <exit code> <exact stdout, final newline excluded; '' = none>
    local wanted=''
    if [[ -n "$3" ]]; then
        wanted="$3"$'\n'
    fi
    if [[ "$RC" == "$2" && "$OUT" == "$wanted" ]]; then
        pass "$1"
    else
        fail "$1" \
            "expected: exit $2, stdout $(printf '%q' "$wanted")" \
            "actual:   exit $RC, stdout $(printf '%q' "$OUT")" \
            "stderr:   $(printf '%q' "$ERR")"
    fi
}

expect_ssh_failure() {
    # expect_ssh_failure <description> <text expected on stderr>: ssh itself fails (255).
    if [[ "$RC" == 255 && "$ERR" == *"$2"* ]]; then
        pass "$1"
    else
        fail "$1" "expected: exit 255, stderr containing: $2" \
            "actual:   exit $RC, stderr $(printf '%q' "$ERR")"
    fi
}

# ---------------------------------------------------------------------------
# Processes and ports
# ---------------------------------------------------------------------------

port_open() {
    (exec 3<> "/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# A port of 127.0.0.1 nothing listens on, outside the ephemeral range, into
# PICKED_PORT. The optional argument is a port to avoid.
pick_port() {
    local tries=0 port=0
    PICKED_PORT=''
    while (( tries < 200 )); do
        tries=$((tries + 1))
        port=$((20000 + (RANDOM * 32768 + RANDOM) % 12000))
        if [[ "$port" != "${1:-}" ]] && ! port_open "$port"; then
            PICKED_PORT="$port"
            return 0
        fi
    done
    return 1
}

# Prints the pids of every descendant of a process.
descendants_of() {
    local known=" $1 " found='' grew=1 stat='' line='' rest='' pid='' ppid=''
    while (( grew == 1 )); do
        grew=0
        for stat in /proc/[0-9]*/stat; do
            line=''
            { IFS= read -r line < "$stat"; } 2>/dev/null || continue
            pid="${stat#/proc/}"
            pid="${pid%/stat}"
            rest="${line##*) }"
            ppid="${rest#* }"
            ppid="${ppid%% *}"
            if [[ "$known" == *" $ppid "* && "$known" != *" $pid "* ]]; then
                known+="$pid "
                found+="$pid "
                grew=1
            fi
        done
    done
    printf '%s' "${found% }"
}

# Waits until a process has disappeared; status 1 at the deadline.
wait_gone() {
    # wait_gone <pid> <seconds>
    local deadline=$((SECONDS + $2))
    while [[ -d "/proc/$1" ]]; do
        if (( SECONDS >= deadline )); then
            return 1
        fi
        sleep 0.1
    done
    return 0
}

# Stops the tunnel, then whatever sshd still has running, then sshd. Safe to
# call twice; also called by the EXIT trap, so nothing survives a failed run.
stop_all() {
    local pid='' descendants='' deepest_first=''
    if [[ -n "$TUNNEL_PID" ]]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
        STOPPED_PIDS+="$TUNNEL_PID "
        TUNNEL_PID=''
    fi
    if [[ -n "$SSHD_PID" ]]; then
        # Sessions still open (none after a normal run) are stopped one by
        # one, children before parents, while sshd is there to reap them.
        descendants="$(descendants_of "$SSHD_PID")"
        for pid in $descendants; do
            deepest_first="$pid $deepest_first"
        done
        for pid in $deepest_first; do
            kill "$pid" 2>/dev/null || true
            if ! wait_gone "$pid" 3; then
                kill -KILL "$pid" 2>/dev/null || true
                wait_gone "$pid" 2 || true
            fi
        done
        kill "$SSHD_PID" 2>/dev/null || true
        wait "$SSHD_PID" 2>/dev/null || true
        STOPPED_PIDS+="$SSHD_PID $descendants "
        SSHD_PID=''
    fi
}

remove_tmp() {
    if [[ -n "$TMP" && -d "$TMP" ]]; then
        rm -rf -- "$TMP"
    fi
}

# Any exit that does not go through finish(): stop everything, say so.
trap '
    stop_all
    printf "\ntest-integration: ABORTED before the end (%d passed, %d failed so far)\n" \
        "$PASSED" "$FAILED"
    remove_tmp
' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# sshd and ssh
# ---------------------------------------------------------------------------

write_sshd_config() {
    # write_sshd_config <port> <yes|no: add options only known to recent sshd>
    {
        printf 'Port %s\n' "$1"
        printf 'ListenAddress 127.0.0.1\n'
        printf 'HostKey %s\n' "$SSHD_DIR/ssh_host_ed25519_key"
        printf 'PidFile %s\n' "$SSHD_DIR/sshd.pid"
        printf 'AuthorizedKeysFile %s\n' "$SSHD_DIR/authorized_keys"
        printf 'AuthenticationMethods publickey\n'
        printf 'PubkeyAuthentication yes\n'
        printf 'PasswordAuthentication no\n'
        printf 'KbdInteractiveAuthentication no\n'
        printf 'UsePAM no\n'
        printf 'PermitRootLogin prohibit-password\n'
        printf 'StrictModes no\n'
        printf 'AllowTcpForwarding yes\n'
        printf 'GatewayPorts no\n'
        printf 'X11Forwarding no\n'
        printf 'PermitUserEnvironment no\n'
        printf 'LogLevel VERBOSE\n'
        printf '%s\n' "$SETENV_LINE"
        if [[ "$2" == yes ]]; then
            # OpenSSH 9.8+: the short connections of this test must not be penalised.
            printf 'PerSourcePenalties no\n'
        fi
    } > "$SSHD_DIR/sshd_config"
}

# Starts sshd on a free port; retries on another port if the bind fails.
start_sshd() {
    local attempt=0 deadline=0
    while (( attempt < 5 )); do
        attempt=$((attempt + 1))
        if ! pick_port; then
            return 1
        fi
        SSHD_PORT="$PICKED_PORT"
        write_sshd_config "$SSHD_PORT" yes
        if ! "$SSHD_BIN" -t -f "$SSHD_DIR/sshd_config" > /dev/null 2>&1; then
            write_sshd_config "$SSHD_PORT" no
            if ! "$SSHD_BIN" -t -f "$SSHD_DIR/sshd_config" > "$TMP/stdout" 2> "$TMP/stderr"; then
                printf '          sshd rejects its configuration:\n'
                sed 's/^/          /' "$TMP/stderr"
                return 1
            fi
        fi
        rm -f "$SSHD_DIR/sshd.pid"
        "$SSHD_BIN" -D -f "$SSHD_DIR/sshd_config" -E "$SSHD_DIR/sshd.log" \
            < /dev/null > /dev/null 2>&1 &
        SSHD_PID=$!
        deadline=$((SECONDS + 15))
        while kill -0 "$SSHD_PID" 2>/dev/null; do
            if [[ -s "$SSHD_DIR/sshd.pid" ]] && port_open "$SSHD_PORT"; then
                return 0
            fi
            if (( SECONDS >= deadline )); then
                break
            fi
            sleep 0.1
        done
        kill "$SSHD_PID" 2>/dev/null || true
        wait "$SSHD_PID" 2>/dev/null || true
        SSHD_PID=''
    done
    return 1
}

write_ssh_config() {
    # write_ssh_config <file> <port> <identity file> <known_hosts>
    # Same keys, same order as the ssh_config of design section 4.3.
    cat > "$1" <<EOF
Host $HOST_ALIAS
    HostName 127.0.0.1
    Port $2
    User $LOGIN_USER
    IdentityFile "$3"
    IdentitiesOnly yes
    BatchMode yes
    PasswordAuthentication no
    StrictHostKeyChecking yes
    UserKnownHostsFile "$4" "$CLIENT_DIR/userprofile_known_hosts"
    ServerAliveInterval 30
    ServerAliveCountMax 3
    TCPKeepAlive yes
    ConnectTimeout 15
    ConnectionAttempts 1
    ExitOnForwardFailure yes
    LogLevel ERROR
EOF
}

# ssh_with <ssh_config> <remote command> [file sent on stdin]
# What Invoke-BLSsh does: ssh -F <ssh_config> <HostAlias> <RemoteCommand>,
# stdin closed unless bytes are sent. Sets OUT, ERR and RC.
ssh_with() {
    RC=0
    timeout 60 ssh -F "$1" "$HOST_ALIAS" "$2" \
        < "${3:-/dev/null}" > "$TMP/stdout" 2> "$TMP/stderr" || RC=$?
    OUT="$(cat "$TMP/stdout"; printf 'x')"
    OUT="${OUT%x}"
    ERR="$(cat "$TMP/stderr")"
}

ssh_run() {
    ssh_with "$CLIENT_DIR/ssh_config" "$@"
}

# Polls "<VpsHelper> probe-port <port>" through ssh until it reports the
# wanted state (OPEN or CLOSED) or the deadline passes. While waiting for
# OPEN, gives up as soon as the tunnel process is gone.
wait_probe() {
    local wanted="$1" deadline=$((SECONDS + 20))
    while true; do
        ssh_run "$VPS_HELPER probe-port $TUNNEL_PORT"
        if [[ "$OUT" == "PORT $TUNNEL_PORT $wanted"$'\n' ]]; then
            return 0
        fi
        if (( SECONDS >= deadline )); then
            return 1
        fi
        if [[ "$wanted" == OPEN && -n "$TUNNEL_PID" ]] && ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            return 1
        fi
        sleep 0.2
    done
}

# Presence of the real paths the helper would use without BL_ROOT.
real_paths_snapshot() {
    local path
    for path in /usr/local/sbin/bokador-link /var/lib/bokador-link /etc/bokador-link \
        /etc/systemd/system/bokador-link-check.service \
        /etc/systemd/system/bokador-link-check.timer /etc/cron.d/bokador-link; do
        if [[ -e "$path" || -L "$path" ]]; then
            printf 'present %s\n' "$path"
        else
            printf 'absent %s\n' "$path"
        fi
    done
}

show_logs() {
    local file
    for file in "$SSHD_DIR/sshd.log" "$CLIENT_DIR/ssh-tunnel.err.log"; do
        if [[ -s "$file" ]]; then
            printf '\n-- last lines of %s\n' "${file##*/}"
            tail -n 25 "$file" | sed 's/^/   /'
        fi
    done
}

finish() {
    stop_all
    if (( FAILED > 0 )); then
        show_logs
    fi
    remove_tmp
    trap - EXIT
    printf '\ntest-integration: %d passed, %d failed\n' "$PASSED" "$FAILED"
    if (( FAILED > 0 )); then
        exit 1
    fi
    exit 0
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

printf 'test-integration: end-to-end test through a throwaway sshd on 127.0.0.1\n'

section 'Prerequisites'

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bl-it.XXXXXXXX")"
if [[ ! "$TMP/vps-sbin/bokador-link" =~ $HELPER_PATH_RE ]]; then
    rmdir "$TMP"
    TMP="$(mktemp -d /tmp/bl-it.XXXXXXXX)"
fi
TMP="$(cd "$TMP" && pwd -P)"

readonly SSHD_DIR="$TMP/sshd"
readonly CLIENT_DIR="$TMP/client"                    # stands in for <BLRoot> on the PC
readonly VPS_ROOT="$TMP/vps-root"                    # BL_ROOT of the helper
readonly VPS_HELPER="$TMP/vps-sbin/bokador-link"     # stands in for VpsHelper
readonly STUB_BIN="$TMP/stub-bin"
readonly STATE_DIR="$VPS_ROOT/var/lib/bokador-link"
readonly ETC_DIR="$VPS_ROOT/etc/bokador-link"
readonly UNIT_DIR="$VPS_ROOT/etc/systemd/system"
readonly NOTIFY_LOG="$TMP/notify.log"
mkdir -p "$SSHD_DIR" "$CLIENT_DIR" "$VPS_ROOT" "$TMP/vps-sbin" "$STUB_BIN"
: > "$NOTIFY_LOG"
LOGIN_USER="$(id -un)"
readonly LOGIN_USER

missing=''
for tool in ssh ssh-keygen timeout; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+="$tool "
    fi
done
for candidate in "$(command -v sshd 2>/dev/null || true)" /usr/sbin/sshd /usr/local/sbin/sshd; do
    if [[ "$candidate" == /* && -x "$candidate" ]]; then
        SSHD_BIN="$candidate"
        break
    fi
done
if [[ -z "$SSHD_BIN" ]]; then
    missing+='sshd '
fi
if [[ ! -f "$SOURCE_HELPER" ]]; then
    missing+='vps/bokador-link '
fi
if [[ -n "$missing" ]]; then
    fail "required tools and files are present" "missing: $missing"
    finish
fi
pass "ssh, ssh-keygen, timeout, $SSHD_BIN and vps/bokador-link are present"

if [[ "$VPS_HELPER" =~ $HELPER_PATH_RE ]]; then
    pass 'the stand-in for VpsHelper satisfies the VpsHelper pattern of design section 4.2'
else
    fail 'the stand-in for VpsHelper satisfies the VpsHelper pattern of design section 4.2' \
        "path: $VPS_HELPER"
    finish
fi

if [[ "$EUID" -eq 0 && ! -d /run/sshd ]]; then
    mkdir -p /run/sshd
    chmod 755 /run/sshd
fi

VERSION="$(bash "$SOURCE_HELPER" version)"
VERSION="${VERSION#bokador-link }"
SOURCE_SUM="$(cksum < "$SOURCE_HELPER")"
REAL_BEFORE="$(real_paths_snapshot)"

ssh-keygen -q -t ed25519 -N '' -C bokador-link-test-host -f "$SSHD_DIR/ssh_host_ed25519_key"
ssh-keygen -q -t ed25519 -N '' -C bokador-link-test-other-host -f "$SSHD_DIR/other_host_key"
ssh-keygen -q -t ed25519 -N '' -C bokador-link-test-client -f "$CLIENT_DIR/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -C bokador-link-test-stranger -f "$CLIENT_DIR/id_unauthorized"
cp "$CLIENT_DIR/id_ed25519.pub" "$SSHD_DIR/authorized_keys"
chmod 600 "$SSHD_DIR/authorized_keys"
: > "$CLIENT_DIR/userprofile_known_hosts"
: > "$CLIENT_DIR/empty_known_hosts"

# "logger" is replaced on the remote side so that the test writes nothing to
# the system log of this machine.
cat > "$STUB_BIN/logger" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> $(printf '%q' "$TMP/logger.log")
EOF
chmod 755 "$STUB_BIN/logger"
SETENV_LINE="SetEnv BL_ROOT=$VPS_ROOT BL_NO_SYSTEMD=1 PATH=$STUB_BIN:$REMOTE_PATH_DIRS"
readonly SETENV_LINE

# ---------------------------------------------------------------------------
section 'Throwaway sshd on 127.0.0.1 and client ssh_config (design section 4.3)'
# ---------------------------------------------------------------------------

if start_sshd; then
    pass "sshd listens on 127.0.0.1:$SSHD_PORT (pid $SSHD_PID)"
else
    fail 'sshd listens on 127.0.0.1' 'sshd did not start; its log follows'
    if [[ -s "$SSHD_DIR/sshd.log" ]]; then
        sed 's/^/          /' "$SSHD_DIR/sshd.log"
    fi
    finish
fi
expect_eq 'sshd wrote its own PidFile' "$SSHD_PID" "$(cat "$SSHD_DIR/sshd.pid" 2>/dev/null || true)"

read -r host_key_type host_key_data _ < "$SSHD_DIR/ssh_host_ed25519_key.pub"
printf '[127.0.0.1]:%s %s %s\n' "$SSHD_PORT" "$host_key_type" "$host_key_data" \
    > "$CLIENT_DIR/known_hosts"
read -r host_key_type host_key_data _ < "$SSHD_DIR/other_host_key.pub"
printf '[127.0.0.1]:%s %s %s\n' "$SSHD_PORT" "$host_key_type" "$host_key_data" \
    > "$CLIENT_DIR/changed_known_hosts"
if ! pick_port "$SSHD_PORT"; then
    fail 'a second free port is available on 127.0.0.1'
    finish
fi
CLOSED_PORT="$PICKED_PORT"

write_ssh_config "$CLIENT_DIR/ssh_config" "$SSHD_PORT" \
    "$CLIENT_DIR/id_ed25519" "$CLIENT_DIR/known_hosts"
write_ssh_config "$CLIENT_DIR/ssh_config.unknown-host" "$SSHD_PORT" \
    "$CLIENT_DIR/id_ed25519" "$CLIENT_DIR/empty_known_hosts"
write_ssh_config "$CLIENT_DIR/ssh_config.changed-host" "$SSHD_PORT" \
    "$CLIENT_DIR/id_ed25519" "$CLIENT_DIR/changed_known_hosts"
write_ssh_config "$CLIENT_DIR/ssh_config.wrong-key" "$SSHD_PORT" \
    "$CLIENT_DIR/id_unauthorized" "$CLIENT_DIR/known_hosts"
write_ssh_config "$CLIENT_DIR/ssh_config.closed-port" "$CLOSED_PORT" \
    "$CLIENT_DIR/id_ed25519" "$CLIENT_DIR/known_hosts"

# The keywords written above must be those of design section 4.3, in order:
# the first word of each line of its code block.
design_keywords="$(awk '
    /^### 4\.3 / { in_section = 1; next }
    /^### /       { in_section = 0 }
    in_section && /^```/ { fence = !fence; next }
    in_section && fence && NF > 0 { print $1 }
' "$REPO_ROOT/docs/DESIGN.md")"
config_keywords="$(awk 'NF > 0 { print $1 }' "$CLIENT_DIR/ssh_config")"
expect_eq 'the client ssh_config has the keywords of design section 4.3, in the same order' \
    "$design_keywords" "$config_keywords"

ssh_run 'echo BOKADOR_LINK_OK'
expect_result 'simple probe "echo BOKADOR_LINK_OK": key, host key and login work' 0 \
    'BOKADOR_LINK_OK'
if (( RC != 0 )); then
    finish
fi

# ---------------------------------------------------------------------------
section 'ssh failures: exit 255 and the stderr text that design section 4.4 classifies'
# ---------------------------------------------------------------------------
# Only the ssh side runs here: the classification itself (Get-BLClassifiedSshFailure)
# is PowerShell and is not executed (design, section 6).

kit_known_hosts_before="$(cksum < "$CLIENT_DIR/known_hosts")"
ssh_with "$CLIENT_DIR/ssh_config.unknown-host" 'echo BOKADOR_LINK_OK'
expect_ssh_failure 'unknown host key: stderr "Host key verification failed"' \
    'Host key verification failed'
ssh_with "$CLIENT_DIR/ssh_config.changed-host" 'echo BOKADOR_LINK_OK'
expect_ssh_failure 'changed host key: stderr "REMOTE HOST IDENTIFICATION HAS CHANGED"' \
    'REMOTE HOST IDENTIFICATION HAS CHANGED'
expect_match 'changed host key: also reports the verification failure' \
    'Host key verification failed' "$ERR"
ssh_with "$CLIENT_DIR/ssh_config.wrong-key" 'echo BOKADOR_LINK_OK'
expect_ssh_failure 'unauthorized key, no password fallback: stderr "Permission denied"' \
    'Permission denied'
ssh_with "$CLIENT_DIR/ssh_config.closed-port" 'echo BOKADOR_LINK_OK'
expect_ssh_failure 'closed port: stderr "Connection refused"' 'Connection refused'
expect_eq 'none of these attempts changed the known_hosts of the kit (content checksum)' \
    "$kit_known_hosts_before" "$(cksum < "$CLIENT_DIR/known_hosts")"

# ---------------------------------------------------------------------------
section 'Upload through stdin, then install (design section 4.6, step 5)'
# ---------------------------------------------------------------------------

readonly UPLOAD_COMMAND="umask 022; cat > $VPS_HELPER.new && chmod 755 $VPS_HELPER.new && mv -f $VPS_HELPER.new $VPS_HELPER && $VPS_HELPER install"
printf '  remote command: %s\n' "$UPLOAD_COMMAND"
ssh_run "$UPLOAD_COMMAND" "$SOURCE_HELPER"
expect_result 'upload + install: stdout is exactly "BOKADOR_LINK_INSTALLED <version>"' 0 \
    "BOKADOR_LINK_INSTALLED $VERSION"
if [[ -f "$VPS_HELPER" ]]; then
    expect_eq 'the uploaded helper is byte for byte the repository file' \
        "$SOURCE_SUM" "$(cksum < "$VPS_HELPER")"
    expect_eq 'the uploaded helper has mode 755' '755' "$(stat -c '%a' "$VPS_HELPER")"
else
    fail 'the uploaded helper exists' "missing: $VPS_HELPER"
fi
expect_absent 'no .new file is left next to the helper' "$VPS_HELPER.new"
expect_exists 'install created /var/lib/bokador-link under BL_ROOT' "$STATE_DIR"
expect_exists 'install created /etc/bokador-link under BL_ROOT' "$ETC_DIR"
expect_eq 'the service unit runs "<VpsHelper> check"' '1' \
    "$(grep -cFx "ExecStart=$VPS_HELPER check" "$UNIT_DIR/bokador-link-check.service" 2>/dev/null || true)"
expect_exists 'the timer unit is written' "$UNIT_DIR/bokador-link-check.timer"
if [[ ! -x "$VPS_HELPER" || ! -d "$STATE_DIR" || ! -d "$ETC_DIR" ]]; then
    # Nothing below can work without the installed helper.
    finish
fi

ssh_run "$UPLOAD_COMMAND" "$SOURCE_HELPER"
expect_result 'running the same upload + install again is safe' 0 "BOKADOR_LINK_INSTALLED $VERSION"

# The administrator of the VPS drops an optional notify hook.
cat > "$ETC_DIR/notify" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$#" "\${1-}" "\${2-}" >> $(printf '%q' "$NOTIFY_LOG")
EOF
chmod 755 "$ETC_DIR/notify"

# ---------------------------------------------------------------------------
section 'Heartbeat and status (design section 4.5, measure "Probe")'
# ---------------------------------------------------------------------------

printf '  remote command: %s\n' "$VPS_HELPER heartbeat $CLIENT_LABEL"
epoch_before="$(date +%s)"
ssh_run "$VPS_HELPER heartbeat $CLIENT_LABEL"
epoch_after="$(date +%s)"
expect_eq 'heartbeat: exit code 0' '0' "$RC"
if [[ "$OUT" =~ ^BOKADOR_LINK_OK\ ([0-9]+)\ (up|down|unknown)$'\n'$ ]]; then
    pass 'heartbeat: one line matching ^BOKADOR_LINK_OK ([0-9]+) (up|down|unknown)$'
    heartbeat_epoch="${BASH_REMATCH[1]}"
    expect_eq 'heartbeat: the VPS sees the link up' 'up' "${BASH_REMATCH[2]}"
    if (( heartbeat_epoch >= epoch_before && heartbeat_epoch <= epoch_after )); then
        pass 'heartbeat: the epoch is the current time'
    else
        fail 'heartbeat: the epoch is the current time' \
            "got $heartbeat_epoch, expected $epoch_before..$epoch_after"
    fi
else
    fail 'heartbeat: one line matching ^BOKADOR_LINK_OK ([0-9]+) (up|down|unknown)$' \
        "exit $RC, stdout $(printf '%q' "$OUT")" "stderr $(printf '%q' "$ERR")"
fi
expect_eq 'heartbeat: the label is recorded in the client file' "$CLIENT_LABEL" \
    "$(cat "$STATE_DIR/client" 2>/dev/null || true)"
expect_eq 'heartbeat: unknown -> up calls the notify hook with "up 0"' '2|up|0' \
    "$(cat "$NOTIFY_LOG")"

printf '  remote command: %s\n' "$VPS_HELPER status"
ssh_run "$VPS_HELPER status"
expect_eq 'status: exit code 0' '0' "$RC"
expect_match 'status: exact format, state up' \
    "^status=up heartbeat_age=[0-9]+ since=[0-9]+ stale_after=600 version=${VERSION//./\\.}"$'\n''$' \
    "$OUT"

# ---------------------------------------------------------------------------
section 'probe-port and a real reverse tunnel (design section 4.5, measure "Forwards")'
# ---------------------------------------------------------------------------

if ! pick_port "$SSHD_PORT"; then
    fail 'a free port is available for the reverse tunnel'
    finish
fi
TUNNEL_PORT="$PICKED_PORT"
printf '  remote command: %s\n' "$VPS_HELPER probe-port $TUNNEL_PORT"
ssh_run "$VPS_HELPER probe-port $TUNNEL_PORT"
expect_result 'before the tunnel: "PORT <port> CLOSED", exit code 1' 1 "PORT $TUNNEL_PORT CLOSED"

# What the supervisor runs: ssh -F <ssh_config> -E <log> -n -N -T -R <spec> <HostAlias>.
readonly TUNNEL_SPEC="127.0.0.1:$TUNNEL_PORT:127.0.0.1:$SSHD_PORT"
printf '  tunnel: ssh -F <ssh_config> -E <log> -n -N -T -R %s %s\n' "$TUNNEL_SPEC" "$HOST_ALIAS"
ssh -F "$CLIENT_DIR/ssh_config" -E "$CLIENT_DIR/ssh-tunnel.err.log" -n -N -T \
    -R "$TUNNEL_SPEC" "$HOST_ALIAS" > /dev/null 2>&1 &
TUNNEL_PID=$!

if wait_probe OPEN; then
    pass 'the reverse tunnel comes up'
else
    fail 'the reverse tunnel comes up' "last answer: exit $RC, stdout $(printf '%q' "$OUT")"
fi
expect_result 'with the tunnel: "PORT <port> OPEN", exit code 0' 0 "PORT $TUNNEL_PORT OPEN"
if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    pass 'the tunnel process is still running'
else
    fail 'the tunnel process is still running'
fi
banner=''
if { exec 3<> "/dev/tcp/127.0.0.1/$TUNNEL_PORT"; } 2>/dev/null; then
    IFS= read -r -t 10 banner <&3 || true
    exec 3>&-
fi
expect_match 'traffic crosses the tunnel (banner of the forwarded service)' '^SSH-2\.0-' "$banner"

kill "$TUNNEL_PID" 2>/dev/null || true
wait "$TUNNEL_PID" 2>/dev/null || true
if [[ ! -d "/proc/$TUNNEL_PID" ]]; then
    pass 'the tunnel process is killed'
else
    fail 'the tunnel process is killed' "pid $TUNNEL_PID still exists"
fi
STOPPED_PIDS+="$TUNNEL_PID "
TUNNEL_PID=''
if wait_probe CLOSED; then
    pass 'the forwarded port closes once the tunnel is dead'
else
    fail 'the forwarded port closes once the tunnel is dead' \
        "last answer: exit $RC, stdout $(printf '%q' "$OUT")"
fi
expect_result 'after the tunnel: "PORT <port> CLOSED", exit code 1' 1 "PORT $TUNNEL_PORT CLOSED"

ssh_run "$VPS_HELPER probe-port 70000"
expect_result 'probe-port with an invalid port: exit code 2 crosses ssh' 2 ''

# ---------------------------------------------------------------------------
section 'Stale heartbeat: check flips the state to down and calls the notify hook'
# ---------------------------------------------------------------------------

# BL_NOW cannot cross ssh: an old epoch is written into the heartbeat file.
stale_epoch=$(( $(date +%s) - STALE_SECONDS ))
if [[ ! -f "$STATE_DIR/heartbeat" ]]; then
    fail 'the heartbeat file exists before it is made stale' "missing: $STATE_DIR/heartbeat"
    finish
fi
printf '%s\n' "$stale_epoch" > "$STATE_DIR/heartbeat"
ssh_run "$VPS_HELPER status"
expect_match 'before check: still recorded as up, with the old heartbeat age' \
    '^status=up heartbeat_age=36[0-9][0-9] since=[0-9]+ stale_after=600 ' "$OUT"

printf '  remote command (run by the timer on a real VPS): %s\n' "$VPS_HELPER check"
check_before="$(date +%s)"
ssh_run "$VPS_HELPER check"
check_after="$(date +%s)"
expect_result 'check: prints nothing, exit code 0' 0 ''
ssh_run "$VPS_HELPER status"
expect_match 'after check: the state is down' \
    '^status=down heartbeat_age=36[0-9][0-9] since=[0-9]+ stale_after=600 ' "$OUT"
status_line="$(cat "$STATE_DIR/status" 2>/dev/null || true)"
if [[ "$status_line" =~ ^down\ ([0-9]+)$ ]] \
    && (( BASH_REMATCH[1] >= check_before && BASH_REMATCH[1] <= check_after )); then
    pass 'the status file is "down <epoch of the check>"'
else
    fail 'the status file is "down <epoch of the check>"' \
        "got $(printf '%q' "$status_line"), expected an epoch in $check_before..$check_after"
fi

mapfile -t notified < "$NOTIFY_LOG"
expect_eq 'the notify hook has been called twice' '2' "${#notified[@]}"
expect_eq 'the first call of the notify hook is "up 0"' '2|up|0' "${notified[0]-}"
if [[ "${notified[1]-}" =~ ^2\|down\|([0-9]+)$ ]] \
    && (( BASH_REMATCH[1] >= check_before - stale_epoch && BASH_REMATCH[1] <= check_after - stale_epoch )); then
    pass 'the notify hook received "down <heartbeat age>"'
else
    fail 'the notify hook received "down <heartbeat age>"' \
        "got $(printf '%q' "${notified[1]-}")" \
        "expected an age in $((check_before - stale_epoch))..$((check_after - stale_epoch))"
fi

ssh_run "$VPS_HELPER check"
expect_result 'a second check: prints nothing, exit code 0' 0 ''
expect_eq 'a second check does not call the notify hook again' '2' \
    "$(grep -c '' "$NOTIFY_LOG")"

ssh_run "$VPS_HELPER heartbeat $CLIENT_LABEL"
expect_match 'the next heartbeat answers "up" again' \
    '^BOKADOR_LINK_OK [0-9]+ up'$'\n''$' "$OUT"
expect_eq 'down -> up calls the notify hook with "up 0"' '2|up|0' \
    "$(sed -n '3p' "$NOTIFY_LOG")"
expect_eq 'three transitions, three calls of the notify hook' '3' "$(grep -c '' "$NOTIFY_LOG")"

# ---------------------------------------------------------------------------
section 'Uninstall (design section 4.7)'
# ---------------------------------------------------------------------------

printf '  remote command: %s\n' "$VPS_HELPER uninstall"
ssh_run "$VPS_HELPER uninstall"
expect_result 'uninstall: stdout is exactly "BOKADOR_LINK_UNINSTALLED"' 0 'BOKADOR_LINK_UNINSTALLED'
expect_absent 'uninstall: the helper removed itself' "$VPS_HELPER"
expect_absent 'uninstall: /var/lib/bokador-link is removed' "$STATE_DIR"
expect_absent 'uninstall: the timer unit is removed' "$UNIT_DIR/bokador-link-check.timer"
expect_absent 'uninstall: the service unit is removed' "$UNIT_DIR/bokador-link-check.service"
expect_exists 'uninstall without --purge keeps /etc/bokador-link' "$ETC_DIR/notify"
ssh_run 'echo BOKADOR_LINK_OK'
expect_result 'the simple probe still works once the VPS side is gone' 0 'BOKADOR_LINK_OK'

# ---------------------------------------------------------------------------
section 'Shutdown: no process, no listener and no stray file left behind'
# ---------------------------------------------------------------------------

deadline=$((SECONDS + 10))
remaining="$(descendants_of "$SSHD_PID")"
while [[ -n "$remaining" ]] && (( SECONDS < deadline )); do
    sleep 0.1
    remaining="$(descendants_of "$SSHD_PID")"
done
expect_eq 'every ssh session ended on its own (sshd has no child left)' '' "$remaining"

sshd_pid="$SSHD_PID"
stop_all
if [[ ! -d "/proc/$sshd_pid" ]]; then
    pass 'sshd is stopped'
else
    fail 'sshd is stopped' "pid $sshd_pid still exists"
fi
deadline=$((SECONDS + 5))
while port_open "$SSHD_PORT" && (( SECONDS < deadline )); do
    sleep 0.1
done
if port_open "$SSHD_PORT"; then
    fail "nothing listens on 127.0.0.1:$SSHD_PORT any more"
else
    pass "nothing listens on 127.0.0.1:$SSHD_PORT any more"
fi
left=''
for pid in $STOPPED_PIDS; do
    if [[ -d "/proc/$pid" ]]; then
        left+="$pid "
    fi
done
expect_eq 'no process started by the test is left (sshd, sessions, tunnel)' '' "$left"

expect_eq 'the repository copy of vps/bokador-link is intact' \
    "$SOURCE_SUM" "$(cksum < "$SOURCE_HELPER")"
expect_eq 'the real paths of the helper (/etc, /var/lib, /usr/local/sbin) are as before' \
    "$REAL_BEFORE" "$(real_paths_snapshot)"

finish
