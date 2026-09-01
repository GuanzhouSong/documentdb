#!/bin/sh
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Install the current stable DocumentDB stand-alone package from the hosted
# package repository, then provision a new private PostgreSQL-backed instance.
#
# Supported targets:
#   - Ubuntu 24.04 LTS on amd64 or arm64
#   - RHEL, Rocky Linux, AlmaLinux, or CentOS Stream 9 on x86_64 or aarch64
#
# This is intentionally a new-install bootstrap, not an upgrade tool.

set -eu

umask 077

PROGRAM="${0##*/}"
DEFAULT_PG_MAJOR="18"
DEFAULT_ADMIN_USER="admin"
DEFAULT_LISTEN_PORT="10260"
PGDG_APT_KEY_FINGERPRINT="B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"
EPEL_KEY_FINGERPRINT="FF8AD1344597106ECE813B918A3872BF3228467C"
PGDG_RPM_KEY_FINGERPRINT="D4BF08AE67A0B4C7A1DBCCD240BCA2B408B40D20"
DOCUMENTDB_KEY_FINGERPRINT="1F748DA911519E749521438252101F285C52B856"
PGDG_APT_KEY_URL="https://www.postgresql.org/media/keys/ACCC4CF8.asc"
EPEL_KEY_URL="https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9"
PGDG_RPM_KEY_URL="https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-RHEL"
DOCUMENTDB_KEY_URL="https://documentdb.io/documentdb-archive-keyring.gpg"
EPEL_RELEASE_URL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"

PG_MAJOR="${DEFAULT_PG_MAJOR}"
ADMIN_USER="${DEFAULT_ADMIN_USER}"
ADMIN_PASSWORD_FILE=""
LISTEN_PORT="${DEFAULT_LISTEN_PORT}"
ASSUME_YES="false"
DRY_RUN="false"

TESTING="${DOCUMENTDB_INSTALLER_TESTING:-false}"
SYSTEM_ROOT=""
TMP_DIR=""
TTY_STATE=""
TTY_PATH="/dev/tty"
IS_ROOT="false"
SUDO="sudo"

OS_ID=""
OS_VERSION_ID=""
OS_DISPLAY=""
PACKAGE_FAMILY=""
DISTRO_KIND=""
RAW_ARCH=""
APT_ARCH=""
RPM_ARCH=""
PGDG_REPO_PRESENT="false"
PGDG_MANAGED_SOURCE="false"
DOCUMENTDB_REPO_PRESENT="false"
RHEL_CRB_METHOD=""
RHEL_CRB_REPO=""

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install the current stable DocumentDB release and provision a new private
DocumentDB instance.

Supported hosts:
  Ubuntu 24.04 LTS                 amd64, arm64
  RHEL/Rocky/Alma/CentOS Stream 9 x86_64, aarch64

Options:
  --pg-major <17|18>          PostgreSQL major (default: 18)
  --admin-user <USER>         Initial DocumentDB administrator (default: admin)
  --admin-password-file <FILE>
                              Read the initial administrator password from FILE.
                              Required with --yes.
  --listen-port <PORT>        Gateway port, 1024-65535 (default: 10260)
  --yes                       Do not ask for confirmation. Requires
                              --admin-password-file and non-interactive sudo.
  --dry-run                   Detect the host and print the planned operations
                              without changing files, repositories, or packages.
  -h, --help                  Show this help.

Interactive installation from a repository checkout:
  ./packaging/install.sh

Non-interactive installation from a repository checkout:
  ./packaging/install.sh --yes \
    --admin-password-file /secure/path/password

This installer is for clean hosts. It refuses to upgrade, replace, or resume an
existing DocumentDB installation and never removes existing data.
EOF
}

log() {
    printf '[documentdb-install] %s\n' "$*"
}

warn() {
    printf '[documentdb-install] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[documentdb-install] ERROR: %s\n' "$*" >&2
    exit 1
}

restore_tty() {
    if [ -n "${TTY_STATE}" ] && [ -r "${TTY_PATH}" ]; then
        stty "${TTY_STATE}" < "${TTY_PATH}" 2>/dev/null || true
        TTY_STATE=""
        printf '\n' > "${TTY_PATH}" 2>/dev/null || true
    fi
}

cleanup() {
    restore_tty
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

system_path() {
    printf '%s%s\n' "${SYSTEM_ROOT}" "$1"
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

strip_outer_quotes() {
    value="$1"
    case "${value}" in
        \"*\")
            value=${value#\"}
            value=${value%\"}
            ;;
        \'*\')
            value=${value#\'}
            value=${value%\'}
            ;;
    esac
    printf '%s\n' "${value}"
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pg-major)
                [ "$#" -ge 2 ] || die "--pg-major requires a value."
                PG_MAJOR="$2"
                shift 2
                ;;
            --admin-user)
                [ "$#" -ge 2 ] || die "--admin-user requires a value."
                ADMIN_USER="$2"
                shift 2
                ;;
            --admin-password-file)
                [ "$#" -ge 2 ] || die "--admin-password-file requires a value."
                ADMIN_PASSWORD_FILE="$2"
                shift 2
                ;;
            --listen-port)
                [ "$#" -ge 2 ] || die "--listen-port requires a value."
                LISTEN_PORT="$2"
                shift 2
                ;;
            --yes)
                ASSUME_YES="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                [ "$#" -eq 0 ] || die "Unexpected positional arguments: $*"
                ;;
            *)
                die "Unknown option: $1. Run ${PROGRAM} --help for usage."
                ;;
        esac
    done
}

