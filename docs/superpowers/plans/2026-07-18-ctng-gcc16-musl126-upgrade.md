# crosstool-NG, GCC 16.1, and musl 1.2.6 Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce and verify an `x86_64-unknown-linux-musl` toolchain built from pinned crosstool-NG commit `27cd8380e72bb1cf3e7cf4a06a9cdbdc57df6f72`, GCC 16.1.0, and musl 1.2.6.

**Architecture:** Keep upstream source selection in the `builder` submodule and project-specific behavior in root-owned target patches. Add executable source-contract tests and a per-target runtime verifier, then make the existing build path enforce resolved versions, execute the verifier before packaging directly from `/opt/x-tools`, and replace the requested `v0.0.1` release only after the full matrix passes.

**Tech Stack:** Git submodules, Bash, crosstool-NG/Kconfig, GNU patch, Docker, GCC 16.1.0, musl 1.2.6, mold, GitHub Actions.

## Global Constraints

- Pin `builder` exactly to `27cd8380e72bb1cf3e7cf4a06a9cdbdc57df6f72`; never follow a moving branch during builds.
- Resolve exactly `CT_GCC_VERSION="16.1.0"` and `CT_MUSL_VERSION="1.2.6"`.
- Preserve C, C++, OpenMP, quadmath, mold, ASan, LSan, UBSan, and TSan support.
- Remove the GCC 15.2.0-only sanitizer source patch instead of retaining a compatibility path.
- Preserve the kernel.org edge-mirror fallback and rebase it against the upstream `[34567].*` case arm.
- Keep the Amazon Linux 2, Alibaba Cloud Linux 3, CentOS 7, and Ubuntu 22.04 build matrix; do not accept partial release success.
- Do not fall back to crosstool-NG 1.28.0, GCC 15, or musl 1.2.5.
- Do not use or re-index with `codebase-memory-mcp` in this session; force-stop
  any automatically respawned process and use live source commands for discovery.
- Do not create an additional commit. Fold all reviewed changes into the current
  root commit with `git commit --amend --no-edit`, then push `main` to both
  configured remotes with `git push --force-with-lease`.

---

### Task 1: Pin upstream sources and upgrade the target contract

**Files:**
- Create: `tests/test-source-upgrade.sh`
- Create: `targets/x86_64-unknown-linux-musl/versions`
- Modify: `builder` gitlink
- Modify: `targets/x86_64-unknown-linux-musl/config`
- Modify: `targets/x86_64-unknown-linux-musl/0001-enable-musl-libsanitizer.patch`
- Modify: `targets/x86_64-unknown-linux-musl/0002-linux-kernel-mirror-fallback.patch`

**Interfaces:**
- Consumes: the approved design and crosstool-NG commit `27cd8380e72bb1cf3e7cf4a06a9cdbdc57df6f72`.
- Produces: a clean pinned submodule, two patches that dry-run cleanly, explicit selectors, and expected-version metadata for Task 2.

- [ ] **Step 1: Write the failing source-upgrade contract**

