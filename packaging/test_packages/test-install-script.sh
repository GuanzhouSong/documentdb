#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Deterministic behavior tests for packaging/install.sh. The installer exposes
# a dry-run-only test mode so these checks can exercise every supported distro
# and architecture without changing the host or requiring nested VMs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INSTALLER="${REPO_ROOT}/packaging/install.sh"

PASS=0
FAIL=0
TEMP_DIRS=()
LAST_OUTPUT=""
NEW_ROOT=""

cleanup() {
    if (( ${#TEMP_DIRS[@]} > 0 )); then
        rm -rf "${TEMP_DIRS[@]}"
    fi
}
trap cleanup EXIT

pass() {
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

new_root() {
    local id="$1" version="$2"
    NEW_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/documentdb-installer-test.XXXXXX")"
    TEMP_DIRS+=("${NEW_ROOT}")
    mkdir -p \
        "${NEW_ROOT}/etc/apt/sources.list.d" \
        "${NEW_ROOT}/etc/yum.repos.d" \
        "${NEW_ROOT}/run/systemd/system"
    printf 'ID=%s\nVERSION_ID="%s"\n' "${id}" "${version}" > "${NEW_ROOT}/etc/os-release"
}

run_installer() {
    local root="$1" arch="$2" native_arch="$3"
    shift 3

    env \
        DOCUMENTDB_INSTALLER_TESTING=true \
        DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
        DOCUMENTDB_INSTALLER_TEST_UNAME_M="${arch}" \
        DOCUMENTDB_INSTALLER_TEST_NATIVE_ARCH="${native_arch}" \
        sh "${INSTALLER}" --dry-run "$@" 2>&1
}

expect_success() {
    local description="$1"
    shift
    if LAST_OUTPUT="$("$@" 2>&1)"; then
        pass "${description}"
    else
        fail "${description}"
        printf '%s\n' "${LAST_OUTPUT}" >&2
        return 1
    fi
}

expect_failure() {
    local description="$1" expected="$2"
    shift 2
    local output
    if output="$("$@" 2>&1)"; then
        fail "${description} (unexpected success)"
        printf '%s\n' "${output}" >&2
        return 1
    fi
    if grep -Fq -- "${expected}" <<< "${output}"; then
        pass "${description}"
    else
        fail "${description} (missing: ${expected})"
        printf '%s\n' "${output}" >&2
        return 1
    fi
}

assert_contains() {
    local description="$1" output="$2" expected="$3"
    if grep -Fq -- "${expected}" <<< "${output}"; then
        pass "${description}"
    else
        fail "${description} (missing: ${expected})"
        return 1
    fi
}

printf '=== packaging/install.sh behavior tests ===\n'

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_success "Ubuntu amd64 dry-run succeeds" \
    run_installer "${root}" x86_64 amd64
output="${LAST_OUTPUT}"
assert_contains "Ubuntu selects APT" "${output}" "Package manager:  apt"
assert_contains "Ubuntu selects amd64 repository" "${output}" "deb [arch=amd64"
assert_contains "Ubuntu defaults to PG18 package" "${output}" "apt-get install -y documentdb-18"
assert_contains "Ubuntu plans managed setup" "${output}" "--use-new-postgres-instance"
if [ ! -e "${root}/etc/apt/sources.list.d/documentdb.list" ]; then
    pass "Ubuntu dry-run writes no repository file"
else
    fail "Ubuntu dry-run wrote a repository file"
fi

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_success "Ubuntu arm64 PG17 dry-run succeeds" \
    run_installer "${root}" aarch64 arm64 --pg-major 17
output="${LAST_OUTPUT}"
assert_contains "Ubuntu selects arm64 repository" "${output}" "deb [arch=arm64"
assert_contains "Ubuntu selects PG17 package" "${output}" "apt-get install -y documentdb-17"

for distro in rocky almalinux; do
    new_root "${distro}" 9.6
    root="${NEW_ROOT}"
    expect_success "${distro} x86_64 dry-run succeeds" \
        run_installer "${root}" x86_64 x86_64 --pg-major 18
    output="${LAST_OUTPUT}"
    assert_contains "${distro} enables CRB" "${output}" "dnf config-manager --set-enabled crb"
    assert_contains "${distro} uses EL9 x86_64 PGDG" "${output}" "EL-9-x86_64"
    assert_contains "${distro} selects PG18 package" "${output}" "dnf install -y documentdb-18"
    if grep -Eq -- 'dnf install -y .*curl' <<< "${output}"; then
        fail "${distro} must not replace curl-minimal"
    else
        pass "${distro} preserves curl-minimal"
    fi
done

new_root centos 9
root="${NEW_ROOT}"
expect_success "CentOS Stream aarch64 dry-run succeeds" \
    run_installer "${root}" arm64 aarch64 --pg-major 17
output="${LAST_OUTPUT}"
assert_contains "CentOS Stream enables CRB" "${output}" "dnf config-manager --set-enabled crb"
assert_contains "CentOS Stream installs EPEL Next" "${output}" "dnf install -y epel-next-release"
assert_contains "CentOS Stream uses EL9 aarch64 PGDG" "${output}" "EL-9-aarch64"

new_root rhel 9.4
root="${NEW_ROOT}"
mkdir -p "${root}/etc/pki/consumer"
printf 'registered\n' > "${root}/etc/pki/consumer/cert.pem"
expect_success "RHEL aarch64 dry-run succeeds" \
    run_installer "${root}" aarch64 aarch64 --pg-major 18
output="${LAST_OUTPUT}"
assert_contains "RHEL enables CodeReady Builder" "${output}" \
    "subscription-manager repos --enable codeready-builder-for-rhel-9-aarch64-rpms"
assert_contains "RHEL enables repository metadata checks" "${output}" "repo_gpgcheck=1"
assert_contains "RHEL pre-accepts DNF metadata key import" "${output}" "dnf -y makecache --refresh"

new_root rhel 9.4
root="${NEW_ROOT}"
output="$(
    env \
        DOCUMENTDB_INSTALLER_TESTING=true \
        DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
        DOCUMENTDB_INSTALLER_TEST_RHEL_REPOLIST='
codeready-builder-for-rhel-9-x86_64-rhui-debug-rpms disabled
codeready-builder-for-rhel-9-x86_64-rhui-rpms disabled
codeready-builder-for-rhel-9-x86_64-rhui-source-rpms disabled' \
        sh "${INSTALLER}" --dry-run 2>&1
)"
assert_contains "RHEL RHUI host enables discovered CodeReady Builder repo" "${output}" \
    "dnf config-manager --set-enabled codeready-builder-for-rhel-9-x86_64-rhui-rpms"
if grep -Fq -- "rhui-debug-rpms" <<< "${output}" &&
   grep -Fq -- "config-manager --set-enabled codeready-builder-for-rhel-9-x86_64-rhui-debug-rpms" <<< "${output}"; then
    fail "RHEL RHUI discovery selected the debug repository"
else
    pass "RHEL RHUI discovery ignores debug/source repositories"
fi

for arch_pair in "x86_64:x86_64" "aarch64:aarch64"; do
    kernel_arch="${arch_pair%%:*}"
    native_arch="${arch_pair##*:}"
    new_root rhel 9.4
    root="${NEW_ROOT}"
    output="$(
        env \
            DOCUMENTDB_INSTALLER_TESTING=true \
            DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
            DOCUMENTDB_INSTALLER_TEST_UNAME_M="${kernel_arch}" \
            DOCUMENTDB_INSTALLER_TEST_NATIVE_ARCH="${native_arch}" \
            DOCUMENTDB_INSTALLER_TEST_RHEL_REPOLIST='
codeready-builder-for-rhel-9-rhui-debug-rpms disabled
codeready-builder-for-rhel-9-rhui-rpms disabled
codeready-builder-for-rhel-9-rhui-source-rpms disabled' \
            sh "${INSTALLER}" --dry-run 2>&1
    )"
    assert_contains "AWS RHEL ${kernel_arch} selects arch-less binary CRB repo" "${output}" \
        "dnf config-manager --set-enabled codeready-builder-for-rhel-9-rhui-rpms"
done

assert_contains "EPEL bootstrap key fingerprint is pinned" "${output}" \
    "FF8AD1344597106ECE813B918A3872BF3228467C"
assert_contains "PGDG RPM bootstrap key fingerprint is pinned" "${output}" \
    "D4BF08AE67A0B4C7A1DBCCD240BCA2B408B40D20"
assert_contains "EPEL bootstrap RPM requires signature verification" "${output}" \
    "dnf --setopt=localpkg_gpgcheck=1 install -y /tmp/epel-release-latest-9.noarch.rpm"
assert_contains "PGDG bootstrap RPM requires signature verification" "${output}" \
    "dnf --setopt=localpkg_gpgcheck=1 install -y /tmp/pgdg-redhat-repo-latest.noarch.rpm"

new_root ubuntu 24.04
root="${NEW_ROOT}"
printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main' \
    > "${root}/etc/apt/sources.list.d/pgdg.list"
printf '%s\n' \
    'deb [arch=amd64 signed-by=/usr/share/keyrings/documentdb-archive-keyring.gpg] https://documentdb.io/deb stable ubuntu24' \
    > "${root}/etc/apt/sources.list.d/documentdb.list"
expect_success "Exact existing APT repositories are reused" \
    run_installer "${root}" x86_64 amd64
output="${LAST_OUTPUT}"
assert_contains "Existing PGDG source is reused" "${output}" \
    "Would verify or install ${root}/usr/share/keyrings/postgresql.gpg"
assert_contains "Existing DocumentDB source is reused" "${output}" \
    "Reusing the existing DocumentDB APT repository configuration."

new_root rocky 9.6
root="${NEW_ROOT}"
cat > "${root}/etc/yum.repos.d/pgdg-redhat-all.repo" <<'REPO'
[pgdg18]
name=PostgreSQL 18 for RHEL / Rocky Linux $releasever - $basearch
baseurl=https://download.postgresql.org/pub/repos/yum/18/redhat/rhel-$releasever-$basearch
enabled=1
gpgcheck=1
REPO
output="$(run_installer "${root}" x86_64 x86_64)"
assert_contains "Canonical PGDG RPM repository is reused" "${output}" \
    "Reusing the existing PGDG DNF repository configuration."

new_root ubuntu 24.04
root="${NEW_ROOT}"
printf '%s\n' \
    'deb https://apt.postgresql.org/pub/repos/apt jammy-pgdg main' \
    > "${root}/etc/apt/sources.list.d/pgdg.list"
expect_failure "Conflicting PGDG repository is rejected" \
    "Conflicting PGDG repository configuration" \
    run_installer "${root}" x86_64 amd64

new_root ubuntu 22.04
root="${NEW_ROOT}"
expect_failure "Ubuntu 22.04 is rejected" "Only Ubuntu 24.04 LTS is supported" \
    run_installer "${root}" x86_64 amd64

new_root debian 12
root="${NEW_ROOT}"
expect_failure "Debian is rejected" "Unsupported Linux distribution 'debian'" \
    run_installer "${root}" x86_64 amd64

new_root rocky 8.10
root="${NEW_ROOT}"
expect_failure "Rocky Linux 8 is rejected" "Only Rocky Linux 9 is supported" \
    run_installer "${root}" x86_64 x86_64

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "Unsupported architecture is rejected" \
    "Supported architectures are x86_64 and arm64" \
    run_installer "${root}" ppc64le ppc64le

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "Kernel/package architecture mismatch is rejected" \
    "does not match dpkg architecture" \
    run_installer "${root}" x86_64 arm64

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "WSL is rejected" "Windows Subsystem for Linux is not supported" \
    env \
        DOCUMENTDB_INSTALLER_TESTING=true \
        DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
        DOCUMENTDB_INSTALLER_TEST_KERNEL_RELEASE="5.15.0-microsoft-standard-WSL2" \
        sh "${INSTALLER}" --dry-run

new_root ubuntu 24.04
root="${NEW_ROOT}"
rm -rf "${root}/run/systemd/system"
expect_failure "Host without running systemd is rejected" \
    "A running systemd host is required" \
    run_installer "${root}" x86_64 amd64

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "Container environment is rejected" \
    "Container environment 'docker' is not supported" \
    env \
        DOCUMENTDB_INSTALLER_TESTING=true \
        DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
        DOCUMENTDB_INSTALLER_TEST_CONTAINER_VIRT=docker \
        sh "${INSTALLER}" --dry-run

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "Existing packages are rejected" \
    "DocumentDB packages are already installed" \
    env \
        DOCUMENTDB_INSTALLER_TESTING=true \
        DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
        DOCUMENTDB_INSTALLER_TEST_EXISTING_PACKAGES=documentdb-18 \
        sh "${INSTALLER}" --dry-run

new_root ubuntu 24.04
root="${NEW_ROOT}"
mkdir -p "${root}/var/lib/documentdb-local/18/data"
expect_failure "Residual data is rejected" "Residual DocumentDB state exists" \
    run_installer "${root}" x86_64 amd64

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "PostgreSQL 16 is rejected" "--pg-major must be 17 or 18" \
    run_installer "${root}" x86_64 amd64 --pg-major 16

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "Privileged listen port is rejected" \
    "--listen-port must be from 1024 through 65535" \
    run_installer "${root}" x86_64 amd64 --listen-port 443

new_root ubuntu 24.04
root="${NEW_ROOT}"
output="$(run_installer "${root}" x86_64 amd64 --listen-port 1024)"
assert_contains "Lowest supported listen port is accepted" "${output}" "--listen-port 1024"

new_root ubuntu 24.04
root="${NEW_ROOT}"
output="$(run_installer "${root}" x86_64 amd64 --listen-port 65535)"
assert_contains "Highest supported listen port is accepted" "${output}" "--listen-port 65535"

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "Listen port above 65535 is rejected" \
    "--listen-port must be from 1024 through 65535" \
    run_installer "${root}" x86_64 amd64 --listen-port 65536

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "Oversized listen port is rejected without overflow" \
    "--listen-port must be from 1024 through 65535" \
    run_installer "${root}" x86_64 amd64 --listen-port 18446744073709561876

new_root ubuntu 24.04
root="${NEW_ROOT}"
expect_failure "Missing required command is rejected" \
    "Required command 'systemctl' is not available" \
    env \
        DOCUMENTDB_INSTALLER_TESTING=true \
        DOCUMENTDB_INSTALLER_TEST_ROOT="${root}" \
        DOCUMENTDB_INSTALLER_TEST_MISSING_COMMAND=systemctl \
        sh "${INSTALLER}" --dry-run

expect_failure "--yes requires a password file outside dry-run" \
    "--yes requires --admin-password-file" \
    env DOCUMENTDB_INSTALLER_TESTING=true sh "${INSTALLER}" --yes

printf '\nResults: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