validate_arguments() {
    case "${PG_MAJOR}" in
        17|18) ;;
        *) die "--pg-major must be 17 or 18." ;;
    esac

    [ -n "${ADMIN_USER}" ] || die "--admin-user cannot be empty."
    case "${ADMIN_USER}" in
        *'
'*) die "--admin-user cannot contain a newline." ;;
    esac

    case "${LISTEN_PORT}" in
        ''|*[!0-9]*) die "--listen-port must be a number from 1024 through 65535." ;;
    esac
    [ "${#LISTEN_PORT}" -le 5 ] ||
        die "--listen-port must be from 1024 through 65535."
    if [ "${LISTEN_PORT}" -lt 1024 ] || [ "${LISTEN_PORT}" -gt 65535 ]; then
        die "--listen-port must be from 1024 through 65535."
    fi

    if [ "${DRY_RUN}" = "false" ] && [ "${ASSUME_YES}" = "true" ] &&
       [ -z "${ADMIN_PASSWORD_FILE}" ]; then
        die "--yes requires --admin-password-file."
    fi

    if [ "${DRY_RUN}" = "false" ] && [ -n "${ADMIN_PASSWORD_FILE}" ]; then
        [ -f "${ADMIN_PASSWORD_FILE}" ] ||
            die "Password file '${ADMIN_PASSWORD_FILE}' is not a regular file."
        [ -r "${ADMIN_PASSWORD_FILE}" ] ||
            die "Password file '${ADMIN_PASSWORD_FILE}' is not readable."
    fi
}

