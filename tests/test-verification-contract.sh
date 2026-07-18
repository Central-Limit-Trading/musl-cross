#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

verifier="${repo_root}/scripts/verify-toolchain.sh"
make_script="${repo_root}/scripts/make"
docker_script="${repo_root}/scripts/build-with-docker.sh"
workflow="${repo_root}/.github/workflows/release.yaml"
alinux_packages="${repo_root}/scripts/packages/alinux3.conf"
versions="${repo_root}/targets/x86_64-unknown-linux-musl/versions"

[[ -x "${verifier}" ]] || fail "runtime verifier is not executable"
bash -n "${verifier}"
bash -n "${make_script}"
bash -n "${docker_script}"

grep -q 'EXPECTED_VERSIONS_FILE=' "${make_script}" ||
    fail "target version metadata is not loaded"
grep -q 'CT_GCC_VERSION=' "${make_script}" ||
    fail "resolved GCC version is not asserted"
grep -q 'CT_MUSL_VERSION=' "${make_script}" ||
    fail "resolved musl version is not asserted"
grep -q 'verify-toolchain.sh' "${make_script}" ||
    fail "runtime verifier is not invoked"
grep -q 'git rev-parse --is-inside-work-tree' "${make_script}" ||
    fail "builder cleanup does not recognize submodule .git files"
! grep -q 'if \[ -d \.git \]' "${make_script}" ||
    fail "builder cleanup still requires .git to be a directory"
grep -q 'Checksum verification passed' "${docker_script}" ||
    fail "renamed artifact checksum gate is missing"
! grep -q 'mv /opt/x-tools/' "${make_script}" ||
    fail "packaging still moves the toolchain into a potentially stale worktree directory"
grep -q 'tar -C /opt/x-tools' "${make_script}" ||
    fail "packaging does not archive directly from the toolchain install root"
grep -q 'read -r actual_hash' "${docker_script}" ||
    fail "renamed artifact hash is not parsed without nested awk quoting"
grep -q 'read -r expected_hash' "${docker_script}" ||
    fail "stored artifact hash is not parsed without nested awk quoting"
# The single-quoted pattern intentionally matches literal shell variable syntax.
# shellcheck disable=SC2016
grep -q '\-z "${actual_hash}".*\-z "${expected_hash}"' "${docker_script}" ||
    fail "renamed artifact checksum gate accepts empty hashes"
grep -q -- '--security-opt seccomp=unconfined' "${docker_script}" ||
    fail "container does not permit the TSan no-ASLR personality"
grep -q 'setarch.*-R' "${verifier}" ||
    fail "TSan is not executed with ASLR disabled"
grep -q 'verify_cflags=.*-Werror' "${verifier}" ||
    fail "runtime verifier does not reject compiler warnings"
grep -q 'pthread_barrier_wait' "${verifier}" ||
    fail "TSan race sample does not synchronize competing writers"
grep -q 'for (.*shared++' "${verifier}" ||
    fail "TSan race sample does not sustain overlapping writes"
grep -q 'OS_LABEL.*alinux3\|alinux3.*OS_LABEL' "${docker_script}" ||
    fail "Alibaba Linux 3 container setup is missing"
grep -q '\[alinux3-module\]' "${docker_script}" ||
    fail "Alibaba Linux 3 module repository is missing"

[[ -f "${alinux_packages}" ]] || fail "Alibaba Linux 3 package configuration is missing"
bash -n "${alinux_packages}"
for package_config in amazonlinux2 alinux3 centos7 ubuntu22; do
    grep -q '"util-linux"' "${repo_root}/scripts/packages/${package_config}.conf" ||
        fail "${package_config} does not install setarch via util-linux"
done

grep -q "containers\[alinux3\]=" "${workflow}" ||
    fail "Alibaba Linux 3 build matrix entry is missing"
grep -Eq 'SELECTED_CONTAINERS=.*amazonlinux2.*alinux3.*centos7.*ubuntu22' "${workflow}" ||
    fail "all-container selection does not include all four consumers"
grep -q "needs.build.result == 'success'" "${workflow}" ||
    fail "release job is not restricted to a successful build matrix"
grep -q "inputs.containers == 'all'" "${workflow}" ||
    fail "release can be created from a partial container selection"
grep -q "inputs.targets == 'x86_64-unknown-linux-musl'" "${workflow}" ||
    fail "release can be created from a noncanonical target selection"
! grep -q "needs.build.result == 'failure'" "${workflow}" ||
    fail "release job still admits a failed build matrix"
grep -q -- '--clobber' "${workflow}" ||
    fail "existing release assets are not replaced"
grep -q "gh release upload \"\$TAG\"" "${workflow}" ||
    fail "existing release upload path is missing"
grep -q "gh release edit \"\$TAG\"" "${workflow}" ||
    fail "existing release metadata is not refreshed"
grep -q "git/refs/tags/\$TAG" "${workflow}" ||
    fail "release tag ref is not updated"
grep -q 'force=true' "${workflow}" ||
    fail "release tag ref is not force-moved"
! grep -q 'refusing to overwrite' "${workflow}" ||
    fail "workflow still rejects the requested release overwrite"
grep -q 'EXPECTED_RELEASE_TAG' "${workflow}" ||
    fail "release tag is not checked against target metadata"
grep -qx 'EXPECTED_RELEASE_TAG=v0.0.1' "${versions}" ||
    fail "expected replacement release tag is missing"

set +e
usage_output=$("${verifier}" 2>&1)
usage_status=$?
set -e
[[ ${usage_status} -eq 64 ]] ||
    fail "usage exit status was ${usage_status}, expected 64"
grep -q '^Usage:' <<<"${usage_output}" || fail "usage text missing"

set +e
missing_output=$("${verifier}" x86_64-unknown-linux-musl /nonexistent \
    16.2.0 1.2.6 ld-musl-x86_64.so.1 2>&1)
missing_status=$?
set -e
[[ ${missing_status} -ne 0 ]] || fail "missing toolchain unexpectedly passed"
grep -q 'compiler not found' <<<"${missing_output}" ||
    fail "missing compiler diagnostic absent"

echo "verification integration contract: PASS"
