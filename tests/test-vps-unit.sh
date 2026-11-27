#!/usr/bin/env bash
# Unit tests for vps/bokador-link (docs/DESIGN.md, sections 5 and 6).
#
# Every subcommand is run against a throwaway BL_ROOT, with BL_NO_SYSTEMD=1
# and a simulated clock (BL_NOW). The helper under test is always a copy made
# in the temporary directory, because "uninstall" removes the file it is run
# from. "logger" and "systemctl" are replaced by recording stubs, so nothing
# outside the temporary directory is touched and no network is needed
# (the only sockets are on 127.0.0.1).
#
# Exit code 0 when every check passes, 1 otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SOURCE_HELPER="$REPO_ROOT/vps/bokador-link"
readonly T0=1700000000
readonly HELPER_PATH_RE='^/[A-Za-z0-9/._-]{1,200}$'

PASSED=0
FAILED=0
SKIPPED=0

TMP=''
ROOT=''
HELPER=''
HELPER_DIR=''
STATE_DIR=''
ETC_DIR=''
UNIT_DIR=''
CRON_FILE=''
SANDBOX_SEQ=0
OUT=''
ERR=''
RC=0
LISTENER_PID=''
LISTENER_PORT=''
VERSION=''

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

skip() {
    SKIPPED=$((SKIPPED + 1))
    printf '  SKIP  %s\n' "$1"
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

expect_file() {
    # expect_file <description> <path> <expected content, final newline excluded>
    local actual=''
    if [[ ! -f "$2" ]]; then
        fail "$1" "missing file: $2"
        return 0
    fi
    actual="$(cat "$2"; printf 'x')"
    actual="${actual%x}"
    if [[ "$actual" == "$3"$'\n' ]]; then
        pass "$1"
    else
        fail "$1" "expected: $(printf '%q' "$3"$'\n')" "actual:   $(printf '%q' "$actual")"
    fi
}

expect_line() {
    # expect_line <description> <path> <whole line that must be present exactly once>
    local count=0
    if [[ -f "$2" ]]; then
        count="$(grep -cFx -- "$3" "$2" || true)"
    fi
    if [[ "$count" == 1 ]]; then
        pass "$1"
    else
        fail "$1" "expected exactly one line: $3" "found $count in: $2"
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

# ---------------------------------------------------------------------------
# Running the helper
# ---------------------------------------------------------------------------

# run_raw <cwd> <program> [NAME=VALUE]... -- [argument]...
# Sets OUT (exact stdout), ERR (stderr) and RC. The BL_* variables of the
# caller never leak into the run.
run_raw() {
    local cwd="$1" program="$2"
    local -a envs
    shift 2
    envs=("PATH=$RUN_PATH")
    while [[ $# -gt 0 && "$1" != '--' ]]; do
        envs+=("$1")
        shift
    done
    shift
    RC=0
    (
        cd "$cwd"
        exec env -u BL_ROOT -u BL_NOW -u BL_NO_SYSTEMD -u BL_FORCE_CRON \
            "${envs[@]}" "$program" "$@"
    ) > "$TMP/stdout" 2> "$TMP/stderr" < /dev/null || RC=$?
    OUT="$(cat "$TMP/stdout"; printf 'x')"
    OUT="${OUT%x}"
    ERR="$(cat "$TMP/stderr")"
}

# run_helper [NAME=VALUE]... -- [argument]...  (always under the fake root)
run_helper() {
    if [[ -z "$ROOT" || "$ROOT" != "$TMP"/* ]]; then
        printf 'internal error: refusing to run the helper outside the sandbox\n' >&2
        exit 99
    fi
    run_raw "$TMP" "$HELPER" "BL_ROOT=$ROOT" "$@"
}

bl() {
    run_helper BL_NO_SYSTEMD=1 -- "$@"
}

bl_at() {
    local now="$1"
    shift
    run_helper BL_NO_SYSTEMD=1 "BL_NOW=$now" -- "$@"
}

# A fresh fake root and a fresh copy of the helper.
new_sandbox() {
    SANDBOX_SEQ=$((SANDBOX_SEQ + 1))
    ROOT="$TMP/root$SANDBOX_SEQ"
    HELPER_DIR="$TMP/sbin$SANDBOX_SEQ"
    HELPER="$HELPER_DIR/bokador-link"
    STATE_DIR="$ROOT/var/lib/bokador-link"
    ETC_DIR="$ROOT/etc/bokador-link"
    UNIT_DIR="$ROOT/etc/systemd/system"
    CRON_FILE="$ROOT/etc/cron.d/bokador-link"
    mkdir -p "$ROOT" "$HELPER_DIR"
    cp "$SOURCE_HELPER" "$HELPER"
    chmod 755 "$HELPER"
    : > "$LOGGER_LOG"
    : > "$SYSTEMCTL_LOG"
    : > "$NOTIFY_LOG"
    : > "$TIMEOUT_LOG"
    : > "$SLEEP_LOG"
    rm -f "$MARK"
}

# Notify hook that records "<argc>|<arg1>|<arg2>"; extra lines are appended.
install_hook() {
    mkdir -p "$ETC_DIR"
    cat > "$ETC_DIR/notify" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$#" "\${1-}" "\${2-}" >> $NOTIFY_LOG_Q
${1-}
EOF
    chmod 755 "$ETC_DIR/notify"
}

# Names found in a directory, dot files included, separated by spaces.
list_dir() {
    local dir="$1" entry out=''
    for entry in "$dir"/* "$dir"/.[!.]*; do
        if [[ -e "$entry" || -L "$entry" ]]; then
            out+="${entry##*/} "
        fi
    done
    printf '%s' "${out% }"
}

# Types, modes, modification times and checksums of everything under a directory.
snapshot() {
    (
        cd "$1"
        find . -printf '%y %m %T@ %p\n' | sort
        find . -type f -exec cksum {} + | sort
    )
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

wait_for() {
    # wait_for <seconds> <command>...: polls until the command succeeds.
    local deadline=$((SECONDS + $1))
    shift
    while ! "$@"; do
        if (( SECONDS >= deadline )); then
            return 1
        fi
        sleep 0.1
    done
    return 0
}

# Real location of a tool. System directories first: a wrapper placed earlier
# on PATH may need the rest of PATH to find the tool it wraps.
real_tool() {
    local dir
    for dir in /usr/bin /bin /usr/sbin /sbin; do
        if [[ -f "$dir/$1" && -x "$dir/$1" ]]; then
            printf '%s\n' "$dir/$1"
            return 0
        fi
    done
    command -v "$1"
}

readonly LISTENER_PY='
import os, socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(16)
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write("%d\n" % s.getsockname()[1])
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
while True:
    conn, _ = s.accept()
    conn.close()
'

# TCP listener on a port chosen by the kernel (127.0.0.1 only).
start_listener() {
    local python=''
    python="$(command -v python3 || true)"
    if [[ -z "$python" ]]; then
        return 1
    fi
    rm -f "$TMP/listener.port"
    "$python" -c "$LISTENER_PY" "$TMP/listener.port" > /dev/null 2>&1 &
    LISTENER_PID=$!
    if ! wait_for 10 test -s "$TMP/listener.port"; then
        return 1
    fi
    LISTENER_PORT="$(cat "$TMP/listener.port")"
    return 0
}

stop_listener() {
    if [[ -n "$LISTENER_PID" ]]; then
        kill "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
        LISTENER_PID=''
    fi
}

trap 'stop_listener; if [[ -n "$TMP" && -d "$TMP" ]]; then rm -rf -- "$TMP"; fi' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

printf 'test-vps-unit: unit tests of vps/bokador-link\n'

if [[ ! -f "$SOURCE_HELPER" ]]; then
    printf '  FAIL  %s does not exist\n' "$SOURCE_HELPER"
    printf '\ntest-vps-unit: 0 passed, 1 failed, 0 skipped\n'
    exit 1
fi

# The helper only installs itself from a path made of safe characters, like
# the VpsHelper path validated by the Windows side.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bl-unit.XXXXXXXX")"
if [[ ! "$TMP/sbin999/bokador-link" =~ $HELPER_PATH_RE ]]; then
    rmdir "$TMP"
    TMP="$(mktemp -d /tmp/bl-unit.XXXXXXXX)"
fi
TMP="$(cd "$TMP" && pwd -P)"

readonly STUB_BIN="$TMP/stub-bin"
readonly LOGGER_LOG="$TMP/logger.log"
readonly SYSTEMCTL_LOG="$TMP/systemctl.log"
readonly NOTIFY_LOG="$TMP/notify.log"
readonly TIMEOUT_LOG="$TMP/timeout.log"
readonly SLEEP_LOG="$TMP/sleep.log"
readonly MARK="$TMP/INJECTED"
NOTIFY_LOG_Q="$(printf '%q' "$NOTIFY_LOG")"
readonly NOTIFY_LOG_Q
REAL_SLEEP="$(real_tool sleep)"
REAL_TIMEOUT="$(real_tool timeout)"
readonly REAL_SLEEP REAL_TIMEOUT
readonly BASE_PATH="$PATH"
RUN_PATH="$STUB_BIN:$BASE_PATH"

mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/logger" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> $(printf '%q' "$LOGGER_LOG")
EOF
cat > "$STUB_BIN/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> $(printf '%q' "$SYSTEMCTL_LOG")
exit "\${STUB_SYSTEMCTL_RC:-0}"
EOF
chmod 755 "$STUB_BIN/logger" "$STUB_BIN/systemctl"

SOURCE_SUM_BEFORE="$(cksum < "$SOURCE_HELPER")"
REAL_BEFORE="$(real_paths_snapshot)"

# ---------------------------------------------------------------------------
section 'Static properties of vps/bokador-link (design section 3)'
# ---------------------------------------------------------------------------

expect_eq 'file mode is 755' '755' "$(stat -c '%a' "$SOURCE_HELPER")"
IFS= read -r first_line < "$SOURCE_HELPER" || true
expect_eq 'first line is the env bash shebang' '#!/usr/bin/env bash' "$first_line"
expect_eq 'contains the line "set -euo pipefail"' '1' \
    "$(grep -cx 'set -euo pipefail' "$SOURCE_HELPER" || true)"
expect_eq 'no CR byte (LF line endings)' '0' "$(grep -c $'\r' "$SOURCE_HELPER" || true)"
if bash -n "$SOURCE_HELPER" 2> "$TMP/stderr"; then
    pass 'bash -n accepts the file'
else
    fail 'bash -n accepts the file' "$(cat "$TMP/stderr")"
fi
sourcing="$(grep -vE '^[[:space:]]*#' "$SOURCE_HELPER" \
    | grep -nE '(^|[;&|({[:space:]])(source|eval)([[:space:]]|$)|^[[:space:]]*\.[[:space:]]+[^[:space:]]' || true)"
expect_eq 'no "source", "." or "eval" (the config file is parsed, never sourced)' '' "$sourcing"

# ---------------------------------------------------------------------------
section 'version, usage and unknown commands'
# ---------------------------------------------------------------------------

new_sandbox
run_raw "$TMP" "$HELPER" -- version
expect_eq 'version: exit code 0 without BL_ROOT' '0' "$RC"
expect_match 'version: prints exactly "bokador-link <version>"' \
    '^bokador-link [0-9]+\.[0-9]+\.[0-9]+'$'\n''$' "$OUT"
VERSION="${OUT#bokador-link }"
VERSION="${VERSION%$'\n'}"

bl
expect_result 'no command: exit code 2, nothing on stdout' 2 ''
expect_match 'no command: usage on stderr' 'usage: bokador-link' "$ERR"
bl frobnicate
expect_result 'unknown command: exit code 2, nothing on stdout' 2 ''
expect_match 'unknown command: usage on stderr' 'usage: bokador-link' "$ERR"
bl --help
expect_result '--help is not a command: exit code 2, nothing on stdout' 2 ''
bl version extra
expect_result 'version with an extra argument: exit code 2' 2 ''
bl status extra
expect_result 'status with an extra argument: exit code 2' 2 ''
bl check extra
expect_result 'check with an extra argument: exit code 2' 2 ''
bl install extra
expect_result 'install with an extra argument: exit code 2' 2 ''
expect_eq 'install with an extra argument creates nothing' '' "$(list_dir "$ROOT")"

# ---------------------------------------------------------------------------
section 'Before any heartbeat: state "unknown"'
# ---------------------------------------------------------------------------

new_sandbox
install_hook
bl_at "$T0" status
expect_result 'status: unknown, no age, no since, default stale_after' 0 \
    "status=unknown heartbeat_age=none since=none stale_after=600 version=$VERSION"
bl_at "$T0" check
expect_result 'check: prints nothing, exit code 0' 0 ''
expect_absent 'check: no status file is created' "$STATE_DIR/status"
expect_absent 'check: no state directory is created' "$STATE_DIR"
expect_eq 'check: notify hook not called' '' "$(cat "$NOTIFY_LOG")"
expect_eq 'check: nothing logged' '' "$(cat "$LOGGER_LOG")"

# ---------------------------------------------------------------------------
section 'install with BL_NO_SYSTEMD=1: units written, systemctl never called'
# ---------------------------------------------------------------------------

new_sandbox
mkdir -p "$ROOT/run/systemd/system"
bl install
expect_result 'install: stdout is exactly "BOKADOR_LINK_INSTALLED <version>"' 0 \
    "BOKADOR_LINK_INSTALLED $VERSION"
expect_exists 'install: creates /var/lib/bokador-link' "$STATE_DIR"
expect_exists 'install: creates /etc/bokador-link' "$ETC_DIR"
expect_line 'service unit: Type=oneshot' "$UNIT_DIR/bokador-link-check.service" 'Type=oneshot'
expect_line 'service unit: ExecStart=<absolute path of the helper> check' \
    "$UNIT_DIR/bokador-link-check.service" "ExecStart=$HELPER check"
expect_line 'timer unit: OnBootSec=2min' "$UNIT_DIR/bokador-link-check.timer" 'OnBootSec=2min'
expect_line 'timer unit: OnUnitActiveSec=5min' "$UNIT_DIR/bokador-link-check.timer" \
    'OnUnitActiveSec=5min'
expect_line 'timer unit: WantedBy=timers.target' "$UNIT_DIR/bokador-link-check.timer" \
    'WantedBy=timers.target'
expect_eq 'unit files have mode 644' '644 644' \
    "$(stat -c '%a' "$UNIT_DIR/bokador-link-check.service") $(stat -c '%a' "$UNIT_DIR/bokador-link-check.timer")"
expect_eq 'unit directory holds the two units and no temporary file' \
    'bokador-link-check.service bokador-link-check.timer' "$(list_dir "$UNIT_DIR")"
expect_absent 'no cron file' "$CRON_FILE"
expect_eq 'systemctl never called, even with /run/systemd/system present' '' \
    "$(cat "$SYSTEMCTL_LOG")"
if [[ "$HELPER" != "$ROOT"/* ]]; then
    pass 'the path written in the unit is not prefixed by BL_ROOT'
else
    fail 'the path written in the unit is not prefixed by BL_ROOT' "helper: $HELPER"
fi

before="$(snapshot "$ROOT")"
bl install
expect_result 'install again: same output, exit code 0' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_eq 'install again: nothing changed (content, modes, modification times)' \
    "$before" "$(snapshot "$ROOT")"

new_sandbox
run_raw "$HELPER_DIR" ./bokador-link "BL_ROOT=$ROOT" BL_NO_SYSTEMD=1 -- install
expect_result 'install through a relative path: exit code 0' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_line 'install through a relative path: ExecStart is absolute' \
    "$UNIT_DIR/bokador-link-check.service" "ExecStart=$HELPER check"

new_sandbox
ln -s "$HELPER" "$TMP/link-to-helper"
run_raw "$TMP" "$TMP/link-to-helper" "BL_ROOT=$ROOT" BL_NO_SYSTEMD=1 -- install
expect_result 'install through a symbolic link: exit code 0' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_line 'install through a symbolic link: ExecStart is the resolved file' \
    "$UNIT_DIR/bokador-link-check.service" "ExecStart=$HELPER check"

new_sandbox
mkdir -p "$TMP/bad dir"
cp "$HELPER" "$TMP/bad dir/bokador-link"
run_raw "$TMP" "$TMP/bad dir/bokador-link" "BL_ROOT=$ROOT" BL_NO_SYSTEMD=1 -- install
expect_result 'install from a path with a space: refused (exit 1), no success line' 1 ''
expect_absent 'install from a path with a space: no unit written' \
    "$UNIT_DIR/bokador-link-check.service"

new_sandbox
chmod 644 "$HELPER"
run_raw "$TMP" bash "BL_ROOT=$ROOT" BL_NO_SYSTEMD=1 -- "$HELPER" install
expect_result 'install of a non-executable file: refused (exit 1), no success line' 1 ''
expect_absent 'install of a non-executable file: no unit written' \
    "$UNIT_DIR/bokador-link-check.service"

new_sandbox
RC=0
(
    cd "$TMP"
    exec env -u BL_NOW -u BL_FORCE_CRON "PATH=$RUN_PATH" "BL_ROOT=$ROOT" BL_NO_SYSTEMD=1 \
        bash -s -- install
) < "$HELPER" > "$TMP/stdout" 2> "$TMP/stderr" || RC=$?
OUT="$(cat "$TMP/stdout")"
ERR="$(cat "$TMP/stderr")"
expect_result 'install read from stdin (no file path): refused (exit 1), no success line' 1 ''

# ---------------------------------------------------------------------------
section 'Transitions unknown -> up -> down -> up, notify hook and logger'
# ---------------------------------------------------------------------------

new_sandbox
bl install
install_hook
bl_at "$T0" check
expect_result 'check before the first heartbeat: silent' 0 ''
expect_eq 'unknown: notify hook not called' '' "$(cat "$NOTIFY_LOG")"

bl_at "$T0" heartbeat pc-1
expect_result 'first heartbeat: "BOKADOR_LINK_OK <epoch> up"' 0 "BOKADOR_LINK_OK $T0 up"
expect_file 'heartbeat file holds the epoch' "$STATE_DIR/heartbeat" "$T0"
expect_file 'client file holds the label' "$STATE_DIR/client" 'pc-1'
expect_file 'status file is "up <epoch of the change>"' "$STATE_DIR/status" "up $T0"
expect_eq 'state directory: heartbeat, status, client and no temporary file' \
    'client heartbeat status' "$(list_dir "$STATE_DIR")"
expect_eq 'state files have mode 644' '644 644 644' \
    "$(stat -c '%a' "$STATE_DIR/heartbeat") $(stat -c '%a' "$STATE_DIR/status") $(stat -c '%a' "$STATE_DIR/client")"
expect_file 'unknown -> up: notify called once with "up 0"' "$NOTIFY_LOG" '2|up|0'

bl_at $((T0 + 100)) status
expect_result 'status while up: exact format' 0 \
    "status=up heartbeat_age=100 since=$T0 stale_after=600 version=$VERSION"

bl_at $((T0 + 600)) check
expect_result 'check at age = STALE_AFTER: silent' 0 ''
expect_file 'age = STALE_AFTER is still up' "$STATE_DIR/status" "up $T0"
expect_file 'no transition: notify not called again' "$NOTIFY_LOG" '2|up|0'

bl_at $((T0 + 601)) check
expect_result 'check at age = STALE_AFTER + 1: silent' 0 ''
expect_file 'up -> down: status file is "down <epoch of the change>"' \
    "$STATE_DIR/status" "down $((T0 + 601))"
expect_file 'up -> down: notify called with "down <age>"' "$NOTIFY_LOG" '2|up|0
2|down|601'

bl_at $((T0 + 700)) check
expect_file 'still down: the epoch of the change is kept' "$STATE_DIR/status" "down $((T0 + 601))"
expect_file 'still down: notify not called again' "$NOTIFY_LOG" '2|up|0
2|down|601'
bl_at $((T0 + 700)) status
expect_result 'status while down: exact format' 0 \
    "status=down heartbeat_age=700 since=$((T0 + 601)) stale_after=600 version=$VERSION"

# Hard links keep the previous files reachable: an atomic replacement (new
# file, then rename) leaves them untouched, a write in place would not.
ln "$STATE_DIR/heartbeat" "$TMP/heartbeat.before"
ln "$STATE_DIR/status" "$TMP/status.before"
ln "$STATE_DIR/client" "$TMP/client.before"
bl_at $((T0 + 800)) heartbeat pc-2
expect_result 'heartbeat after down: "BOKADOR_LINK_OK <epoch> up"' 0 \
    "BOKADOR_LINK_OK $((T0 + 800)) up"
expect_file 'down -> up: status file' "$STATE_DIR/status" "up $((T0 + 800))"
expect_file 'heartbeat file updated' "$STATE_DIR/heartbeat" "$((T0 + 800))"
expect_file 'client file updated with the new label' "$STATE_DIR/client" 'pc-2'
expect_file 'atomic write: the previous heartbeat file was replaced, not rewritten' \
    "$TMP/heartbeat.before" "$T0"
expect_file 'atomic write: the previous status file was replaced, not rewritten' \
    "$TMP/status.before" "down $((T0 + 601))"
expect_file 'atomic write: the previous client file was replaced, not rewritten' \
    "$TMP/client.before" 'pc-1'
rm -f "$TMP/heartbeat.before" "$TMP/status.before" "$TMP/client.before"
expect_file 'down -> up: notify called with "up 0" (three calls in total)' "$NOTIFY_LOG" '2|up|0
2|down|601
2|up|0'
expect_eq 'state directory still holds exactly three files' \
    'client heartbeat status' "$(list_dir "$STATE_DIR")"

mapfile -t logged < "$LOGGER_LOG"
expect_eq 'logger called once per transition (three times)' '3' "${#logged[@]}"
expect_match 'logger: tag bokador-link, unknown -> up' \
    '^-t bokador-link .*unknown -> up' "${logged[0]-}"
expect_match 'logger: tag bokador-link, up -> down' \
    '^-t bokador-link .*up -> down' "${logged[1]-}"
expect_match 'logger: tag bokador-link, down -> up' \
    '^-t bokador-link .*down -> up' "${logged[2]-}"

bl_at $((T0 + 700)) status
expect_result 'clock earlier than the heartbeat: age reported as 0' 0 \
    "status=up heartbeat_age=0 since=$((T0 + 800)) stale_after=600 version=$VERSION"

# ---------------------------------------------------------------------------
section 'Notify hook: failures never fail the command'
# ---------------------------------------------------------------------------

new_sandbox
bl install
install_hook 'exit 7'
bl_at "$T0" heartbeat pc-1
expect_result 'failing hook: heartbeat still answers, exit code 0' 0 "BOKADOR_LINK_OK $T0 up"
expect_file 'failing hook: it was called' "$NOTIFY_LOG" '2|up|0'
expect_match 'failing hook: the failure and its code are logged' \
    'notify.*code 7' "$(cat "$LOGGER_LOG")"
bl_at $((T0 + 601)) check
expect_result 'failing hook: check still exits 0' 0 ''
expect_file 'failing hook: the transition is recorded anyway' "$STATE_DIR/status" \
    "down $((T0 + 601))"

new_sandbox
bl install
install_hook
chmod 644 "$ETC_DIR/notify"
bl_at "$T0" heartbeat pc-1
expect_result 'non-executable hook: heartbeat exits 0' 0 "BOKADOR_LINK_OK $T0 up"
expect_eq 'non-executable hook: not run' '' "$(cat "$NOTIFY_LOG")"
expect_match 'non-executable hook: reported in the log' 'notify' "$(cat "$LOGGER_LOG")"

new_sandbox
bl install
install_hook 'echo NOISE-ON-STDOUT
echo NOISE-ON-STDERR >&2'
bl_at "$T0" heartbeat pc-1
expect_result 'noisy hook: stdout is still exactly the contract line' 0 "BOKADOR_LINK_OK $T0 up"
expect_match 'noisy hook: its output is sent to stderr' 'NOISE-ON-STDOUT' "$ERR"

new_sandbox
bl install
install_hook 'if read -r -t 5 line; then echo "STDIN-HAD-DATA" >&2; else echo "STDIN-EMPTY" >&2; fi'
bl_at "$T0" heartbeat pc-1
expect_match 'hook: standard input is empty (/dev/null)' 'STDIN-EMPTY' "$ERR"

# A stub "timeout" records the limit asked by the helper, then applies a
# limit of 1 second so that the test stays fast.
new_sandbox
mkdir -p "$TMP/timeout-bin"
cat > "$TMP/timeout-bin/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> $(printf '%q' "$TIMEOUT_LOG")
if [[ "\${1-}" == -k ]]; then
    shift 2
fi
shift
exec $(printf '%q' "$REAL_TIMEOUT") -k 1 1 "\$@"
EOF
chmod 755 "$TMP/timeout-bin/timeout"
RUN_PATH="$TMP/timeout-bin:$STUB_BIN:$BASE_PATH"
bl install
bl_at "$T0" heartbeat pc-1
install_hook 'sleep 60'
: > "$TIMEOUT_LOG"
started=$SECONDS
bl_at $((T0 + 601)) check
elapsed=$((SECONDS - started))
expect_result 'hanging hook: check still exits 0' 0 ''
expect_match 'hanging hook: run through timeout with a limit of 30 seconds' \
    "^(-k [0-9]+ )?30 $ETC_DIR/notify down 601\$" "$(cat "$TIMEOUT_LOG")"
if (( elapsed < 20 )); then
    pass 'hanging hook: interrupted, the command does not wait for it'
else
    fail 'hanging hook: interrupted, the command does not wait for it' "took $elapsed s"
fi
expect_match 'hanging hook: the interruption is logged' \
    'notify interrompu' "$(cat "$LOGGER_LOG")"
expect_file 'hanging hook: the transition is recorded anyway' "$STATE_DIR/status" \
    "down $((T0 + 601))"
RUN_PATH="$STUB_BIN:$BASE_PATH"

# ---------------------------------------------------------------------------
section 'heartbeat labels (pattern ^[A-Za-z0-9._-]{1,64}$)'
# ---------------------------------------------------------------------------

new_sandbox
bl install
label64="$(printf 'a%.0s' {1..64})"
label65="$(printf 'a%.0s' {1..65})"
for label in 'pc-1' 'A.b_c-9' 'BOKADOR' "$label64"; do
    bl_at "$T0" heartbeat "$label"
    if [[ "$RC" == 0 && "$OUT" == "BOKADOR_LINK_OK $T0 up"$'\n' \
        && "$(cat "$STATE_DIR/client")" == "$label" ]]; then
        pass "valid label recorded: $label"
    else
        fail "valid label recorded: $label" "exit $RC, stdout $(printf '%q' "$OUT")" \
            "client file: $(cat "$STATE_DIR/client" 2>&1)"
    fi
done

bl_at "$T0" heartbeat good-label
# shellcheck disable=SC2016  # the injection attempts must stay literal
for label in "$label65" 'bad label' 'a/b' '../etc' 'a;b' "\$(touch $MARK)" "\`touch $MARK\`" \
    'caf'$'\xc3\xa9' '' $'ok\nbad' 'a*' '-x y'; do
    bl_at $((T0 + 1)) heartbeat "$label"
    if [[ "$RC" == 0 && "$OUT" == "BOKADOR_LINK_OK $((T0 + 1)) up"$'\n' \
        && "$(cat "$STATE_DIR/client")" == 'good-label' && -n "$ERR" ]]; then
        pass "invalid label ignored, heartbeat still recorded: $(printf '%q' "$label")"
    else
        fail "invalid label ignored, heartbeat still recorded: $(printf '%q' "$label")" \
            "exit $RC, stdout $(printf '%q' "$OUT")" "client file: $(cat "$STATE_DIR/client" 2>&1)"
    fi
done
bl_at $((T0 + 2)) heartbeat one two
expect_result 'two labels: heartbeat recorded, exit code 0' 0 "BOKADOR_LINK_OK $((T0 + 2)) up"
expect_file 'two labels: client file unchanged' "$STATE_DIR/client" 'good-label'
bl_at $((T0 + 3)) heartbeat
expect_result 'no label: heartbeat recorded, exit code 0' 0 "BOKADOR_LINK_OK $((T0 + 3)) up"
expect_file 'no label: client file unchanged' "$STATE_DIR/client" 'good-label'
expect_file 'no label: heartbeat file updated' "$STATE_DIR/heartbeat" "$((T0 + 3))"
expect_absent 'no label was executed as a command' "$MARK"

new_sandbox
bl_at "$T0" heartbeat pc-1
expect_result 'heartbeat without a prior install: creates the state directory' 0 \
    "BOKADOR_LINK_OK $T0 up"

# ---------------------------------------------------------------------------
section 'probe-port'
# ---------------------------------------------------------------------------

new_sandbox
# shellcheck disable=SC2016  # the injection attempts must stay literal
for port in '0' '65536' '99999' '123456' 'abc' '80x' '-1' '+80' ' 80' '8 0' '' '0x50' \
    '80;id' "\$(touch $MARK)" "a[\$(touch $MARK)]" $'80\n' '1.5'; do
    bl probe-port "$port"
    if [[ "$RC" == 2 && -z "$OUT" && -n "$ERR" ]]; then
        pass "invalid port refused with exit code 2: $(printf '%q' "$port")"
    else
        fail "invalid port refused with exit code 2: $(printf '%q' "$port")" \
            "exit $RC, stdout $(printf '%q' "$OUT")"
    fi
done
bl probe-port
expect_result 'missing port: exit code 2, nothing on stdout' 2 ''
bl probe-port 80 81
expect_result 'two ports: exit code 2, nothing on stdout' 2 ''
expect_absent 'no port argument was executed as a command' "$MARK"

if start_listener; then
    bl probe-port "$LISTENER_PORT"
    expect_result 'listening port: "PORT <port> OPEN", exit code 0' 0 "PORT $LISTENER_PORT OPEN"
    : > "$TIMEOUT_LOG"
    RUN_PATH="$TMP/timeout-bin:$STUB_BIN:$BASE_PATH"
    bl probe-port "$LISTENER_PORT"
    RUN_PATH="$STUB_BIN:$BASE_PATH"
    expect_result 'listening port, through the recording timeout: still OPEN' 0 \
        "PORT $LISTENER_PORT OPEN"
    expect_match 'the connection attempt is limited to 5 seconds' \
        '^(-k [0-9]+ )?5 ' "$(cat "$TIMEOUT_LOG")"
    stop_listener
    bl probe-port "$LISTENER_PORT"
    expect_result 'same port once the listener is gone: "PORT <port> CLOSED", exit code 1' 1 \
        "PORT $LISTENER_PORT CLOSED"
else
    fail 'probe-port on a listening port (python3 is needed to open a local listener)'
fi

for port in 1 65535 0007; do
    bl probe-port "$port"
    if [[ ( "$RC" == 0 && "$OUT" == "PORT $port OPEN"$'\n' ) \
        || ( "$RC" == 1 && "$OUT" == "PORT $port CLOSED"$'\n' ) ]]; then
        pass "port $port accepted and echoed as given (exit $RC)"
    else
        fail "port $port accepted and echoed as given" "exit $RC, stdout $(printf '%q' "$OUT")"
    fi
done

# ---------------------------------------------------------------------------
section 'Config parser: /etc/bokador-link/config (STALE_AFTER, 60..86400, default 600)'
# ---------------------------------------------------------------------------

new_sandbox
bl install

config_case() {
    # config_case <description> <expected stale_after> <warning: yes|no> <file content>
    local got='' warned='no'
    printf '%s' "$4" > "$ETC_DIR/config"
    bl_at "$T0" status
    got="${OUT#* stale_after=}"
    got="${got%% *}"
    if [[ -n "$ERR" ]]; then
        warned='yes'
    fi
    if [[ "$RC" == 0 && "$got" == "$2" && "$warned" == "$3" && ! -e "$MARK" ]]; then
        pass "$1"
    else
        fail "$1" "expected: exit 0, stale_after=$2, warning=$3" \
            "actual:   exit $RC, stale_after=$got, warning=$warned" \
            "stderr:   $(printf '%q' "$ERR")"
    fi
}

rm -f "$ETC_DIR/config"
bl_at "$T0" status
expect_result 'no config file: default 600' 0 \
    "status=unknown heartbeat_age=none since=none stale_after=600 version=$VERSION"
config_case 'empty file: default 600' 600 no ''
config_case 'valid value' 120 no $'STALE_AFTER=120\n'
config_case 'valid value without a final newline' 300 no 'STALE_AFTER=300'
config_case 'lower bound 60 accepted' 60 no $'STALE_AFTER=60\n'
config_case 'upper bound 86400 accepted' 86400 no $'STALE_AFTER=86400\n'
config_case 'leading zeros are decimal, not octal' 90 no $'STALE_AFTER=0090\n'
config_case 'comments and blank lines are skipped silently' 900 no \
    $'# comment\n\n   \n  # indented comment\nSTALE_AFTER=900\n'
config_case 'CRLF line endings are tolerated' 240 no $'# edited on Windows\r\nSTALE_AFTER=240\r\n'
config_case 'surrounding blanks are tolerated' 180 no $'  STALE_AFTER=180  \n'
config_case 'the last valid line wins' 200 no $'STALE_AFTER=100\nSTALE_AFTER=200\n'
config_case 'below range (59): default kept, warning' 600 yes $'STALE_AFTER=59\n'
config_case 'above range (86401): default kept, warning' 600 yes $'STALE_AFTER=86401\n'
config_case 'zero: default kept, warning' 600 yes $'STALE_AFTER=0\n'
config_case 'huge number: default kept, warning' 600 yes \
    $'STALE_AFTER=999999999999999999999999999999\n'
config_case 'an out-of-range line does not undo an earlier valid one' 120 yes \
    $'STALE_AFTER=120\nSTALE_AFTER=5\n'
config_case 'garbage word: ignored, warning' 600 yes $'garbage\n'
config_case 'unknown key: ignored, warning' 600 yes $'FOO=bar\n'
config_case 'non-numeric value: ignored, warning' 600 yes $'STALE_AFTER=abc\n'
config_case 'empty value: ignored, warning' 600 yes $'STALE_AFTER=\n'
config_case 'negative value: ignored, warning' 600 yes $'STALE_AFTER=-120\n'
config_case 'quoted value: ignored, warning' 600 yes $'STALE_AFTER="120"\n'
config_case 'blanks around "=": ignored, warning' 600 yes $'STALE_AFTER = 120\n'
config_case '"export" prefix: ignored, warning' 600 yes $'export STALE_AFTER=120\n'
config_case 'lower-case key: ignored, warning' 600 yes $'stale_after=120\n'
config_case 'trailing text: ignored, warning' 600 yes $'STALE_AFTER=120 seconds\n'
config_case 'garbage around a valid line: the valid line is used' 150 yes \
    $'garbage\nSTALE_AFTER=150\nFOO=bar\n'
# shellcheck disable=SC2016  # the injection attempts must stay literal
{
    config_case 'injection $(...) in the value: not executed' 600 yes \
        'STALE_AFTER=$(touch '"$MARK"')'$'\n'
    config_case 'injection with backquotes: not executed' 600 yes \
        'STALE_AFTER=`touch '"$MARK"'`'$'\n'
    config_case 'injection "; command": not executed' 600 yes \
        'STALE_AFTER=120; touch '"$MARK"$'\n'
    config_case 'injection "&& command": not executed' 600 yes \
        'STALE_AFTER=120 && touch '"$MARK"$'\n'
    config_case 'injection through an arithmetic subscript: not executed' 600 yes \
        'STALE_AFTER=a[$(touch '"$MARK"')]'$'\n'
    config_case 'bare command line: not executed' 600 yes \
        'touch '"$MARK"$'\n''$(touch '"$MARK"')'$'\n''; touch '"$MARK"$'\n'
    config_case 'injection next to a valid line: not executed, valid line used' 300 yes \
        'STALE_AFTER=300'$'\n''STALE_AFTER=$(touch '"$MARK"')'$'\n''PATH=/nonexistent'$'\n'
}
expect_absent 'no line of the config file was executed' "$MARK"

rm -f "$ETC_DIR/config"
mkdir "$ETC_DIR/config"
bl_at "$T0" status
expect_result 'config is a directory: default 600, exit code 0' 0 \
    "status=unknown heartbeat_age=none since=none stale_after=600 version=$VERSION"
rmdir "$ETC_DIR/config"

printf 'STALE_AFTER=120\n' > "$ETC_DIR/config"
install_hook
bl_at "$T0" heartbeat pc-1
bl_at $((T0 + 120)) check
expect_file 'STALE_AFTER=120 is applied: age 120 is up' "$STATE_DIR/status" "up $T0"
bl_at $((T0 + 121)) check
expect_file 'STALE_AFTER=120 is applied: age 121 is down' "$STATE_DIR/status" \
    "down $((T0 + 121))"
bl_at $((T0 + 121)) status
expect_result 'status reports the configured stale_after' 0 \
    "status=down heartbeat_age=121 since=$((T0 + 121)) stale_after=120 version=$VERSION"
printf 'STALE_AFTER=3600\n' > "$ETC_DIR/config"
bl_at $((T0 + 500)) check
expect_file 'raising STALE_AFTER brings the link back up at the next check' \
    "$STATE_DIR/status" "up $((T0 + 500))"
expect_file 'notify called for each of the three transitions' "$NOTIFY_LOG" '2|up|0
2|down|121
2|up|500'

# ---------------------------------------------------------------------------
section 'Hostile environment and state files are never evaluated'
# ---------------------------------------------------------------------------

new_sandbox
bl install
# shellcheck disable=SC2016  # the injection attempts must stay literal
for now in "a[\$(touch $MARK)]" "\$(touch $MARK)" '12x' '-5' '1e9' ' 12'; do
    for command in status check 'heartbeat pc-1'; do
        # shellcheck disable=SC2086  # "heartbeat pc-1" is two words on purpose
        bl_at "$now" $command
        if [[ "$RC" == 2 && -z "$OUT" && ! -e "$MARK" ]]; then
            pass "invalid BL_NOW refused with exit code 2: $(printf '%q' "$now") ($command)"
        else
            fail "invalid BL_NOW refused with exit code 2: $(printf '%q' "$now") ($command)" \
                "exit $RC, stdout $(printf '%q' "$OUT")"
        fi
    done
done
expect_absent 'an invalid BL_NOW leaves no heartbeat file' "$STATE_DIR/heartbeat"

# shellcheck disable=SC2016  # the injection attempts must stay literal
for content in "a[\$(touch $MARK)]" "\$(touch $MARK)" 'garbage' '' '12 34' '-1'; do
    printf '%s\n' "$content" > "$STATE_DIR/heartbeat"
    rm -f "$STATE_DIR/status"
    bl_at "$T0" status
    status_out="$OUT"
    bl_at "$T0" check
    if [[ "$status_out" == "status=unknown heartbeat_age=none since=none stale_after=600 version=$VERSION"$'\n' \
        && "$RC" == 0 && -z "$OUT" && ! -e "$STATE_DIR/status" && ! -e "$MARK" ]]; then
        pass "invalid heartbeat file treated as no heartbeat: $(printf '%q' "$content")"
    else
        fail "invalid heartbeat file treated as no heartbeat: $(printf '%q' "$content")" \
            "status: $(printf '%q' "$status_out")" "check: exit $RC, stdout $(printf '%q' "$OUT")"
    fi
done

# shellcheck disable=SC2016  # the injection attempts must stay literal
for content in "up 12; touch $MARK" "up a[\$(touch $MARK)]" 'sideways 12' 'up' 'down -3' ''; do
    printf '%s\n' "$T0" > "$STATE_DIR/heartbeat"
    printf '%s\n' "$content" > "$STATE_DIR/status"
    bl_at $((T0 + 10)) status
    status_out="$OUT"
    bl_at $((T0 + 10)) check
    if [[ "$status_out" == "status=unknown heartbeat_age=10 since=none stale_after=600 version=$VERSION"$'\n' \
        && "$RC" == 0 && -z "$OUT" && "$(cat "$STATE_DIR/status")" == "up $((T0 + 10))" \
        && ! -e "$MARK" ]]; then
        pass "invalid status file treated as unknown, then rewritten: $(printf '%q' "$content")"
    else
        fail "invalid status file treated as unknown, then rewritten: $(printf '%q' "$content")" \
            "status: $(printf '%q' "$status_out")" "check: exit $RC, stdout $(printf '%q' "$OUT")" \
            "status file: $(cat "$STATE_DIR/status" 2>&1)"
    fi
done

# shellcheck disable=SC2016  # the injection attempts must stay literal
printf '%s\n' "\$(touch $MARK)" > "$STATE_DIR/client"
rm -f "$STATE_DIR/status"
: > "$LOGGER_LOG"
bl_at $((T0 + 10)) check
expect_result 'hostile client file: check exits 0' 0 ''
expect_match 'hostile client file: its content is not copied into the log' \
    'client : -\)$' "$(cat "$LOGGER_LOG")"
expect_absent 'nothing from BL_NOW or the state files was executed' "$MARK"

# ---------------------------------------------------------------------------
section 'Choice of the scheduler by install (cron forced, cron fallback, systemd)'
# ---------------------------------------------------------------------------

new_sandbox
mkdir -p "$ROOT/run/systemd/system"
run_helper BL_FORCE_CRON=1 BL_NO_SYSTEMD=1 -- install
expect_result 'BL_FORCE_CRON=1: stdout is exactly the success line' 0 \
    "BOKADOR_LINK_INSTALLED $VERSION"
expect_line 'BL_FORCE_CRON=1: cron line "*/5 * * * * root <path> check"' "$CRON_FILE" \
    "*/5 * * * * root $HELPER check"
expect_eq 'BL_FORCE_CRON=1: every other line of the cron file is a comment' '1' \
    "$(grep -cvE '^#' "$CRON_FILE" || true)"
expect_eq 'BL_FORCE_CRON=1: cron file has mode 644 and ends with a newline' '644 0a' \
    "$(stat -c '%a' "$CRON_FILE") $(tail -c 1 "$CRON_FILE" | od -An -tx1 | tr -d ' ')"
expect_eq 'BL_FORCE_CRON=1: /etc/cron.d holds the cron file and no temporary file' \
    'bokador-link' "$(list_dir "$ROOT/etc/cron.d")"
expect_absent 'BL_FORCE_CRON=1: no service unit' "$UNIT_DIR/bokador-link-check.service"
expect_absent 'BL_FORCE_CRON=1: no timer unit' "$UNIT_DIR/bokador-link-check.timer"
expect_exists 'BL_FORCE_CRON=1: state directory created' "$STATE_DIR"
expect_eq 'BL_FORCE_CRON=1: systemctl never called' '' "$(cat "$SYSTEMCTL_LOG")"
before="$(snapshot "$ROOT")"
run_helper BL_FORCE_CRON=1 BL_NO_SYSTEMD=1 -- install
expect_result 'BL_FORCE_CRON=1 again: same output' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_eq 'BL_FORCE_CRON=1 again: nothing changed (content, modes, modification times)' \
    "$before" "$(snapshot "$ROOT")"

bl install
expect_result 'cron then units: exit code 0' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_absent 'cron then units: the cron file is removed' "$CRON_FILE"
expect_exists 'cron then units: the timer unit is written' "$UNIT_DIR/bokador-link-check.timer"
run_helper BL_FORCE_CRON=1 BL_NO_SYSTEMD=1 -- install
expect_result 'units then cron: exit code 0' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_absent 'units then cron: the service unit is removed' "$UNIT_DIR/bokador-link-check.service"
expect_absent 'units then cron: the timer unit is removed' "$UNIT_DIR/bokador-link-check.timer"
expect_exists 'units then cron: the cron file is written' "$CRON_FILE"
expect_eq 'switching scheduler with BL_NO_SYSTEMD=1 never calls systemctl' '' \
    "$(cat "$SYSTEMCTL_LOG")"

new_sandbox
run_helper -- install
expect_result 'no systemd detected: exit code 0' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_line 'no systemd detected: falls back to cron' "$CRON_FILE" \
    "*/5 * * * * root $HELPER check"
expect_absent 'no systemd detected: no unit' "$UNIT_DIR/bokador-link-check.timer"
expect_eq 'no systemd detected: systemctl never called' '' "$(cat "$SYSTEMCTL_LOG")"

new_sandbox
mkdir -p "$ROOT/run/systemd/system" "$ROOT/etc/cron.d"
printf 'stale cron entry\n' > "$CRON_FILE"
run_helper -- install
expect_result 'systemd detected: exit code 0' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_line 'systemd detected: service unit written' "$UNIT_DIR/bokador-link-check.service" \
    "ExecStart=$HELPER check"
expect_file 'systemd detected: daemon-reload, then enable --now of the timer' "$SYSTEMCTL_LOG" \
    'daemon-reload
enable --now bokador-link-check.timer'
expect_absent 'systemd detected: a previous cron file is removed' "$CRON_FILE"
: > "$SYSTEMCTL_LOG"
run_helper -- uninstall
expect_result 'systemd detected: uninstall succeeds' 0 'BOKADOR_LINK_UNINSTALLED'
expect_file 'systemd detected: uninstall disables the timer, then reloads' "$SYSTEMCTL_LOG" \
    'disable --now bokador-link-check.timer
daemon-reload'
expect_absent 'systemd detected: uninstall removes the timer unit' \
    "$UNIT_DIR/bokador-link-check.timer"

new_sandbox
mkdir -p "$ROOT/run/systemd/system"
run_helper STUB_SYSTEMCTL_RC=1 -- install
expect_result 'systemctl fails: install fails (exit 1) without the success line' 1 ''

new_sandbox
mkdir -p "$ROOT/run/systemd/system"
run_helper -- install
: > "$SYSTEMCTL_LOG"
run_helper BL_FORCE_CRON=1 -- install
expect_result 'BL_FORCE_CRON=1 on a systemd host: exit code 0' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_file 'BL_FORCE_CRON=1 on a systemd host: the timer is disabled first' "$SYSTEMCTL_LOG" \
    'disable --now bokador-link-check.timer
daemon-reload'
expect_absent 'BL_FORCE_CRON=1 on a systemd host: units removed' \
    "$UNIT_DIR/bokador-link-check.timer"
expect_exists 'BL_FORCE_CRON=1 on a systemd host: cron file written' "$CRON_FILE"

# ---------------------------------------------------------------------------
section 'uninstall, with and without --purge'
# ---------------------------------------------------------------------------

new_sandbox
mkdir -p "$ROOT/run/systemd/system"
bl install
install_hook
printf 'STALE_AFTER=120\n' > "$ETC_DIR/config"
bl_at "$T0" heartbeat pc-1
printf 'other\n' > "$UNIT_DIR/other.service"
mkdir -p "$ROOT/etc/cron.d"
printf 'other\n' > "$ROOT/etc/cron.d/other"
bl uninstall --bogus
expect_result 'uninstall with an unknown option: exit code 2, nothing on stdout' 2 ''
expect_exists 'uninstall with an unknown option: state kept' "$STATE_DIR/heartbeat"
expect_exists 'uninstall with an unknown option: helper kept' "$HELPER"
bl uninstall --purge extra
expect_result 'uninstall with two arguments: exit code 2, nothing on stdout' 2 ''
expect_exists 'uninstall with two arguments: helper kept' "$HELPER"

bl uninstall
expect_result 'uninstall: stdout is exactly "BOKADOR_LINK_UNINSTALLED"' 0 'BOKADOR_LINK_UNINSTALLED'
expect_absent 'uninstall: service unit removed' "$UNIT_DIR/bokador-link-check.service"
expect_absent 'uninstall: timer unit removed' "$UNIT_DIR/bokador-link-check.timer"
expect_absent 'uninstall: /var/lib/bokador-link removed' "$STATE_DIR"
expect_file 'uninstall without --purge: config kept' "$ETC_DIR/config" 'STALE_AFTER=120'
expect_exists 'uninstall without --purge: notify hook kept' "$ETC_DIR/notify"
expect_absent 'uninstall: the helper removed itself' "$HELPER"
expect_exists 'uninstall: unrelated systemd unit untouched' "$UNIT_DIR/other.service"
expect_exists 'uninstall: unrelated cron file untouched' "$ROOT/etc/cron.d/other"
expect_eq 'uninstall: systemctl never called with BL_NO_SYSTEMD=1, even on a systemd host' '' \
    "$(cat "$SYSTEMCTL_LOG")"

new_sandbox
run_helper BL_FORCE_CRON=1 BL_NO_SYSTEMD=1 -- install
install_hook
printf 'STALE_AFTER=120\n' > "$ETC_DIR/config"
bl_at "$T0" heartbeat pc-1
bl uninstall --purge
expect_result 'uninstall --purge: stdout is exactly "BOKADOR_LINK_UNINSTALLED"' 0 \
    'BOKADOR_LINK_UNINSTALLED'
expect_absent 'uninstall --purge: cron file removed' "$CRON_FILE"
expect_absent 'uninstall --purge: /var/lib/bokador-link removed' "$STATE_DIR"
expect_absent 'uninstall --purge: /etc/bokador-link removed' "$ETC_DIR"
expect_absent 'uninstall --purge: the helper removed itself' "$HELPER"

new_sandbox
bl uninstall
expect_result 'uninstall when nothing is installed: still succeeds' 0 'BOKADOR_LINK_UNINSTALLED'
expect_absent 'uninstall when nothing is installed: the helper removed itself' "$HELPER"

new_sandbox
bl install
mkdir -p "$UNIT_DIR/timers.target.wants"
ln -s "$UNIT_DIR/bokador-link-check.timer" "$UNIT_DIR/timers.target.wants/bokador-link-check.timer"
bl uninstall
expect_result 'uninstall with an enablement link left behind: succeeds' 0 'BOKADOR_LINK_UNINSTALLED'
expect_absent 'uninstall: the timers.target.wants link is removed' \
    "$UNIT_DIR/timers.target.wants/bokador-link-check.timer"

# Run from stdin, $0 is "bash": a file of that name in the current directory
# must not be mistaken for the script.
new_sandbox
bl install
mkdir -p "$TMP/decoy"
printf 'not the helper\n' > "$TMP/decoy/bash"
RC=0
(
    cd "$TMP/decoy"
    exec env -u BL_NOW -u BL_FORCE_CRON "PATH=$RUN_PATH" "BL_ROOT=$ROOT" BL_NO_SYSTEMD=1 \
        bash -s -- uninstall
) < "$HELPER" > "$TMP/stdout" 2> "$TMP/stderr" || RC=$?
OUT="$(cat "$TMP/stdout"; printf 'x')"
OUT="${OUT%x}"
ERR="$(cat "$TMP/stderr")"
expect_result 'uninstall read from stdin: succeeds' 0 'BOKADOR_LINK_UNINSTALLED'
expect_file 'uninstall never removes a file that is not the helper' "$TMP/decoy/bash" \
    'not the helper'

# ---------------------------------------------------------------------------
section 'Refusal to run without root when BL_ROOT is empty (exit code 3)'
# ---------------------------------------------------------------------------

new_sandbox
UNPRIVILEGED=()
unprivileged_mode='none'
if [[ "$EUID" -ne 0 ]]; then
    unprivileged_mode='direct'
elif command -v setpriv >/dev/null 2>&1; then
    nobody_uid="$(id -u nobody 2>/dev/null || printf '65534')"
    nobody_gid="$(id -g nobody 2>/dev/null || printf '65534')"
    UNPRIVILEGED=(setpriv "--reuid=$nobody_uid" "--regid=$nobody_gid" --clear-groups)
    dropped="$("${UNPRIVILEGED[@]}" id -u 2>/dev/null || true)"
    if [[ -n "$dropped" && "$dropped" != 0 ]]; then
        unprivileged_mode='setpriv'
    fi
fi

# The helper is fed through stdin so that the unprivileged user does not need
# to reach the temporary directory. BL_ROOT is unset: every command but
# "version" must stop before doing anything.
run_unprivileged() {
    RC=0
    (
        cd /
        exec env -u BL_ROOT -u BL_NOW -u BL_NO_SYSTEMD -u BL_FORCE_CRON "PATH=$BASE_PATH" \
            ${UNPRIVILEGED[@]+"${UNPRIVILEGED[@]}"} bash -s -- "$@"
    ) < "$HELPER" > "$TMP/stdout" 2> "$TMP/stderr" || RC=$?
    OUT="$(cat "$TMP/stdout"; printf 'x')"
    OUT="${OUT%x}"
    ERR="$(cat "$TMP/stderr")"
}

if [[ "$unprivileged_mode" == 'none' ]]; then
    skip 'cannot drop privileges here (running as root without a usable setpriv)'
else
    for command in status check heartbeat install uninstall 'uninstall --purge' 'probe-port 1'; do
        # shellcheck disable=SC2086  # the command and its argument are two words on purpose
        run_unprivileged $command
        expect_result "non-root, BL_ROOT empty: \"$command\" refused with exit code 3" 3 ''
    done
    run_unprivileged version
    expect_result 'non-root, BL_ROOT empty: "version" still works' 0 "bokador-link $VERSION"
    run_unprivileged frobnicate
    expect_result 'non-root, BL_ROOT empty: an unknown command is refused too (only "version" is exempt)' 3 ''
    run_unprivileged
    expect_result 'non-root, BL_ROOT empty: no command is refused too' 3 ''
    run_unprivileged version extra
    expect_result 'non-root, BL_ROOT empty: "version" with an extra argument is a usage error' 2 ''
fi

# ---------------------------------------------------------------------------
section 'Minimal PATH: no timeout, no logger, no flock, no systemctl'
# ---------------------------------------------------------------------------

make_minimal_path() {
    # make_minimal_path <directory>: only the tools the helper cannot do without.
    local tool
    mkdir -p "$1"
    for tool in bash date mkdir mktemp mv rm chmod readlink sleep; do
        ln -s "$(real_tool "$tool")" "$1/$tool"
    done
}

new_sandbox
make_minimal_path "$TMP/min-bin"
RUN_PATH="$TMP/min-bin"
run_helper -- install
expect_result 'minimal PATH: install falls back to cron' 0 "BOKADOR_LINK_INSTALLED $VERSION"
expect_line 'minimal PATH: cron line written' "$CRON_FILE" "*/5 * * * * root $HELPER check"
install_hook
bl_at "$T0" heartbeat pc-1
expect_result 'minimal PATH: heartbeat' 0 "BOKADOR_LINK_OK $T0 up"
expect_match 'minimal PATH: without logger the transition goes to stderr' \
    'unknown -> up' "$ERR"
bl_at $((T0 + 601)) check
expect_result 'minimal PATH: check' 0 ''
bl_at $((T0 + 601)) status
expect_result 'minimal PATH: status' 0 \
    "status=down heartbeat_age=601 since=$((T0 + 601)) stale_after=600 version=$VERSION"
expect_file 'minimal PATH: notify hook called without the timeout command' "$NOTIFY_LOG" '2|up|0
2|down|601'
if start_listener; then
    bl probe-port "$LISTENER_PORT"
    expect_result 'minimal PATH: probe-port OPEN without the timeout command' 0 \
        "PORT $LISTENER_PORT OPEN"
    stop_listener
    bl probe-port "$LISTENER_PORT"
    expect_result 'minimal PATH: probe-port CLOSED without the timeout command' 1 \
        "PORT $LISTENER_PORT CLOSED"
else
    fail 'minimal PATH: probe-port (python3 is needed to open a local listener)'
fi

# Without "timeout" the helper polls with "sleep". A stub "sleep" returns at
# once and records what was asked: the 30 second limit is checked without
# waiting 30 seconds. The hook itself sleeps for real.
rm "$TMP/min-bin/sleep"
cat > "$TMP/min-bin/sleep" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${1-}" >> $(printf '%q' "$SLEEP_LOG")
EOF
chmod 755 "$TMP/min-bin/sleep"
install_hook "printf '%s\n' \"\$\$\" > $(printf '%q' "$TMP/hook.pid")
exec $(printf '%q' "$REAL_SLEEP") 300"
: > "$SLEEP_LOG"
rm -f "$TMP/hook.pid"
started=$SECONDS
bl_at $((T0 + 700)) heartbeat pc-1
elapsed=$((SECONDS - started))
expect_result 'minimal PATH, hanging hook: heartbeat still answers, exit code 0' 0 \
    "BOKADOR_LINK_OK $((T0 + 700)) up"
slept="$(awk '{ total += $1 } END { printf "%d", total + 0.5 }' "$SLEEP_LOG")"
if (( slept >= 30 && slept <= 32 )); then
    pass 'minimal PATH, hanging hook: interrupted after 30 seconds of polling'
else
    fail 'minimal PATH, hanging hook: interrupted after 30 seconds of polling' \
        "polled for $slept s"
fi
if (( elapsed < 20 )); then
    pass 'minimal PATH, hanging hook: the test itself did not wait (stubbed sleep)'
else
    fail 'minimal PATH, hanging hook: the test itself did not wait (stubbed sleep)' \
        "took $elapsed s"
fi
hook_pid="$(cat "$TMP/hook.pid" 2>/dev/null || true)"
if [[ "$hook_pid" =~ ^[0-9]+$ ]] && wait_for 5 test ! -d "/proc/$hook_pid"; then
    pass 'minimal PATH, hanging hook: the hook process was killed'
else
    fail 'minimal PATH, hanging hook: the hook process was killed' "pid: $hook_pid"
    if [[ "$hook_pid" =~ ^[0-9]+$ ]]; then
        kill -KILL "$hook_pid" 2>/dev/null || true
    fi
fi
expect_match 'minimal PATH, hanging hook: the interruption is reported on stderr' \
    'notify interrompu' "$ERR"
RUN_PATH="$TMP/min-bin"
bl uninstall --purge
expect_result 'minimal PATH: uninstall --purge' 0 'BOKADOR_LINK_UNINSTALLED'
expect_absent 'minimal PATH: the helper removed itself' "$HELPER"
RUN_PATH="$STUB_BIN:$BASE_PATH"

# ---------------------------------------------------------------------------
section 'Nothing outside the temporary directory was touched'
# ---------------------------------------------------------------------------

expect_eq 'the repository copy of vps/bokador-link is intact' \
    "$SOURCE_SUM_BEFORE" "$(cksum < "$SOURCE_HELPER")"
expect_eq 'the real paths of the helper (/etc, /var/lib, /usr/local/sbin) are as before' \
    "$REAL_BEFORE" "$(real_paths_snapshot)"
leftovers="$(find "$TMP" -name '.bokador-link.*' | sort)"
expect_eq 'no temporary file of an atomic write is left anywhere' '' "$leftovers"

printf '\ntest-vps-unit: %d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
if (( FAILED > 0 )); then
    exit 1
fi
exit 0
