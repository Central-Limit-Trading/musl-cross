#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
target_dir="${repo_root}/targets/x86_64-unknown-linux-musl"
expected_ctng=d7a90ff11aae5e59d6acd8c491f0297c15b7fa37

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

actual_ctng=$(git -C "${repo_root}/builder" rev-parse HEAD)
[[ "${actual_ctng}" == "${expected_ctng}" ]] ||
    fail "builder is ${actual_ctng}, expected ${expected_ctng}"

grep -qx 'CT_GCC_V_16=y' "${target_dir}/config" ||
    fail "GCC 16 selector missing"
grep -qx 'CT_MUSL_V_1_2_6=y' "${target_dir}/config" ||
    fail "musl 1.2.6 selector missing"
grep -qx 'CT_CC_GCC_LIBSANITIZER=y' "${target_dir}/config" ||
    fail "libsanitizer disabled"
grep -q 'musl-1.2.6' "${target_dir}/config" ||
    fail "musl 1.2.6 mirror missing"
if grep -Eq 'CT_GCC_V_15=y|musl-1\.2\.5' "${target_dir}/config"; then
    fail "stale GCC 15 or musl 1.2.5 selection remains"
fi

# shellcheck disable=SC1090,SC1091
source "${target_dir}/versions"
[[ "${EXPECTED_GCC_VERSION}" == 16.2.0 ]] ||
    fail "unexpected expected GCC version"
[[ "${EXPECTED_MUSL_VERSION}" == 1.2.6 ]] ||
    fail "unexpected expected musl version"
[[ "${EXPECTED_MUSL_LOADER}" == ld-musl-x86_64.so.1 ]] ||
    fail "unexpected musl loader"

if grep -q 'packages/gcc/15\.2\.0' \
    "${target_dir}/0001-enable-musl-libsanitizer.patch"; then
    fail "GCC 15.2.0-only sanitizer patch remains"
fi

[[ -f "${repo_root}/builder/packages/gcc/16.2.0/chksum" ]] ||
    fail "GCC 16.2 package missing"
[[ -f "${repo_root}/builder/packages/musl/1.2.6/chksum" ]] ||
    fail "musl 1.2.6 package missing"
grep -lE 'src/locale/iconv\.c|gb18030' \
    "${repo_root}/builder/packages/musl/1.2.6"/*.patch >/dev/null ||
    fail "musl iconv security patch missing"

[[ -z "$(git -C "${repo_root}/builder" status --porcelain)" ]] ||
    fail "builder is not clean"

(
    cd "${repo_root}/builder"
    patch --fuzz=0 --dry-run -Np1 \
        -i "${target_dir}/0001-enable-musl-libsanitizer.patch"
    patch --fuzz=0 --dry-run -Np1 \
        -i "${target_dir}/0002-linux-kernel-mirror-fallback.patch"
) >/dev/null

echo "source upgrade contract: PASS"
