#!/usr/bin/env bash
# Host-side launcher for building and publishing telegram-desktop to Launchpad.
# Debian packaging runs in an Ubuntu container, so this works on Gentoo.
#
# This is a native package built straight from this branch: the checked-out
# tdesktop tree *is* the source. To move to a newer upstream commit, rebase this
# branch onto it and add a debian/changelog entry.
set -euo pipefail

PPA_REMOTE="${PPA_REMOTE:-ppa:lightofmysoul/tg}"
PPA_PACKAGES_URL="${PPA_PACKAGES_URL:-https://launchpad.net/~lightofmysoul/+archive/ubuntu/tg/+packages}"
SERIES="${SERIES:-resolute}"
GPG_KEY_FINGERPRINT="${GPG_KEY_FINGERPRINT:-C21DA3A97F220CA130545721B179022596F6BFCD}"
IMAGE_TAG="${IMAGE_TAG:-tdesktop-ppa-builder}"

NO_UPLOAD=0
UNSIGNED=0
ALLOW_DIRTY=0
TEST_BUILD=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Build a source-only telegram-desktop package for ${SERIES} in an Ubuntu Podman
container. By default the source is signed and uploaded to ${PPA_REMOTE};
Launchpad builds the binaries for amd64 and arm64.

  --test-build      Install build-deps in the container and run a full binary
                    build before uploading. Source is only dput'd if it
                    succeeds. Roughly 10 min.
  --no-upload       Build, sign and validate, but do not run dput.
  --unsigned        Build without a key; implies --no-upload.
  --allow-dirty     Permit an unclean tree (validation only).
  --key FINGERPRINT Override the OpenPGP signing-key fingerprint.
  --ppa TARGET      Override the dput target (default: ${PPA_REMOTE}).
  -h, --help        Show this help.

Generated artifacts are retained under build-packages/ (gitignored).

Host requirements: podman, git, and gpg (unless --unsigned is used).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --test-build)  TEST_BUILD=1; shift ;;
        --no-upload)   NO_UPLOAD=1; shift ;;
        --unsigned)    UNSIGNED=1; NO_UPLOAD=1; shift ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --key)         [ "$#" -ge 2 ] || die "--key needs a fingerprint"; GPG_KEY_FINGERPRINT="$2"; shift 2 ;;
        --ppa)         [ "$#" -ge 2 ] || die "--ppa needs a dput target"; PPA_REMOTE="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done

if [ "${ALLOW_DIRTY}" -eq 1 ] && [ "${NO_UPLOAD}" -eq 0 ]; then
    die "--allow-dirty is restricted to --no-upload/--unsigned validation"
fi

MISSING_COMMANDS=()
for command_name in git podman sed date mktemp cp find sha256sum tar; do
    command -v "${command_name}" >/dev/null 2>&1 || MISSING_COMMANDS+=("${command_name}")
done
[ "${UNSIGNED}" -eq 1 ] || command -v gpg >/dev/null 2>&1 || MISSING_COMMANDS+=(gpg)
if [ "${#MISSING_COMMANDS[@]}" -ne 0 ]; then
    printf 'error: missing required host commands:' >&2
    printf ' %s' "${MISSING_COMMANDS[@]}" >&2
    printf '\nOn Gentoo, install Podman with:\n  sudo emerge --ask app-containers/podman\n' >&2
    exit 1
fi

PACKAGE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(git -C "${PACKAGE_DIR}" rev-parse --show-toplevel 2>/dev/null)" \
    || die "publish.sh must be run from the Git checkout"
[ "${REPO}" = "${PACKAGE_DIR}" ] || die "unexpected package path: ${PACKAGE_DIR}"

BRANCH="$(git -C "${REPO}" rev-parse --abbrev-ref HEAD)"
[ "${BRANCH}" = "tdesktop_ubuntu" ] \
    || warn "on branch ${BRANCH}, expected tdesktop_ubuntu"

# Every submodule must be present: this is a native package, so the tree is the
# source, and anything missing silently drops a feature or breaks configure.
UNINITIALISED="$(git -C "${REPO}" submodule status --recursive | grep -c '^-' || true)"
[ "${UNINITIALISED}" -eq 0 ] \
    || die "${UNINITIALISED} submodule(s) not initialised — run: git submodule update --init --recursive"

TREE_STATUS="$(git -C "${REPO}" status --porcelain --untracked-files=all)"
if [ -n "${TREE_STATUS}" ]; then
    if [ "${ALLOW_DIRTY}" -eq 0 ]; then
        printf '%s\n' "${TREE_STATUS}" >&2
        die "tree has uncommitted files; commit them or use --allow-dirty for validation"
    fi
    warn "building from a dirty tree"
fi

CHANGELOG_HEADER="$(sed -n '1p' "${PACKAGE_DIR}/debian/changelog")"
CHANGELOG_PATTERN='^([^[:space:]]+)[[:space:]]+\(([^)]*)\)[[:space:]]+([^;[:space:]]+);'
if [[ "${CHANGELOG_HEADER}" =~ ${CHANGELOG_PATTERN} ]]; then
    SOURCE="${BASH_REMATCH[1]}"
    VERSION="${BASH_REMATCH[2]}"
    DISTRIBUTION="${BASH_REMATCH[3]}"
else
    die "cannot parse the first line of debian/changelog"
fi
[ "${SOURCE}" = "telegram-desktop" ] || die "unexpected source package: ${SOURCE}"
[ "${DISTRIBUTION}" = "${SERIES}" ] \
    || die "debian/changelog targets ${DISTRIBUTION}, expected ${SERIES}"