Create executable `tests/test-source-upgrade.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
target_dir="${repo_root}/targets/x86_64-unknown-linux-musl"
expected_ctng=27cd8380e72bb1cf3e7cf4a06a9cdbdc57df6f72

fail() { echo "FAIL: $*" >&2; exit 1; }

actual_ctng=$(git -C "${repo_root}/builder" rev-parse HEAD)
[[ "${actual_ctng}" == "${expected_ctng}" ]] ||
    fail "builder is ${actual_ctng}, expected ${expected_ctng}"

grep -qx 'CT_GCC_V_16=y' "${target_dir}/config" || fail "GCC 16 selector missing"
grep -qx 'CT_MUSL_V_1_2_6=y' "${target_dir}/config" || fail "musl 1.2.6 selector missing"
grep -qx 'CT_CC_GCC_LIBSANITIZER=y' "${target_dir}/config" || fail "libsanitizer disabled"
grep -q 'musl-1.2.6' "${target_dir}/config" || fail "musl 1.2.6 mirror missing"
if grep -Eq 'CT_GCC_V_15=y|musl-1\.2\.5' "${target_dir}/config"; then
    fail "stale GCC 15 or musl 1.2.5 selection remains"
fi

# shellcheck disable=SC1090
source "${target_dir}/versions"
[[ "${EXPECTED_GCC_VERSION}" == 16.1.0 ]] || fail "unexpected expected GCC version"
[[ "${EXPECTED_MUSL_VERSION}" == 1.2.6 ]] || fail "unexpected expected musl version"
[[ "${EXPECTED_MUSL_LOADER}" == ld-musl-x86_64.so.1 ]] || fail "unexpected loader"

if grep -q 'packages/gcc/15\.2\.0' "${target_dir}/0001-enable-musl-libsanitizer.patch"; then
    fail "GCC 15.2.0-only sanitizer patch remains"
fi

[[ -f "${repo_root}/builder/packages/gcc/16.1.0/chksum" ]] || fail "GCC 16.1 package missing"
[[ -f "${repo_root}/builder/packages/musl/1.2.6/chksum" ]] || fail "musl 1.2.6 package missing"
grep -lE 'src/locale/iconv\.c|gb18030' \
    "${repo_root}/builder/packages/musl/1.2.6"/*.patch >/dev/null ||
    fail "musl iconv security patch missing"

[[ -z "$(git -C "${repo_root}/builder" status --porcelain)" ]] ||
    fail "builder is not clean"
(
    cd "${repo_root}/builder"
    patch --dry-run -Np1 -i "${target_dir}/0001-enable-musl-libsanitizer.patch"
    patch --dry-run -Np1 -i "${target_dir}/0002-linux-kernel-mirror-fallback.patch"
) >/dev/null

echo "source upgrade contract: PASS"
```

- [ ] **Step 2: Run the test and observe the old-baseline failure**

Run:

```bash
chmod +x tests/test-source-upgrade.sh
./tests/test-source-upgrade.sh
```

Expected: nonzero exit reporting `builder is a3fef857..., expected 27cd8380...`.

- [ ] **Step 3: Pin the submodule**

Run:

```bash
git -C builder fetch origin master
git -C builder checkout 27cd8380e72bb1cf3e7cf4a06a9cdbdc57df6f72
git -C builder status --short
git submodule status builder
```

Expected: detached, clean `builder` at `27cd8380...`; the root gitlink is modified.

- [ ] **Step 4: Replace the GCC 15 sanitizer patch**

Replace `0001-enable-musl-libsanitizer.patch` with:

```diff
Enable GCC libsanitizer for the supported x86_64 musl target.

GCC 16.1 already includes linux/filter.h and defines struct_sock_fprog_sz
for SANITIZER_LINUX, so no GCC source patch is required. Remove only
crosstool-NG's conservative musl gate. uClibc-ng remains disabled.

diff --git a/config/cc/gcc.in b/config/cc/gcc.in
--- a/config/cc/gcc.in
+++ b/config/cc/gcc.in
@@ -328,7 +328,7 @@ config CC_GCC_LIBSANITIZER
     tristate
     prompt "Compile libsanitizer"
     depends on THREADS_NATIVE
-    depends on !LIBC_UCLIBC_NG && !LIBC_MUSL # Currently lacks required headers (like netrom.h)
+    depends on !LIBC_UCLIBC_NG # GCC 16.1 supports libsanitizer with musl on x86_64
     depends on ARCH_SUPPORTS_LIBSANITIZER
     help
       libsanitizer is a library which provides run-time sanitising of either
```

- [ ] **Step 5: Rebase the kernel mirror patch**

Preserve its explanation and use this diff:

```diff
diff --git a/scripts/functions b/scripts/functions
--- a/scripts/functions
+++ b/scripts/functions
@@ -1842,7 +1842,8 @@ CT_Mirrors()
                 # Ignore, this happens before .config is fully evaluated
                 ;;
             [34567].*)
                 echo "https://cdn.kernel.org/pub/linux/kernel/v${version%%.*}.x"
+                echo "https://mirrors.edge.kernel.org/pub/linux/kernel/v${version%%.*}.x"
                 ;;
             2.6.*)
                 echo "https://cdn.kernel.org/pub/linux/kernel/v2.6"
```

- [ ] **Step 6: Lock target versions**

Make the relevant `config` block exactly:

```text
CT_LIBC_MUSL=y
CT_MUSL_V_1_2_6=y
CT_MUSL_MIRRORS="https://fossies.org/linux/misc https://toolchains.bootlin.com/downloads/releases/sources/musl-1.2.6 https://www.musl-libc.org/releases"
CT_CC_LANG_CXX=y
CT_CC_GCC_LIBGOMP=y
CT_CC_GCC_LIBQUADMATH=y
CT_CC_GCC_LIBSANITIZER=y
CT_LINKER_MOLD=y
CT_ALLOW_BUILD_AS_ROOT=y
CT_ALLOW_BUILD_AS_ROOT_SURE=y
CT_GCC_V_16=y
```

Create `versions`:

```bash
EXPECTED_GCC_VERSION=16.1.0
EXPECTED_MUSL_VERSION=1.2.6
EXPECTED_MUSL_LOADER=ld-musl-x86_64.so.1
EXPECTED_RELEASE_TAG=v0.0.1
```

- [ ] **Step 7: Verify Task 1 before amending**

Run:

```bash
bash -n tests/test-source-upgrade.sh
./tests/test-source-upgrade.sh
git diff --check
```

Expected: `source upgrade contract: PASS`, a clean `builder` submodule, and the
reviewed root upgrade diff ready to amend.

---

### Task 2: Enforce resolved versions and runtime capabilities

**Files:**
- Create: `tests/test-verification-contract.sh`
- Create: `scripts/verify-toolchain.sh`
- Modify: `scripts/make`
- Modify: `scripts/build-with-docker.sh`

**Interfaces:**
- Consumes: the three `EXPECTED_*` variables from Task 1.
- Produces: `verify-toolchain.sh <target> <toolchain-dir> <gcc-version> <musl-version> <loader-name>`, resolved-config assertions, runtime tests, and checksum checks.

- [ ] **Step 1: Write the failing verification contract**

Create executable `tests/test-verification-contract.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x "${repo_root}/scripts/verify-toolchain.sh" ]] || fail "runtime verifier is not executable"
bash -n "${repo_root}/scripts/verify-toolchain.sh"
bash -n "${repo_root}/scripts/make"
bash -n "${repo_root}/scripts/build-with-docker.sh"
grep -q 'EXPECTED_VERSIONS_FILE=' "${repo_root}/scripts/make" || fail "metadata is not loaded"
grep -q 'CT_GCC_VERSION=' "${repo_root}/scripts/make" || fail "GCC version is not asserted"
grep -q 'CT_MUSL_VERSION=' "${repo_root}/scripts/make" || fail "musl version is not asserted"
grep -q 'verify-toolchain.sh' "${repo_root}/scripts/make" || fail "runtime verifier is not invoked"
grep -q 'Checksum verification passed' "${repo_root}/scripts/build-with-docker.sh" || fail "checksum gate missing"

set +e
usage_output=$("${repo_root}/scripts/verify-toolchain.sh" 2>&1)
usage_status=$?
set -e
[[ ${usage_status} -eq 64 ]] || fail "usage exit was ${usage_status}"
grep -q '^Usage:' <<<"${usage_output}" || fail "usage text missing"

set +e
missing_output=$("${repo_root}/scripts/verify-toolchain.sh" \
    x86_64-unknown-linux-musl /nonexistent 16.1.0 1.2.6 ld-musl-x86_64.so.1 2>&1)
missing_status=$?
set -e
[[ ${missing_status} -ne 0 ]] || fail "missing toolchain passed"
grep -q 'compiler not found' <<<"${missing_output}" || fail "missing compiler diagnostic absent"
echo "verification integration contract: PASS"
```

- [ ] **Step 2: Run it and observe failure**

Run `bash tests/test-verification-contract.sh`.

Expected: nonzero exit with `runtime verifier is not executable`.

- [ ] **Step 3: Add the runtime verifier**

