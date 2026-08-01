#!/usr/bin/env bash
# Debian-specific half of publish.sh. This runs in the Ubuntu 26.04 image.
set -euo pipefail

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

for variable_name in SERIES PPA_REMOTE GPG_KEY UNSIGNED NO_UPLOAD TEST_BUILD; do
    [ -n "${!variable_name+x}" ] || die "missing environment variable: ${variable_name}"
done

PACKAGE_DIR=/repo
OUTPUT_DIR=/out
[ -d "${PACKAGE_DIR}/debian" ] || die "package source is not mounted at ${PACKAGE_DIR}"
[ -d "${OUTPUT_DIR}" ] || die "artifact output is not mounted at ${OUTPUT_DIR}"

SOURCE="$(dpkg-parsechangelog -l"${PACKAGE_DIR}/debian/changelog" -SSource)"
VERSION="$(dpkg-parsechangelog -l"${PACKAGE_DIR}/debian/changelog" -SVersion)"
DISTRIBUTION="$(dpkg-parsechangelog -l"${PACKAGE_DIR}/debian/changelog" -SDistribution)"
[ "${SOURCE}" = "telegram-desktop" ] || die "unexpected source package: ${SOURCE}"
[ "${DISTRIBUTION}" = "${SERIES}" ] \
    || die "debian/changelog targets ${DISTRIBUTION}, expected ${SERIES}"
[ "$(<"${PACKAGE_DIR}/debian/source/format")" = "3.0 (native)" ] \
    || die "expected Debian source format 3.0 (native)"

SAFE_VERSION="${VERSION//:/_}"
WORK="$(mktemp -d /tmp/tdesktop-publish.XXXXXX)"
cleanup() {
    if [ -d "${WORK}" ] && [ ! -L "${WORK}" ]; then
        find "${WORK}" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

SOURCE_DIR="${WORK}/${SOURCE}-${SAFE_VERSION}"
install -d -m 0755 "${SOURCE_DIR}"

# Keep dpkg-buildpackage away from the read-only checkout. --exclude=.git also
# drops the .git *files* inside the submodules, leaving their contents as plain
# source, which is what a native package wants.
say "Copying source tree"
tar -C "${PACKAGE_DIR}" \
    --exclude=.git \
    --exclude=./out \
    --exclude=./build \
    --exclude='./build-*' \
    --exclude='./obj-*' \
    --exclude=./build-packages \
    --exclude=./.cache \
    --exclude=./debian/.debhelper \
    --exclude=./debian/debhelper-build-stamp \
    --exclude=./debian/files \
    --exclude='./debian/*.substvars' \
    --exclude=./debian/telegram-desktop \
    -cf - . | tar -C "${SOURCE_DIR}" -xf -

say "Creating source package"
BUILD_ARGS=(-S -d)
if [ "${UNSIGNED}" -eq 1 ]; then
    BUILD_ARGS+=(-us -uc)
else
    BUILD_ARGS+=("-k${GPG_KEY}")
fi
( cd "${SOURCE_DIR}" && dpkg-buildpackage "${BUILD_ARGS[@]}" )

mapfile -t CHANGES_FILES < <(find "${WORK}" -maxdepth 1 -type f -name "${SOURCE}_*_source.changes" -print)
mapfile -t DSC_FILES     < <(find "${WORK}" -maxdepth 1 -type f -name "${SOURCE}_*.dsc" -print)
[ "${#CHANGES_FILES[@]}" -eq 1 ] || die "expected one source .changes file, found ${#CHANGES_FILES[@]}"
[ "${#DSC_FILES[@]}" -eq 1 ]     || die "expected one .dsc file, found ${#DSC_FILES[@]}"
CHANGES_FILE="${CHANGES_FILES[0]}"
DSC_FILE="${DSC_FILES[0]}"

verify_sha256_manifest() {
    local manifest="$1"
    local checksum_lines
    checksum_lines="$(
        awk '
            /^Checksums-Sha256:/ { inside = 1; next }
            inside && /^[^ ]/ { exit }
            inside && NF == 3 { print $1 "  " $3 }
        ' "${manifest}"
    )"
    [ -n "${checksum_lines}" ] || die "no SHA-256 manifest in ${manifest}"
    (
        cd "$(dirname -- "${manifest}")"
        printf '%s\n' "${checksum_lines}" | sha256sum --check --strict --quiet -
    )
}

say "Verifying source-package checksums"
verify_sha256_manifest "${DSC_FILE}"
verify_sha256_manifest "${CHANGES_FILE}"

if [ "${UNSIGNED}" -eq 0 ]; then
    say "Verifying OpenPGP signatures"
    gpg --batch --verify "${DSC_FILE}"
    gpg --batch --verify "${CHANGES_FILE}"
elif grep -q '^-----BEGIN PGP SIGNATURE-----$' "${CHANGES_FILE}"; then
    die "unsigned mode unexpectedly produced a signed .changes file"
fi

say "Checking that the source package extracts cleanly"
# Signatures and every Checksums-Sha256 entry were checked above. --no-check
# avoids dpkg-source's separate gpgv keyring, which does not know PPA keys.
dpkg-source --no-check -x "${DSC_FILE}" "${WORK}/extracted" >/dev/null

say "Running lintian"
lintian --display-info --pedantic "${CHANGES_FILE}" || warn "lintian reported issues"

if [ "${TEST_BUILD}" = "1" ]; then
    say "Installing build dependencies for the test build"
    rm -f /etc/apt/apt.conf.d/docker-clean
    apt-get update -qq
    apt-get build-dep -y --no-install-recommends "${SOURCE_DIR}"

    say "Running binary test build (unsigned, not uploaded)"
    # Build the *extracted source package*, not the working-tree copy. They are
    # not the same thing: dpkg-source applies debian/source/options tar-ignore
    # patterns when it builds the tarball, so a bad pattern can delete files
    # that are still present in the copy. Launchpad only ever sees the tarball,
    # so that is what has to be proven to build.
    #
    # Cap parallelism locally: this tree has translation units that peak well
    # over 1 GB in cc1plus even at -g1, so one job per core OOMs a big host.
    # Launchpad's builders have far fewer cores and are left to their default.
    TEST_BUILD_JOBS="${TEST_BUILD_JOBS:-$(( $(nproc) < 8 ? $(nproc) : 8 ))}"
    say "Using parallel=${TEST_BUILD_JOBS}"
    BINARY_BUILD_DIR="${WORK}/extracted"
    ( cd "${BINARY_BUILD_DIR}" \
        && DEB_BUILD_OPTIONS="parallel=${TEST_BUILD_JOBS}" debuild -b -d -us -uc )
    say "Binary test build succeeded"

    say "Installed layout"
    find "${BINARY_BUILD_DIR}/debian/telegram-desktop" -type f \
        ! -path '*/icons/*' | sed "s|${BINARY_BUILD_DIR}/debian/telegram-desktop||"
    printf 'icons: %s\n' \
        "$(find "${BINARY_BUILD_DIR}/debian/telegram-desktop" -path '*/icons/*' -type f 2>/dev/null | wc -l)"
fi

# Preserve artifacts before upload so a transient dput failure can be retried
# without rebuilding the source package.
while IFS= read -r -d '' artifact; do
    cp -a -- "${artifact}" "${OUTPUT_DIR}/"
done < <(find "${WORK}" -maxdepth 1 -type f -print0)

if [ "${NO_UPLOAD}" = "1" ]; then
    say "Upload disabled"
else
    say "Uploading $(basename -- "${CHANGES_FILE}") to ${PPA_REMOTE}"
    dput "${PPA_REMOTE}" "${CHANGES_FILE}"
fi