[ "$(<"${PACKAGE_DIR}/debian/source/format")" = "3.0 (native)" ] \
    || die "expected Debian source format 3.0 (native)"

if [ "${UNSIGNED}" -eq 0 ]; then
    HOST_GNUPG_HOME="${GNUPGHOME:-${HOME}/.gnupg}"
    [ -d "${HOST_GNUPG_HOME}" ] || die "GnuPG home does not exist: ${HOST_GNUPG_HOME}"
    gpg --homedir "${HOST_GNUPG_HOME}" --batch --with-colons \
        --list-secret-keys "${GPG_KEY_FINGERPRINT}" 2>/dev/null | grep -q '^sec:' \
        || die "secret GPG key ${GPG_KEY_FINGERPRINT} is not available"
else
    warn "building an unsigned source package; upload is disabled"
fi

CONTAINERFILE="${PACKAGE_DIR}/Containerfile"
INSIDE_SCRIPT="${PACKAGE_DIR}/inside-container.sh"
[ -f "${CONTAINERFILE}" ] || die "missing ${CONTAINERFILE}"
[ -f "${INSIDE_SCRIPT}" ] || die "missing ${INSIDE_SCRIPT}"

CONTAINERFILE_SHA256="$(sha256sum -- "${CONTAINERFILE}")"
CONTAINERFILE_SHA256="${CONTAINERFILE_SHA256%% *}"
IMAGE_CONTAINERFILE_SHA256=""
if podman image exists "${IMAGE_TAG}"; then
    IMAGE_CONTAINERFILE_SHA256="$(
        podman image inspect \
            --format '{{ index .Labels "org.tdesktop.containerfile-sha256" }}' \
            "${IMAGE_TAG}" 2>/dev/null || true
    )"
fi
if [ "${IMAGE_CONTAINERFILE_SHA256}" != "${CONTAINERFILE_SHA256}" ]; then
    say "Building Ubuntu packaging image ${IMAGE_TAG}"
    podman build \
        --label "org.tdesktop.containerfile-sha256=${CONTAINERFILE_SHA256}" \
        --tag "${IMAGE_TAG}" \
        --file "${CONTAINERFILE}" \
        "${PACKAGE_DIR}"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SAFE_VERSION="${VERSION//:/_}"
ARTIFACT_DIR="${PACKAGE_DIR}/build-packages/${SOURCE}-${SAFE_VERSION}-${RUN_ID}"
[ ! -e "${ARTIFACT_DIR}" ] || die "artifact directory already exists: ${ARTIFACT_DIR}"
install -d -m 0755 "${ARTIFACT_DIR}"
install -d -m 0755 "${PACKAGE_DIR}/.cache/apt-archives"

TEMP_GPG=""
cleanup() {
    if [ -n "${TEMP_GPG}" ] && [ -d "${TEMP_GPG}" ] && [ ! -L "${TEMP_GPG}" ]; then
        chmod -R u+w "${TEMP_GPG}" 2>/dev/null || true
        find "${TEMP_GPG}" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

CONTAINER_ARGS=(
    run --rm
    --volume "${REPO}:/repo:ro"
    --volume "${ARTIFACT_DIR}:/out"
    --volume "${PACKAGE_DIR}/.cache/apt-archives:/var/cache/apt/archives"
    --env "SERIES=${SERIES}"
    --env "PPA_REMOTE=${PPA_REMOTE}"
    --env "GPG_KEY=${GPG_KEY_FINGERPRINT}"
    --env "UNSIGNED=${UNSIGNED}"
    --env "NO_UPLOAD=${NO_UPLOAD}"
    --env "TEST_BUILD=${TEST_BUILD}"
)

if [ "${UNSIGNED}" -eq 0 ]; then
    # Copy the GPG home, stripping sockets and lock files, so the container gets
    # its own lock state. Otherwise gpg inside waits forever on locks held by
    # host-side gpg-agent processes whose PIDs do not exist in its namespace.
    TEMP_GPG="$(mktemp -d "${TMPDIR:-/tmp}/tdesktop-gnupg.XXXXXX")"
    cp -a "${HOST_GNUPG_HOME}/." "${TEMP_GPG}/"
    find "${TEMP_GPG}" \( -name 'S.*' -o -name '*.lock' -o -name '.#lk*' \) -delete
    chmod 700 "${TEMP_GPG}"
    CONTAINER_ARGS+=(--volume "${TEMP_GPG}:/root/.gnupg")
fi

say "Building ${SOURCE} ${VERSION} for ${DISTRIBUTION} in Ubuntu 26.04"
podman "${CONTAINER_ARGS[@]}" "${IMAGE_TAG}" bash /repo/inside-container.sh

mapfile -t CHANGES_FILES < <(
    find "${ARTIFACT_DIR}" -maxdepth 1 -type f -name "${SOURCE}_*_source.changes" -print
)
[ "${#CHANGES_FILES[@]}" -eq 1 ] \
    || die "expected one source .changes file, found ${#CHANGES_FILES[@]}"

say "Artifacts: ${ARTIFACT_DIR}"
( cd "${ARTIFACT_DIR}" && sha256sum -- * )

if [ "${NO_UPLOAD}" -eq 1 ]; then
    say "Upload skipped"
    say "To upload later: dput ${PPA_REMOTE} ${CHANGES_FILES[0]}"
else
    say "Upload complete; watch ${PPA_PACKAGES_URL}"
fi