Create executable `scripts/verify-toolchain.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <target> <toolchain-dir> <gcc-version> <musl-version> <loader-name>" >&2
    exit 64
}
[[ $# -eq 5 ]] || usage

target=$1; toolchain_dir=$2; expected_gcc=$3; expected_musl=$4; loader_name=$5
cc="${toolchain_dir}/bin/${target}-gcc"
cxx="${toolchain_dir}/bin/${target}-g++"
mold="${toolchain_dir}/${target}/bin/ld.mold"
[[ -x "${cc}" ]] || { echo "compiler not found: ${cc}" >&2; exit 1; }
[[ -x "${cxx}" ]] || { echo "C++ compiler not found: ${cxx}" >&2; exit 1; }
[[ -x "${mold}" ]] || { echo "mold linker not found: ${mold}" >&2; exit 1; }

actual_gcc=$("${cc}" -dumpfullversion)
[[ "${actual_gcc}" == "${expected_gcc}" ]] || {
    echo "GCC version mismatch: ${actual_gcc} != ${expected_gcc}" >&2; exit 1;
}
sysroot=$("${cc}" -print-sysroot)
loader="${sysroot}/lib/${loader_name}"
[[ -x "${loader}" ]] || { echo "musl loader not found: ${loader}" >&2; exit 1; }
loader_output=$("${loader}" 2>&1 || true)
grep -Fq "Version ${expected_musl}" <<<"${loader_output}" || {
    echo "musl version mismatch: ${loader_output}" >&2; exit 1;
}

verify_tmp=$(mktemp -d "${TMPDIR:-/tmp}/musl-cross-verify.XXXXXX")
cleanup() { rm -rf -- "${verify_tmp}"; }
trap cleanup EXIT

runtime_dirs=("${sysroot}/lib" "${sysroot}/usr/lib")
for runtime in libasan.so liblsan.so libubsan.so libtsan.so libgcc_s.so.1 \
               libgomp.so.1 libquadmath.so.0; do
    runtime_path=$("${cc}" -print-file-name="${runtime}")
    [[ "${runtime_path}" != "${runtime}" && -f "${runtime_path}" ]] || {
        echo "target runtime not found: ${runtime}" >&2; exit 1;
    }
    runtime_dirs+=("$(dirname "${runtime_path}")")
done
runtime_library_path=$(IFS=:; echo "${runtime_dirs[*]}")
run_dynamic() { "${loader}" --library-path "${runtime_library_path}" "$@"; }

expect_failure() {
    local name=$1 pattern=$2 program=$3 output status
    set +e; output=$(run_dynamic "${program}" 2>&1); status=$?; set -e
    [[ ${status} -ne 0 ]] || { echo "${name} unexpectedly succeeded" >&2; exit 1; }
    grep -Eq "${pattern}" <<<"${output}" || {
        echo "${name} diagnostic missing: ${output}" >&2; exit 1;
    }
}

cat >"${verify_tmp}/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("C PASS"); return 0; }
EOF
"${cc}" -static "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-c"
[[ "$("${verify_tmp}/hello-c")" == "C PASS" ]]
cat >"${verify_tmp}/hello.cc" <<'EOF'
#include <iostream>
int main() { std::cout << "C++ PASS\n"; }
EOF
"${cxx}" -static "${verify_tmp}/hello.cc" -o "${verify_tmp}/hello-cxx"
[[ "$("${verify_tmp}/hello-cxx")" == "C++ PASS" ]]
"${cc}" "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-dynamic"
[[ "$(run_dynamic "${verify_tmp}/hello-dynamic")" == "C PASS" ]]

cat >"${verify_tmp}/openmp.c" <<'EOF'
#include <omp.h>
#include <stdio.h>
int main(void) { int n=0;
#pragma omp parallel reduction(+:n) num_threads(2)
n += 1; printf("%d\n", n); return n == 2 ? 0 : 1; }
EOF
"${cc}" -fopenmp "${verify_tmp}/openmp.c" -o "${verify_tmp}/openmp"
[[ "$(run_dynamic "${verify_tmp}/openmp")" == 2 ]]

cat >"${verify_tmp}/quadmath.c" <<'EOF'
#include <quadmath.h>
#include <stdio.h>
int main(void) { char s[32]; quadmath_snprintf(s,sizeof s,"%.2Qf",(__float128)1.25); puts(s); }
EOF
"${cc}" "${verify_tmp}/quadmath.c" -lquadmath -o "${verify_tmp}/quadmath"
[[ "$(run_dynamic "${verify_tmp}/quadmath")" == 1.25 ]]
"${mold}" --version | grep -qi mold
"${cc}" -static -fuse-ld=mold "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-mold"
[[ "$("${verify_tmp}/hello-mold")" == "C PASS" ]]

cat >"${verify_tmp}/asan.c" <<'EOF'
#include <stdlib.h>
int main(void) { char *p=malloc(4); p[8]=1; return p[8]; }
EOF
"${cc}" -O0 -g -fsanitize=address -fno-omit-frame-pointer "${verify_tmp}/asan.c" -o "${verify_tmp}/asan"
expect_failure ASan AddressSanitizer "${verify_tmp}/asan"
cat >"${verify_tmp}/ubsan.c" <<'EOF'
#include <limits.h>
int main(void) { volatile int v=INT_MAX; return v+1; }
EOF
"${cc}" -O0 -g -fsanitize=undefined -fno-sanitize-recover=undefined "${verify_tmp}/ubsan.c" -o "${verify_tmp}/ubsan"
expect_failure UBSan 'runtime error|signed integer overflow' "${verify_tmp}/ubsan"
cat >"${verify_tmp}/lsan.c" <<'EOF'
#include <stdlib.h>
int main(void) { malloc(128); return 0; }
EOF
"${cc}" -O0 -g -fsanitize=leak "${verify_tmp}/lsan.c" -o "${verify_tmp}/lsan"
expect_failure LSan 'LeakSanitizer|detected memory leaks' "${verify_tmp}/lsan"
cat >"${verify_tmp}/tsan.c" <<'EOF'
#include <pthread.h>
static int shared;
static void *write_shared(void *p) { (void)p; shared++; return 0; }
int main(void) { pthread_t t; pthread_create(&t,0,write_shared,0); shared++; pthread_join(t,0); }
EOF
"${cc}" -O0 -g -fsanitize=thread -pthread "${verify_tmp}/tsan.c" -o "${verify_tmp}/tsan"
expect_failure TSan 'ThreadSanitizer: data race|WARNING: ThreadSanitizer' "${verify_tmp}/tsan"
echo "toolchain runtime verification: PASS"
```