initialize_environment() {
    case "${TESTING}" in
        true|false) ;;
        *) die "DOCUMENTDB_INSTALLER_TESTING must be true or false." ;;
    esac

    if [ "${TESTING}" = "true" ]; then
        [ "${DRY_RUN}" = "true" ] ||
            die "Internal installer test mode is restricted to --dry-run."
        SYSTEM_ROOT="${DOCUMENTDB_INSTALLER_TEST_ROOT:-}"
        case "${SYSTEM_ROOT}" in
            /*|'') ;;
            *) die "DOCUMENTDB_INSTALLER_TEST_ROOT must be an absolute path." ;;
        esac
        return
    fi

    PATH="/usr/sbin:/usr/bin:/sbin:/bin"
    export PATH
    unset CDPATH ENV BASH_ENV APT_CONFIG DNF0_CONFIG_FILE GNUPGHOME GPG_AGENT_INFO || true
    LC_ALL=C
    export LC_ALL
}

command_exists() {
    if [ "${TESTING}" = "true" ]; then
        missing="${DOCUMENTDB_INSTALLER_TEST_MISSING_COMMAND:-}"
        [ "$1" != "${missing}" ]
        return
    fi
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" || die "Required command '$1' is not available."
}

get_uname_s() {
    if [ "${TESTING}" = "true" ]; then
        printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_UNAME_S:-Linux}"
    else
        uname -s
    fi
}

get_uname_m() {
    if [ "${TESTING}" = "true" ]; then
        printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_UNAME_M:-x86_64}"
    else
        uname -m
    fi
}

get_kernel_release() {
    if [ "${TESTING}" = "true" ]; then
        printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_KERNEL_RELEASE:-generic-linux}"
        return
    fi
    kernel_release_file="$(system_path /proc/sys/kernel/osrelease)"
    if [ -r "${kernel_release_file}" ]; then
        cat "${kernel_release_file}"
    else
        uname -r
    fi
}

get_systemd_state() {
    if [ "${TESTING}" = "true" ]; then
        printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_SYSTEMD_STATE:-running}"
    else
        systemctl is-system-running 2>/dev/null || true
    fi
}

get_container_virtualization() {
    if [ "${TESTING}" = "true" ]; then
        printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_CONTAINER_VIRT:-none}"
        return
    fi
    if command_exists systemd-detect-virt; then
        systemd-detect-virt --container 2>/dev/null || true
    else
        printf 'none\n'
    fi
}

get_chroot_virtualization() {
    if [ "${TESTING}" = "true" ]; then
        printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_CHROOT_VIRT:-none}"
        return
    fi
    if command_exists systemd-detect-virt; then
        systemd-detect-virt --chroot 2>/dev/null || true
    else
        printf 'none\n'
    fi
}

get_native_package_arch() {
    if [ "${TESTING}" = "true" ]; then
        if [ "${PACKAGE_FAMILY}" = "apt" ]; then
            printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_NATIVE_ARCH:-${APT_ARCH}}"
        else
            printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_NATIVE_ARCH:-${RPM_ARCH}}"
        fi
        return
    fi

    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        dpkg --print-architecture
    else
        rpm --eval '%{_arch}'
    fi
}

read_os_release() {
    os_release_file="$(system_path /etc/os-release)"
    [ -r "${os_release_file}" ] || die "Cannot read ${os_release_file}."

    OS_ID=""
    OS_VERSION_ID=""
    while IFS='=' read -r key value; do
        case "${key}" in
            ID)
                OS_ID="$(strip_outer_quotes "${value}")"
                ;;
            VERSION_ID)
                OS_VERSION_ID="$(strip_outer_quotes "${value}")"
                ;;
        esac
    done < "${os_release_file}"

    OS_ID="$(lowercase "${OS_ID}")"
    case "${OS_ID}" in
        ''|*[!a-z0-9._-]*) die "Invalid ID in ${os_release_file}." ;;
    esac
    case "${OS_VERSION_ID}" in
        ''|*[!0-9.]*) die "Invalid VERSION_ID in ${os_release_file}." ;;
    esac
}

detect_platform() {
    os_name="$(get_uname_s)"
    [ "${os_name}" = "Linux" ] ||
        die "Unsupported operating system '${os_name}'. This installer supports Linux only."

    kernel_release="$(lowercase "$(get_kernel_release)")"
    case "${kernel_release}" in
        *microsoft*|*wsl*)
            die "Windows Subsystem for Linux is not supported by this installer."
            ;;
    esac

    read_os_release

    case "${OS_ID}" in
        ubuntu)
            [ "${OS_VERSION_ID}" = "24.04" ] ||
                die "Unsupported Ubuntu release ${OS_VERSION_ID}. Only Ubuntu 24.04 LTS is supported."
            PACKAGE_FAMILY="apt"
            DISTRO_KIND="ubuntu"
            OS_DISPLAY="Ubuntu 24.04 LTS"
            ;;
        rhel)
            case "${OS_VERSION_ID}" in
                9|9.*) ;;
                *) die "Unsupported RHEL release ${OS_VERSION_ID}. Only RHEL 9 is supported." ;;
            esac
            PACKAGE_FAMILY="rpm"
            DISTRO_KIND="rhel"
            OS_DISPLAY="Red Hat Enterprise Linux 9"
            ;;
        rocky)
            case "${OS_VERSION_ID}" in
                9|9.*) ;;
                *) die "Unsupported Rocky Linux release ${OS_VERSION_ID}. Only Rocky Linux 9 is supported." ;;
            esac
            PACKAGE_FAMILY="rpm"
            DISTRO_KIND="rocky"
            OS_DISPLAY="Rocky Linux 9"
            ;;
        almalinux)
            case "${OS_VERSION_ID}" in
                9|9.*) ;;
                *) die "Unsupported AlmaLinux release ${OS_VERSION_ID}. Only AlmaLinux 9 is supported." ;;
            esac
            PACKAGE_FAMILY="rpm"
            DISTRO_KIND="almalinux"
            OS_DISPLAY="AlmaLinux 9"
            ;;
        centos)
            case "${OS_VERSION_ID}" in
                9|9.*) ;;
                *) die "Unsupported CentOS release ${OS_VERSION_ID}. Only CentOS Stream 9 is supported." ;;
            esac
            PACKAGE_FAMILY="rpm"
            DISTRO_KIND="centos-stream"
            OS_DISPLAY="CentOS Stream 9"
            ;;
        *)
            die "Unsupported Linux distribution '${OS_ID}' ${OS_VERSION_ID}. Supported distributions are Ubuntu 24.04 and RHEL-compatible 9."
            ;;
    esac

    RAW_ARCH="$(lowercase "$(get_uname_m)")"
    case "${RAW_ARCH}" in
        x86_64|amd64)
            APT_ARCH="amd64"
            RPM_ARCH="x86_64"
            ;;
        aarch64|arm64)
            APT_ARCH="arm64"
            RPM_ARCH="aarch64"
            ;;
        *)
            die "Unsupported CPU architecture '${RAW_ARCH}'. Supported architectures are x86_64 and arm64."
            ;;
    esac
}

validate_native_environment() {
    require_command grep
    require_command awk
    require_command sed
    require_command sort
    require_command find
    require_command mktemp
    require_command install
    require_command systemctl

    systemd_dir="$(system_path /run/systemd/system)"
    [ -d "${systemd_dir}" ] ||
        die "A running systemd host is required; ${systemd_dir} is not present."

    systemd_state="$(get_systemd_state)"
    case "${systemd_state}" in
        running|degraded) ;;
        *) die "systemd is not ready (state: ${systemd_state:-unknown})." ;;
    esac

    container_virt="$(get_container_virtualization)"
    case "${container_virt}" in
        ''|none) ;;
        *) die "Container environment '${container_virt}' is not supported by the native installer." ;;
    esac

    chroot_virt="$(get_chroot_virtualization)"
    case "${chroot_virt}" in
        ''|none) ;;
        *) die "Chroot environment '${chroot_virt}' is not supported by the native installer." ;;
    esac

    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        require_command apt-get
        require_command dpkg
        require_command dpkg-query
    else
        require_command dnf
        require_command rpm
    fi

    native_arch="$(lowercase "$(get_native_package_arch)")"
    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        [ "${native_arch}" = "${APT_ARCH}" ] ||
            die "Kernel architecture '${RAW_ARCH}' does not match dpkg architecture '${native_arch}'."
    else
        [ "${native_arch}" = "${RPM_ARCH}" ] ||
            die "Kernel architecture '${RAW_ARCH}' does not match RPM architecture '${native_arch}'."
    fi
}

list_existing_packages() {
    if [ "${TESTING}" = "true" ]; then
        printf '%s\n' "${DOCUMENTDB_INSTALLER_TEST_EXISTING_PACKAGES:-}"
        return
    fi

    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' \
            'documentdb*' 'postgresql-*-documentdb' 2>/dev/null |
            awk '$1 !~ /^un/ { print $2 }' | sort -u || true
    else
        {
            rpm -qa 'documentdb*' 2>/dev/null || true
            rpm -qa 'postgresql*documentdb*' 2>/dev/null || true
        } | sort -u
    fi
}

directory_has_entries() {
    directory="$1"
    [ -d "${directory}" ] || return 1
    first_entry="$(find "${directory}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    [ -n "${first_entry}" ]
}

detect_existing_installation() {
    existing_packages="$(list_existing_packages)"
    if [ -n "${existing_packages}" ]; then
        printf '%s\n' "${existing_packages}" | sed 's/^/  - /' >&2
        die "DocumentDB packages are already installed. This bootstrap does not perform upgrades. If a previous install stopped after package installation, run documentdb-setup directly to resume it."
    fi

    if [ "${TESTING}" = "false" ] && command_exists documentdb-setup; then
        die "documentdb-setup is already present on PATH. Refusing to replace or upgrade an existing installation."
    fi

    state_dir="$(system_path /etc/documentdb/local)"
    data_dir="$(system_path /var/lib/documentdb-local)"
    if directory_has_entries "${state_dir}" || directory_has_entries "${data_dir}"; then
        die "Residual DocumentDB state exists under /etc/documentdb/local or /var/lib/documentdb-local. Refusing to reuse or remove existing data."
    fi

    alias_unit="$(system_path /etc/systemd/system/documentdb-local.target)"
    if [ -e "${alias_unit}" ] || [ -L "${alias_unit}" ]; then
        die "Residual systemd unit ${alias_unit} exists. Remove or reconcile the prior installation manually."
    fi
}

file_contains() {
    file="$1"
    pattern="$2"
    [ -r "${file}" ] && grep -Eq "${pattern}" "${file}"
}

file_matches_content() {
    file="$1"
    expected="$2"
    [ -r "${file}" ] || return 1
    actual="$(
        sed \
            -e '/^[[:space:]]*#/d' \
            -e '/^[[:space:]]*$/d' \
            -e 's/[[:space:]]*$//' \
            "${file}"
    )"
    [ "${actual}" = "${expected}" ]
}

preflight_apt_repositories() {
    sources_list="$(system_path /etc/apt/sources.list)"
    sources_dir="$(system_path /etc/apt/sources.list.d)"
    managed_pgdg="$(system_path /etc/apt/sources.list.d/pgdg.list)"
    managed_docdb="$(system_path /etc/apt/sources.list.d/documentdb.list)"
    desired_pgdg="deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main"
    desired_docdb="deb [arch=${APT_ARCH} signed-by=/usr/share/keyrings/documentdb-archive-keyring.gpg] https://documentdb.io/deb stable ubuntu24"

    PGDG_REPO_PRESENT="false"
    PGDG_MANAGED_SOURCE="false"
    DOCUMENTDB_REPO_PRESENT="false"

    for file in "${sources_list}" "${sources_dir}"/*.list "${sources_dir}"/*.sources; do
        [ -f "${file}" ] || continue
        if file_contains "${file}" 'apt\.postgresql\.org/pub/repos/apt'; then
            if [ "${file}" != "${managed_pgdg}" ] ||
               ! file_matches_content "${file}" "${desired_pgdg}"; then
                die "Conflicting PGDG repository configuration found in ${file}. The installer only reuses its exact HTTPS noble-pgdg source definition."
            fi
            PGDG_REPO_PRESENT="true"
            PGDG_MANAGED_SOURCE="true"
        fi
        if file_contains "${file}" 'documentdb\.io/deb'; then
            if [ "${file}" != "${managed_docdb}" ] ||
               ! file_matches_content "${file}" "${desired_docdb}"; then
                die "Conflicting DocumentDB repository configuration found in ${file}."
            fi
            DOCUMENTDB_REPO_PRESENT="true"
        fi
    done

    if [ -e "${managed_pgdg}" ] && [ "${PGDG_REPO_PRESENT}" = "false" ]; then
        die "Refusing to overwrite unrelated repository file ${managed_pgdg}."
    fi
    if [ -e "${managed_docdb}" ] && [ "${DOCUMENTDB_REPO_PRESENT}" = "false" ]; then
        die "Refusing to overwrite unrelated repository file ${managed_docdb}."
    fi

    DESIRED_PGDG_SOURCE="${desired_pgdg}"
    DESIRED_DOCUMENTDB_SOURCE="${desired_docdb}"
}

detect_rhel_crb_method() {
    consumer_cert="$(system_path /etc/pki/consumer/cert.pem)"
    if command_exists subscription-manager && [ -s "${consumer_cert}" ]; then
        RHEL_CRB_METHOD="subscription-manager"
        RHEL_CRB_REPO="codeready-builder-for-rhel-9-${RPM_ARCH}-rpms"
        return
    fi

    if [ "${TESTING}" = "true" ]; then
        repolist="${DOCUMENTDB_INSTALLER_TEST_RHEL_REPOLIST:-}"
    else
        repolist="$(dnf -q repolist --all 2>/dev/null || true)"
    fi

    RHEL_CRB_REPO="$(
        printf '%s\n' "${repolist}" |
            awk -v arch="${RPM_ARCH}" '
                {
                    id = tolower($1)
                    expected = "codeready-builder-for-rhel-9-" tolower(arch) "-rhui-rpms"
                    if (id == expected) {
                        print $1
                        found = 1
                        exit
                    }
                    if (id ~ /codeready-builder/ &&
                        id ~ /rhel-9/ &&
                        id ~ tolower(arch) &&
                        id ~ /rpms$/ &&
                        id !~ /(debug|source)-rpms$/ &&
                        candidate == "") {
                        candidate = $1
                    }
                }
                END {
                    if (!found && candidate != "") {
                        print candidate
                    }
                }
            '
    )"
    [ -n "${RHEL_CRB_REPO}" ] ||
        die "RHEL 9 is not registered with subscription-manager and no RHUI CodeReady Builder repository was found."
    RHEL_CRB_METHOD="dnf"
}

preflight_rpm_repositories() {
    repo_dir="$(system_path /etc/yum.repos.d)"
    managed_docdb="$(system_path /etc/yum.repos.d/documentdb.repo)"
    managed_pgdg="$(system_path /etc/yum.repos.d/pgdg-redhat-all.repo)"
    docdb_key="$(system_path /etc/pki/rpm-gpg/RPM-GPG-KEY-documentdb)"
    desired_docdb="[documentdb]
name=DocumentDB Repository
baseurl=https://documentdb.io/rpm/rhel9
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://${docdb_key}"

    PGDG_REPO_PRESENT="false"
    DOCUMENTDB_REPO_PRESENT="false"

    for file in "${repo_dir}"/*.repo; do
        [ -f "${file}" ] || continue
        if file_contains "${file}" 'download\.postgresql\.org/pub/repos/yum'; then
            if [ "${file}" != "${managed_pgdg}" ]; then
                die "Conflicting PGDG repository configuration found in ${file}. The installer only reuses the PGDG repository package's canonical pgdg-redhat-all.repo file."
            fi
            if [ "${TESTING}" = "false" ] &&
               ! rpm -q pgdg-redhat-repo >/dev/null 2>&1; then
                die "${managed_pgdg} exists but is not owned by the pgdg-redhat-repo package."
            fi
            PGDG_REPO_PRESENT="true"
        fi
        if file_contains "${file}" 'documentdb\.io/rpm'; then
            if [ "${file}" != "${managed_docdb}" ] ||
               ! file_matches_content "${file}" "${desired_docdb}"; then
                die "Conflicting DocumentDB repository configuration found in ${file}."
            fi
            DOCUMENTDB_REPO_PRESENT="true"
        fi
    done

    if [ -e "${managed_docdb}" ] && [ "${DOCUMENTDB_REPO_PRESENT}" = "false" ]; then
        die "Refusing to overwrite unrelated repository file ${managed_docdb}."
    fi

    if [ "${TESTING}" = "false" ] && rpm -q postgresql-server >/dev/null 2>&1; then
        die "The RHEL AppStream postgresql-server package is installed. Refusing to disable the PostgreSQL module on an existing PostgreSQL host."
    fi

    if [ "${DISTRO_KIND}" = "rhel" ]; then
        detect_rhel_crb_method
    fi

    DESIRED_DOCUMENTDB_RPM_REPO="${desired_docdb}"
}

preflight_repositories() {
    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        preflight_apt_repositories
    else
        preflight_rpm_repositories
    fi
}

print_argument() {
    argument="$1"
    case "${argument}" in
        ''|*[!A-Za-z0-9_./:=,@%+-]*)
            escaped="$(printf '%s' "${argument}" | sed "s/'/'\\\\''/g")"
            printf "'%s'" "${escaped}"
            ;;
        *)
            printf '%s' "${argument}"
            ;;
    esac
}

print_command() {
    printf '  +'
    for argument in "$@"; do
        printf ' '
        print_argument "${argument}"
    done
    printf '\n'
}

run_command() {
    if [ "${DRY_RUN}" = "true" ]; then
        print_command "$@"
    else
        "$@"
    fi
}

run_root() {
    if [ "${IS_ROOT}" = "true" ]; then
        run_command "$@"
    else
        run_command "${SUDO}" "$@"
    fi
}

run_root_no_stdin() {
    if [ "${DRY_RUN}" = "true" ]; then
        run_root "$@"
    elif [ "${IS_ROOT}" = "true" ]; then
        "$@" < /dev/null
    else
        "${SUDO}" "$@" < /dev/null
    fi
}

write_root_file() {
    destination="$1"
    mode="$2"
    content="$3"

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would write ${destination} (mode ${mode}):"
        printf '%s\n' "${content}" | sed 's/^/    /'
        return
    fi

    staged="${TMP_DIR}/$(basename "${destination}").staged"
    printf '%s\n' "${content}" > "${staged}"
    run_root install -D -m "${mode}" "${staged}" "${destination}"
}

strict_curl() {
    url="$1"
    output="$2"
    curl --disable --proto '=https' --proto-redir '=https' --tlsv1.2 \
        -fsSL "${url}" -o "${output}"
}

verify_key_fingerprint() {
    key_file="$1"
    expected="$2"
    label="$3"

    key_listing="$(
        GNUPGHOME="${TMP_DIR}/gnupg" gpg --no-options --batch \
            --show-keys --with-colons "${key_file}" 2>/dev/null
    )" || die "Cannot inspect the ${label} signing key."

    public_key_count="$(printf '%s\n' "${key_listing}" | awk -F: '$1 == "pub" { count++ } END { print count + 0 }')"
    [ "${public_key_count}" -eq 1 ] ||
        die "${label} key file contains ${public_key_count} primary keys; expected exactly one."

    actual="$(printf '%s\n' "${key_listing}" |
        awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print toupper($10); exit }')"
    [ "${actual}" = "${expected}" ] ||
        die "${label} key fingerprint is ${actual:-unknown}; expected ${expected}."
}

download_key() {
    url="$1"
    output="$2"
    expected="$3"
    label="$4"

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would download ${label} key from ${url} and require fingerprint ${expected}."
        return
    fi

    strict_curl "${url}" "${output}"
    verify_key_fingerprint "${output}" "${expected}" "${label}"
}

ensure_apt_keyring() {
    destination="$1"
    url="$2"
    expected="$3"
    label="$4"
    armored="${TMP_DIR}/$(basename "${destination}").asc"
    binary="${TMP_DIR}/$(basename "${destination}").gpg"

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would verify or install ${destination} for ${label}."
        download_key "${url}" "${armored}" "${expected}" "${label}"
        return
    fi

    if [ -f "${destination}" ]; then
        verify_key_fingerprint "${destination}" "${expected}" "${label}"
        return
    fi

    download_key "${url}" "${armored}" "${expected}" "${label}"
    GNUPGHOME="${TMP_DIR}/gnupg" gpg --no-options --batch --yes \
        --dearmor --output "${binary}" "${armored}"
    run_root install -D -m 0644 "${binary}" "${destination}"
}

ensure_rpm_key() {
    rpm_key_destination="$1"
    rpm_key_url="$2"
    rpm_key_expected="$3"
    rpm_key_label="$4"
    rpm_key_downloaded="${TMP_DIR:-/tmp}/$(basename "${rpm_key_destination}")"

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would verify or install ${rpm_key_destination} for ${rpm_key_label}."
        download_key "${rpm_key_url}" "${rpm_key_downloaded}" \
            "${rpm_key_expected}" "${rpm_key_label}"
        run_root rpm --import "${rpm_key_destination}"
        return
    fi

    if [ -f "${rpm_key_destination}" ]; then
        verify_key_fingerprint "${rpm_key_destination}" \
            "${rpm_key_expected}" "${rpm_key_label}"
    else
        download_key "${rpm_key_url}" "${rpm_key_downloaded}" \
            "${rpm_key_expected}" "${rpm_key_label}"
        run_root install -D -m 0644 "${rpm_key_downloaded}" "${rpm_key_destination}"
    fi
    run_root_no_stdin rpm --import "${rpm_key_destination}"
}

install_verified_repository_rpm() {
    repository_rpm_url="$1"
    repository_rpm_filename="$2"
    repository_key_destination="$3"
    repository_key_url="$4"
    repository_key_fingerprint="$5"
    repository_label="$6"
    repository_rpm_path="${TMP_DIR:-/tmp}/${repository_rpm_filename}"

    ensure_rpm_key "${repository_key_destination}" "${repository_key_url}" \
        "${repository_key_fingerprint}" "${repository_label}"

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would download ${repository_label} repository package from ${repository_rpm_url}."
    else
        strict_curl "${repository_rpm_url}" "${repository_rpm_path}"
    fi

    run_root_no_stdin dnf --setopt=localpkg_gpgcheck=1 install -y \
        "${repository_rpm_path}"

    if [ "${DRY_RUN}" = "false" ]; then
        # The repository package owns the same key path. Re-check it after the
        # transaction so the enabled repositories cannot silently replace the
        # independently verified bootstrap key.
        verify_key_fingerprint "${repository_key_destination}" \
            "${repository_key_fingerprint}" "${repository_label}"
    fi
}

create_temp_dir() {
    [ "${DRY_RUN}" = "false" ] || return
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/documentdb-install.XXXXXX")"
    mkdir -m 0700 "${TMP_DIR}/gnupg"
}

determine_privilege_mode() {
    if [ "${TESTING}" = "true" ]; then
        IS_ROOT="false"
        SUDO="sudo"
        return
    fi

    if [ "$(id -u)" -eq 0 ]; then
        IS_ROOT="true"
        SUDO=""
        return
    fi

    require_command sudo
    IS_ROOT="false"
    SUDO="sudo"
}

acquire_privileges() {
    [ "${DRY_RUN}" = "false" ] || return
    [ "${IS_ROOT}" = "false" ] || return

    if [ "${ASSUME_YES}" = "true" ]; then
        sudo -n true >/dev/null 2>&1 ||
            die "--yes requires root or non-interactive sudo access."
    else
        sudo -v
    fi
}

tty_available() {
    [ -r "${TTY_PATH}" ] && [ -w "${TTY_PATH}" ]
}

confirm_plan() {
    [ "${DRY_RUN}" = "false" ] || return
    [ "${ASSUME_YES}" = "false" ] || return
    tty_available ||
        die "Interactive confirmation requires /dev/tty. Use --yes with --admin-password-file for unattended installation."

    printf 'Continue with this installation? [y/N] ' > "${TTY_PATH}"
    answer=""
    IFS= read -r answer < "${TTY_PATH}" || true
    case "${answer}" in
        y|Y|yes|YES) ;;
        *) die "Installation cancelled." ;;
    esac
}

prompt_password_file() {
    [ "${DRY_RUN}" = "false" ] || return

    password_copy="${TMP_DIR}/admin-password"
    if [ -n "${ADMIN_PASSWORD_FILE}" ]; then
        cp "${ADMIN_PASSWORD_FILE}" "${password_copy}"
        chmod 0600 "${password_copy}"
        [ -s "${password_copy}" ] || die "Password file is empty."
        ADMIN_PASSWORD_FILE="${password_copy}"
        return
    fi

    tty_available ||
        die "Password prompt requires /dev/tty. Use --admin-password-file for unattended installation."
    require_command stty

    attempts=0
    while [ "${attempts}" -lt 3 ]; do
        TTY_STATE="$(stty -g < "${TTY_PATH}")"
        stty -echo < "${TTY_PATH}"
        printf 'DocumentDB admin password: ' > "${TTY_PATH}"
        password=""
        IFS= read -r password < "${TTY_PATH}" || true
        printf '\nConfirm admin password: ' > "${TTY_PATH}"
        confirmation=""
        IFS= read -r confirmation < "${TTY_PATH}" || true
        restore_tty

        if [ -n "${password}" ] && [ "${password}" = "${confirmation}" ]; then
            printf '%s' "${password}" > "${password_copy}"
            chmod 0600 "${password_copy}"
            password=""
            confirmation=""
            ADMIN_PASSWORD_FILE="${password_copy}"
            return
        fi

        password=""
        confirmation=""
        attempts=$((attempts + 1))
        if [ "${attempts}" -lt 3 ]; then
            warn "Passwords were empty or did not match; try again."
        fi
    done

    die "Passwords did not match after three attempts."
}

print_plan() {
    log "Installation plan"
    printf '  Operating system: %s\n' "${OS_DISPLAY}"
    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        printf '  Architecture:     %s\n' "${APT_ARCH}"
        printf '  Package manager:  apt\n'
    else
        printf '  Architecture:     %s\n' "${RPM_ARCH}"
        printf '  Package manager:  dnf\n'
    fi
    printf '  PostgreSQL major: %s\n' "${PG_MAJOR}"
    printf '  Package:          documentdb-%s\n' "${PG_MAJOR}"
    printf '  Admin user:       %s\n' "${ADMIN_USER}"
    printf '  Gateway port:     %s\n' "${LISTEN_PORT}"
    printf '  Deployment:       new private PostgreSQL instance managed by systemd\n'
    printf '\n'
    warn "The setup wizard currently binds the gateway on all interfaces with a self-signed TLS certificate. Restrict port ${LISTEN_PORT} with the host firewall before exposing this machine to an untrusted network."
    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        log "The installer may add the PGDG and DocumentDB APT repositories."
    else
        log "The installer may enable CRB/CodeReady Builder, EPEL, PGDG, and the DocumentDB DNF repository."
    fi
}

install_ubuntu() {
    pgdg_keyring="$(system_path /usr/share/keyrings/postgresql.gpg)"
    docdb_keyring="$(system_path /usr/share/keyrings/documentdb-archive-keyring.gpg)"
    pgdg_source="$(system_path /etc/apt/sources.list.d/pgdg.list)"
    docdb_source="$(system_path /etc/apt/sources.list.d/documentdb.list)"

    run_root_no_stdin env DEBIAN_FRONTEND=noninteractive apt-get update
    run_root_no_stdin env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends ca-certificates curl gnupg

    if [ "${PGDG_REPO_PRESENT}" = "false" ]; then
        ensure_apt_keyring "${pgdg_keyring}" "${PGDG_APT_KEY_URL}" \
            "${PGDG_APT_KEY_FINGERPRINT}" "PGDG"
        write_root_file "${pgdg_source}" 0644 "${DESIRED_PGDG_SOURCE}"
    elif [ "${PGDG_MANAGED_SOURCE}" = "true" ]; then
        ensure_apt_keyring "${pgdg_keyring}" "${PGDG_APT_KEY_URL}" \
            "${PGDG_APT_KEY_FINGERPRINT}" "PGDG"
    else
        log "Reusing the existing Ubuntu 24.04 PGDG repository configuration."
    fi

    ensure_apt_keyring "${docdb_keyring}" "${DOCUMENTDB_KEY_URL}" \
        "${DOCUMENTDB_KEY_FINGERPRINT}" "DocumentDB"
    if [ "${DOCUMENTDB_REPO_PRESENT}" = "false" ]; then
        write_root_file "${docdb_source}" 0644 "${DESIRED_DOCUMENTDB_SOURCE}"
    else
        log "Reusing the existing DocumentDB APT repository configuration."
    fi

    run_root_no_stdin env DEBIAN_FRONTEND=noninteractive apt-get update
    run_root_no_stdin env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "documentdb-${PG_MAJOR}"
}

rpm_package_installed() {
    package="$1"
    if [ "${TESTING}" = "true" ]; then
        installed="${DOCUMENTDB_INSTALLER_TEST_RPM_INSTALLED:-}"
        case " ${installed} " in
            *" ${package} "*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    rpm -q "${package}" >/dev/null 2>&1
}

install_rhel_family() {
    docdb_repo="$(system_path /etc/yum.repos.d/documentdb.repo)"
    docdb_key="$(system_path /etc/pki/rpm-gpg/RPM-GPG-KEY-documentdb)"
    epel_key="$(system_path /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-9)"
    pgdg_key="$(system_path /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-RHEL)"
    pgdg_repo_url="https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-${RPM_ARCH}/pgdg-redhat-repo-latest.noarch.rpm"

    require_command curl
    run_root_no_stdin dnf install -y ca-certificates gnupg2 dnf-plugins-core

    case "${DISTRO_KIND}" in
        rhel)
            if [ "${RHEL_CRB_METHOD}" = "subscription-manager" ]; then
                require_command subscription-manager
                run_root_no_stdin subscription-manager repos \
                    --enable "${RHEL_CRB_REPO}"
            else
                run_root_no_stdin dnf config-manager --set-enabled "${RHEL_CRB_REPO}"
            fi
            ;;
        rocky|almalinux|centos-stream)
            run_root_no_stdin dnf config-manager --set-enabled crb
            ;;
    esac

    if ! rpm_package_installed epel-release; then
        install_verified_repository_rpm \
            "${EPEL_RELEASE_URL}" \
            "epel-release-latest-9.noarch.rpm" \
            "${epel_key}" \
            "${EPEL_KEY_URL}" \
            "${EPEL_KEY_FINGERPRINT}" \
            "EPEL 9"
    else
        log "Reusing the installed epel-release package."
    fi
    if [ "${DISTRO_KIND}" = "centos-stream" ] &&
       ! rpm_package_installed epel-next-release; then
        run_root_no_stdin dnf install -y epel-next-release
    fi

    if [ "${PGDG_REPO_PRESENT}" = "false" ]; then
        install_verified_repository_rpm \
            "${pgdg_repo_url}" \
            "pgdg-redhat-repo-latest.noarch.rpm" \
            "${pgdg_key}" \
            "${PGDG_RPM_KEY_URL}" \
            "${PGDG_RPM_KEY_FINGERPRINT}" \
            "PGDG RPM"
    else
        log "Reusing the existing PGDG DNF repository configuration."
    fi

    run_root_no_stdin dnf -qy module disable postgresql

    ensure_rpm_key "${docdb_key}" "${DOCUMENTDB_KEY_URL}" \
        "${DOCUMENTDB_KEY_FINGERPRINT}" "DocumentDB"
    if [ "${DOCUMENTDB_REPO_PRESENT}" = "false" ]; then
        write_root_file "${docdb_repo}" 0644 "${DESIRED_DOCUMENTDB_RPM_REPO}"
    else
        log "Reusing the existing DocumentDB DNF repository configuration."
    fi

    run_root_no_stdin dnf clean expire-cache
    run_root_no_stdin dnf -y makecache --refresh
    run_root_no_stdin dnf -q --disablerepo='*' --enablerepo=documentdb \
        list --available "documentdb-${PG_MAJOR}"
    run_root_no_stdin dnf install -y "documentdb-${PG_MAJOR}"
}

run_setup() {
    setup_command="documentdb-setup"
    if [ "${DRY_RUN}" = "false" ]; then
        command_exists "${setup_command}" ||
            die "Package installation completed but documentdb-setup is not on PATH."
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log "Would provision and start the DocumentDB instance:"
        run_root "${setup_command}" --yes \
            --pg-version "${PG_MAJOR}" \
            --use-new-postgres-instance \
            --admin-user "${ADMIN_USER}" \
            --admin-password-file "<temporary-password-file>" \
            --listen-port "${LISTEN_PORT}"
        return
    fi

    if ! run_root_no_stdin "${setup_command}" --yes \
        --pg-version "${PG_MAJOR}" \
        --use-new-postgres-instance \
        --admin-user "${ADMIN_USER}" \
        --admin-password-file "${ADMIN_PASSWORD_FILE}" \
        --listen-port "${LISTEN_PORT}"; then
        warn "The packages remain installed, but setup did not complete."
        warn "After resolving the reported error, resume with:"
        warn "  sudo documentdb-setup --yes --pg-version ${PG_MAJOR} --use-new-postgres-instance --admin-user ${ADMIN_USER} --admin-password-file <file> --listen-port ${LISTEN_PORT}"
        return 1
    fi

    run_root_no_stdin "${setup_command}" --status --pg-version "${PG_MAJOR}"
}

print_success() {
    log "DocumentDB installation completed successfully."
    printf '  Endpoint: mongodb://%s@127.0.0.1:%s/?tls=true&tlsAllowInvalidCertificates=true\n' \
        "${ADMIN_USER}" "${LISTEN_PORT}"
    printf '  Status:   sudo documentdb-setup --status --pg-version %s\n' "${PG_MAJOR}"
    printf '  Service:  sudo systemctl status documentdb-local@%s.target\n' "${PG_MAJOR}"
}

main() {
    parse_arguments "$@"
    validate_arguments
    initialize_environment
    detect_platform
    validate_native_environment
    determine_privilege_mode
    detect_existing_installation
    preflight_repositories
    print_plan

    if [ "${DRY_RUN}" = "true" ]; then
        if [ "${PACKAGE_FAMILY}" = "apt" ]; then
            install_ubuntu
        else
            install_rhel_family
        fi
        run_setup
        log "Dry run complete; no changes were made."
        return
    fi

    confirm_plan
    acquire_privileges
    create_temp_dir
    prompt_password_file

    if [ "${PACKAGE_FAMILY}" = "apt" ]; then
        install_ubuntu
    else
        install_rhel_family
    fi

    run_setup
    print_success
}

# Keep the call as the final executable line: if a curl stream is truncated,
# the shell sees only definitions and never starts a partial installation.
main "$@"
