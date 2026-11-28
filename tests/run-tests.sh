#!/usr/bin/env bash
# Runs every test that can run on Linux (docs/DESIGN.md, section 6), in order:
#
#   1. shellcheck on vps/bokador-link and tests/*.sh
#   2. tests/test-vps-unit.sh      unit tests of the VPS helper
#   3. tests/test-integration.sh   end-to-end test through a throwaway sshd
#   4. tests/ps-static-check.py    static checks of the PowerShell scripts, run
#                                  with the interpreter named by PS_CHECK_PYTHON
#                                  (default: python3)
#
# Every stage runs even when an earlier one failed. Each stage ends with one
# "PASS: <stage>" or "FAIL: <stage>" line; the exit code is 1 if any stage
# failed, 0 otherwise.
#
# The PowerShell scripts are not executed here (no PowerShell on Linux): see
# the "Limite connue" paragraph of the design.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

SUMMARY=()
STAGES=0
FAILED=0
STAGE_NAME=''

begin_stage() {
    STAGE_NAME="$1"
    STAGES=$((STAGES + 1))
    printf '\n===== Stage %d: %s\n' "$STAGES" "$STAGE_NAME"
}

# end_stage <exit code of the stage>
end_stage() {
    if (( $1 == 0 )); then
        printf 'PASS: %s\n' "$STAGE_NAME"
        SUMMARY+=("PASS  $STAGE_NAME")
    else
        printf 'FAIL: %s (exit code %d)\n' "$STAGE_NAME" "$1"
        SUMMARY+=("FAIL  $STAGE_NAME")
        FAILED=$((FAILED + 1))
    fi
}

stage_shellcheck() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        printf 'shellcheck is not installed.\n'
        return 127
    fi
    if [[ ! -f vps/bokador-link ]]; then
        printf 'vps/bokador-link does not exist.\n'
        return 1
    fi
    printf 'shellcheck vps/bokador-link tests/*.sh\n'
    shellcheck vps/bokador-link tests/*.sh
}

stage_unit() {
    bash tests/test-vps-unit.sh
}

stage_integration() {
    bash tests/test-integration.sh
}

stage_powershell_static() {
    local python="${PS_CHECK_PYTHON:-python3}" first=''
    if [[ -d windows ]]; then
        first="$(find windows -type f -name '*.ps1' -print -quit)"
    fi
    if [[ -z "$first" ]]; then
        printf 'windows/ contains no .ps1 file yet: there is nothing to check.\n'
        printf 'This stage fails until the Windows scripts exist; the other stages are not affected.\n'
        return 1
    fi
    if ! command -v "$python" >/dev/null 2>&1; then
        printf 'Python interpreter not found: %s (set PS_CHECK_PYTHON).\n' "$python"
        return 127
    fi
    printf '%s tests/ps-static-check.py\n' "$python"
    "$python" tests/ps-static-check.py
}

begin_stage 'shellcheck (vps/bokador-link, tests/*.sh)'
rc=0
stage_shellcheck || rc=$?
end_stage "$rc"

begin_stage 'unit tests of the VPS helper (tests/test-vps-unit.sh)'
rc=0
stage_unit || rc=$?
end_stage "$rc"

begin_stage 'integration test with a local sshd (tests/test-integration.sh)'
rc=0
stage_integration || rc=$?
end_stage "$rc"

begin_stage 'PowerShell static check (tests/ps-static-check.py)'
rc=0
stage_powershell_static || rc=$?
end_stage "$rc"

printf '\n===== Summary\n'
printf '%s\n' "${SUMMARY[@]}"
if (( FAILED > 0 )); then
    printf 'RESULT: FAIL (%d of %d stages failed)\n' "$FAILED" "$STAGES"
    exit 1
fi
printf 'RESULT: PASS (%d stages)\n' "$STAGES"
exit 0