- [ ] **Step 4: Integrate metadata, resolved-version checks, and runtime checks**

In `scripts/make`, load `targets/${TARGET}/versions` after argument parsing:

```bash
EXPECTED_GCC_VERSION=""; EXPECTED_MUSL_VERSION=""; EXPECTED_MUSL_LOADER=""
EXPECTED_VERSIONS_FILE="${PROJECT_ROOT}/targets/${TARGET}/versions"
if [ -f "${EXPECTED_VERSIONS_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${EXPECTED_VERSIONS_FILE}"
fi
```

Immediately after `ct-ng olddefconfig`, require exact resolved lines:

```bash
if [ -n "${EXPECTED_GCC_VERSION}" ]; then
    if ! grep -qx "CT_GCC_VERSION=\"${EXPECTED_GCC_VERSION}\"" .config; then
        echo "Error: resolved GCC version does not equal ${EXPECTED_GCC_VERSION}" >&2
        grep '^CT_GCC_VERSION=' .config >&2 || true
        exit 1
    fi
fi
if [ -n "${EXPECTED_MUSL_VERSION}" ]; then
    if ! grep -qx "CT_MUSL_VERSION=\"${EXPECTED_MUSL_VERSION}\"" .config; then
        echo "Error: resolved musl version does not equal ${EXPECTED_MUSL_VERSION}" >&2
        grep '^CT_MUSL_VERSION=' .config >&2 || true
        exit 1
    fi
fi
```

Immediately after `ct-ng build`, reject incomplete metadata and invoke the verifier only for targets that declare the complete metadata contract:

```bash
if [ -n "${EXPECTED_GCC_VERSION}${EXPECTED_MUSL_VERSION}${EXPECTED_MUSL_LOADER}" ]; then
    if [ -z "${EXPECTED_GCC_VERSION}" ] || [ -z "${EXPECTED_MUSL_VERSION}" ] || \
       [ -z "${EXPECTED_MUSL_LOADER}" ]; then
        echo "Error: incomplete target version metadata in ${EXPECTED_VERSIONS_FILE}" >&2
        exit 1
    fi
    "${PROJECT_ROOT}/scripts/verify-toolchain.sh" "${TARGET}" \
      "/opt/x-tools/${TARGET}" "${EXPECTED_GCC_VERSION}" \
      "${EXPECTED_MUSL_VERSION}" "${EXPECTED_MUSL_LOADER}"
fi
```

After creating the tarball checksum, recompute and compare it. In `build-with-docker.sh`, do the same after renaming and print `Checksum verification passed` only on equality:

```bash
actual_hash=\$(sha256sum "${TARGET}-${OS_LABEL}.tar.xz" | awk '{print \$1}')
expected_hash=\$(cat "${TARGET}-${OS_LABEL}.tar.xz.sha256")
[ "\${actual_hash}" = "\${expected_hash}" ] || exit 1
echo 'Checksum verification passed'
```

Archive from the installation root without first moving the toolchain into the
worktree:

```bash
tar -C /opt/x-tools -cJvf "${PROJECT_ROOT}/${TARGET}.tar.xz" "${TARGET}"
```

- [ ] **Step 5: Verify Task 2 before amending**

Run:

```bash
chmod +x scripts/verify-toolchain.sh tests/test-verification-contract.sh
bash -n scripts/verify-toolchain.sh scripts/make scripts/build-with-docker.sh
./tests/test-verification-contract.sh
./tests/test-source-upgrade.sh
git diff --check
```

Expected: both contracts pass and all intended changes are ready to amend.

---

### Task 3: Build and verify all release environments

**Files:**
- Verify: `build/.config`
- Verify: `x86_64-unknown-linux-musl-amazonlinux2.tar.xz`
- Verify: `x86_64-unknown-linux-musl-alinux3.tar.xz`
- Verify: `x86_64-unknown-linux-musl-centos7.tar.xz`
- Verify: `x86_64-unknown-linux-musl-ubuntu22.tar.xz`
- Verify: the matching four `.sha256` files

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces: four independent logs and artifact pairs proving exact versions and runtime capabilities.

- [ ] **Step 1: Confirm a clean Docker baseline**

Create the external evidence directory and confirm a clean baseline:

```bash
evidence_dir=/root/musl-cross-artifacts/2026-07-18-gcc16-musl126
mkdir -p "${evidence_dir}"
docker version
git status --short
test ! -e x86_64-unknown-linux-musl
```

Expected: Docker client/server available, the intended source diff ready for
review, and no packaging collision.

- [ ] **Step 2: Build Amazon Linux 2**

```bash
./scripts/build-with-docker.sh x86_64-unknown-linux-musl \
  public.ecr.aws/amazonlinux/amazonlinux:2 amazonlinux2
```

Expected: the log contains `toolchain runtime verification: PASS` and `Checksum verification passed`. Move the artifact pair to `${evidence_dir}`, remove only the generated extracted target directory and `build/`, and restore `builder` to its pinned clean state.

- [ ] **Step 3: Build Alibaba Cloud Linux 3**

```bash
./scripts/build-with-docker.sh x86_64-unknown-linux-musl \
  alibaba-cloud-linux-3-registry.cn-hangzhou.cr.aliyuncs.com/alinux3/alinux3:latest alinux3
```

Expected: identical gates pass with the Alibaba Linux module repository
enabled. Move the artifact pair to `${evidence_dir}`, remove only generated
outputs, and restore `builder` to its pinned clean state.

- [ ] **Step 4: Build CentOS 7**

```bash
./scripts/build-with-docker.sh x86_64-unknown-linux-musl centos:7.9.2009 centos7
```

Expected: identical gates pass under devtoolset-11. Move the artifact pair to `${evidence_dir}`, remove only the generated extracted target directory and `build/`, and restore `builder` to its pinned clean state.

- [ ] **Step 5: Build Ubuntu 22.04**

```bash
./scripts/build-with-docker.sh x86_64-unknown-linux-musl ubuntu:22.04 ubuntu22
```

Expected: identical gates pass under Ubuntu 22.04. Move the artifact pair to `${evidence_dir}`, remove only the generated extracted target directory and `build/`, and restore `builder` to its pinned clean state.

- [ ] **Step 6: Independently audit artifacts**

Audit the four explicitly named artifacts in isolated temporary directories:

```bash
evidence_dir=/root/musl-cross-artifacts/2026-07-18-gcc16-musl126
for os_label in amazonlinux2 alinux3 centos7 ubuntu22; do
    artifact="${evidence_dir}/x86_64-unknown-linux-musl-${os_label}.tar.xz"
    actual=$(sha256sum "${artifact}" | awk '{print $1}')
    expected=$(cat "${artifact}.sha256")
    test "${actual}" = "${expected}"
    audit_dir=$(mktemp -d "/tmp/musl-cross-${os_label}-audit.XXXXXX")
    tar -xJf "${artifact}" -C "${audit_dir}"
    "${audit_dir}/x86_64-unknown-linux-musl/bin/x86_64-unknown-linux-musl-gcc" \
        -dumpfullversion | grep -qx '16.1.0'
    loader="${audit_dir}/x86_64-unknown-linux-musl/x86_64-unknown-linux-musl/sysroot/lib/ld-musl-x86_64.so.1"
    ("${loader}" 2>&1 || true) | grep -Fq 'Version 1.2.6'
    rm -rf -- "${audit_dir}"
done
```

Expected: every hash matches, compiler output is `16.1.0`, loader output contains `Version 1.2.6`.

If a gate fails, invoke `superpowers:systematic-debugging`, add a regression assertion, implement the minimal root-cause fix, and repeat that environment before continuing.

---

### Task 4: Complete the acceptance audit without codebase-memory

**Files:**
- Verify: all Task 1-2 changes and both planning documents

**Interfaces:**
- Consumes: the reviewed source diff, tests, logs, and four artifact pairs.
- Produces: live-source and requirement-by-requirement completion evidence.

- [ ] **Step 1: Restore a clean builder and remove generated intermediates**

Reverse only the two known target patches after all builds have stopped, remove
generated build outputs, and then run:

```bash
patch --fuzz=0 --dry-run -R -d builder -Np1 \
  -i targets/x86_64-unknown-linux-musl/0002-linux-kernel-mirror-fallback.patch
patch --fuzz=0 --dry-run -R -d builder -Np1 \
  -i targets/x86_64-unknown-linux-musl/0001-enable-musl-libsanitizer.patch
# Apply the same two exact reverse operations only after both dry-runs pass.
git -C builder status --short
git status --short
```

Expected: `builder` is clean; the root repository contains only the intended
source changes ready to amend and no generated build directory.

- [ ] **Step 2: Verify live source selections**

```bash
rg -n 'CT_GCC_V_16|CT_MUSL_V_1_2_6|16\.1\.0|1\.2\.6' \
  targets/x86_64-unknown-linux-musl scripts tests
! rg -n 'CT_GCC_V_15=y|musl-1\.2\.5|packages/gcc/15\.2\.0' \
  targets/x86_64-unknown-linux-musl
./tests/test-source-upgrade.sh
./tests/test-verification-contract.sh
git diff --check
```

Expected: desired versions only, both contracts pass, clean whitespace.

- [ ] **Step 3: Audit every acceptance criterion**

Use this exact evidence map:

```text
builder SHA                         -> git submodule status
resolved GCC/musl versions          -> captured build log and build/.config
no GCC 15 sanitizer source patch    -> test-source-upgrade.sh and rg
rebased sanitizer/kernel patches    -> patch --dry-run
four container builds               -> four logs and artifact pairs
artifact integrity                  -> four hash comparisons
C/C++/dynamic/OpenMP/quadmath/mold  -> verifier PASS in every log
ASan/LSan/UBSan/TSan                -> verifier PASS in every log
clean builder and intended root diff -> git status --short
```

Do not claim completion if any item lacks direct evidence.

- [ ] **Step 4: Amend the current commit and push both remotes**

Run:

```bash
git diff --cached --check
git commit --amend --no-edit
git push --force-with-lease origin main
git push --force-with-lease origin1 main
```

Expected: both remote `main` refs equal the amended root HEAD; no unrelated
commit is created and a concurrent remote update would make the lease fail.

- [ ] **Step 5: Run and monitor the full release workflow in both repositories**

Dispatch `Release` on `main` with the canonical target, `containers=all`,
`create_release=true`, and `release_tag=v0.0.1`. Watch both runs to completion.
If either fails, use the failing job log to add a regression assertion, apply
the minimal fix, repeat the amend/dual-push sequence, and rerun both workflows.

Expected: both workflows succeed, both `v0.0.1` tag refs equal the amended
commit, and each release contains the four archives plus four checksum files.
