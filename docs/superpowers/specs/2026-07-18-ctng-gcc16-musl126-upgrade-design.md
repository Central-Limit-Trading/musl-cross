# crosstool-NG, GCC 16.1, and musl 1.2.6 Upgrade Design

## Goal

Upgrade the `x86_64-unknown-linux-musl` toolchain from crosstool-NG
`1.28.0-3-ga3fef857`, GCC 15.2.0, and musl 1.2.5 to a reproducible
crosstool-NG master snapshot, GCC 16.1.0, and musl 1.2.6. Preserve the
existing C, C++, OpenMP, quadmath, mold, and sanitizer capabilities and keep
the four-container release matrix buildable.

## Current State

- The root repository is on `main` at `c35764af2519b4bb424034dd4f0581005db482a0`.
- The `builder` submodule is pinned to
  `a3fef85781d3cda0b27388916f3287826aeec177`, described as
  `crosstool-ng-1.28.0-3-ga3fef857`.
- `targets/x86_64-unknown-linux-musl/config` selects `CT_GCC_V_15=y`; resolved
  configuration currently yields GCC 15.2.0 and musl 1.2.5.
- `0001-enable-musl-libsanitizer.patch` removes crosstool-NG's musl sanitizer
  gate and adds a GCC 15.2.0-only source patch.
- `0002-linux-kernel-mirror-fallback.patch` adds the kernel.org edge mirror to
  crosstool-NG's download fallback list.
- GitHub Actions builds the target on Amazon Linux 2, Alibaba Cloud Linux 3,
  CentOS 7, and Ubuntu 22.04.

## Upstream Baseline Decision

Pin `builder` to crosstool-NG commit
`27cd8380e72bb1cf3e7cf4a06a9cdbdc57df6f72` from 2026-07-02.

The latest stable crosstool-NG release is 1.28.0, which is older than the
current submodule commit and does not provide GCC 16.1.0 or musl 1.2.6.
The selected master commit includes:

- musl 1.2.6 package metadata and checksums;
- the post-release musl GB18030 `iconv` fix for CVE-2026-6042;
- GCC 16.1.0 package metadata, checksums, and upstream crosstool-NG patches;
- follow-up GCC 16.1 target fixes through the selected commit;
- subsequent crosstool-NG maintenance fixes present as of the pin date.

The submodule must remain pinned to the exact commit. The build must not track
the moving `master` branch at build time.

## Considered Approaches

### 1. Pin current crosstool-NG master snapshot

This is the selected approach. It uses upstream-maintained GCC 16.1.0 and musl
1.2.6 package definitions and minimizes local package backports. The cost is
using an unreleased crosstool-NG snapshot, controlled by the immutable SHA and
the full release matrix.

### 2. Keep the existing crosstool-NG base and backport package commits

This would preserve the current framework while cherry-picking the GCC and
musl package additions. It is rejected because it leaves this repository
responsible for dependency ordering, follow-up fixes, and compatibility with
an older framework while not satisfying the request to upgrade crosstool-NG.

### 3. Follow crosstool-NG master without a fixed SHA

This is rejected because identical root commits could produce different
toolchains over time. Reproducibility requires a submodule commit pin.

## Repository Changes

### `builder`

Move the submodule pointer from `a3fef85781d3cda0b27388916f3287826aeec177`
to `27cd8380e72bb1cf3e7cf4a06a9cdbdc57df6f72`. Do not commit local changes
inside the submodule; project-specific changes remain target patch files in
the root repository.

### `targets/x86_64-unknown-linux-musl/config`

Make version selection explicit:

```text
CT_GCC_V_16=y
CT_MUSL_V_1_2_6=y
```

Remove `CT_GCC_V_15=y`. Update the version-specific Bootlin musl mirror path
from `musl-1.2.5` to `musl-1.2.6` while retaining the official musl release
mirror. Keep the existing architecture, kernel, C++, OpenMP, quadmath,
sanitizer, mold, and root-build selections.

The explicit musl selector prevents a future crosstool-NG default change from
silently changing the libc version. The explicit GCC selector provides the
same guarantee for the compiler.

### `targets/x86_64-unknown-linux-musl/0001-enable-musl-libsanitizer.patch`

Rebase the patch on the selected crosstool-NG commit and reduce it to the
crosstool-NG configuration change that allows `CC_GCC_LIBSANITIZER` with musl.

Delete the part that creates
`packages/gcc/15.2.0/0011-libsanitizer-struct_sock_fprog_sz.patch`. GCC 16.1.0
already includes `<linux/filter.h>` for Linux and defines
`struct_sock_fprog_sz` under `SANITIZER_LINUX`, so carrying the GCC 15 source
patch would be obsolete and would not affect the selected GCC version.

The rebased patch comment must state that GCC 16.1.0 contains the required
source fix and that the local change only removes crosstool-NG's conservative
musl gate for the supported x86_64 target.

### `targets/x86_64-unknown-linux-musl/0002-linux-kernel-mirror-fallback.patch`

Rebase the hunk against the selected crosstool-NG `scripts/functions`. Upstream
now recognizes kernel major version 7 in the same case arm, so the patch
context changes from `[3456].*` to `[34567].*`. Preserve the edge mirror as a
fallback after the CDN URL.

### Build scripts and package prerequisites

The build flow must also support Alibaba Cloud Linux 3. Every consumer image
installs its native GCC/G++ host compiler and `util-linux`; the latter provides
`setarch`, which is required to run the TSan data-race check with ASLR disabled.
Containers run with `seccomp=unconfined` so that `setarch -R` is not blocked by
Docker's default seccomp profile.

Package directly from `/opt/x-tools` with `tar -C` instead of moving the
installed toolchain into the source worktree. This keeps repeated builds and
reused runners from colliding with a stale target directory.

The release metadata fixes the requested replacement tag at `v0.0.1`. After
all four matrix jobs succeed, the release job force-moves that lightweight tag
to the workflow commit, replaces existing assets with `--clobber`, and refreshes
the release title and notes. A missing release is created with the same tag.

Do not add compatibility aliases, alternate version paths, or fallback to GCC
15/musl 1.2.5. A failed GCC 16.1 or musl 1.2.6 build must fail visibly.

## Configuration and Build Flow

The resulting build flow is:

```text
root target config
        |
        v
apply rebased target patches to crosstool-NG 27cd8380
        |
        v
build crosstool-NG
        |
        v
ct-ng olddefconfig
        |
        +--> CT_GCC_VERSION="16.1.0"
        +--> CT_MUSL_VERSION="1.2.6"
        |
        v
build x86_64-unknown-linux-musl toolchain
        |
        v
package and verify release artifact
```

`olddefconfig` is authoritative for version resolution. Merely observing the
target config selectors or package directories is not sufficient evidence.

## Security Treatment

The selected crosstool-NG snapshot includes the musl 1.2.6 GB18030 `iconv`
patch addressing CVE-2026-6042. Verification must confirm that the patch is
present in `packages/musl/1.2.6` and is applied during the build.

CVE-2026-40200 affects musl through 1.2.6 on 32-bit architectures. The only
target in this change is x86_64, so that patch is outside this upgrade's
runtime scope. If a 32-bit target is later added to this repository, its
acceptance criteria must include the three upstream qsort fixes before release.

## Failure Handling

- If either target patch does not apply cleanly to the pinned submodule, rebase
  the patch; do not skip it silently.
- If `olddefconfig` resolves any version other than GCC 16.1.0 and musl 1.2.6,
  stop before the full build.
- If sanitizer libraries are absent or sanitizer binaries do not report the
  expected failures, treat the build as failed even if the compiler itself was
  produced.
- If only some release containers pass, do not publish a partial release under
  the existing all-container release contract.
- Do not fall back to crosstool-NG 1.28.0, GCC 15, or musl 1.2.5.

## Verification Strategy

### Static repository gates

1. Confirm the root worktree and submodule are clean before the upgrade.
2. Confirm the `builder` gitlink equals `27cd8380e72bb1cf3e7cf4a06a9cdbdc57df6f72`.
3. Run both target patches in dry-run mode against a clean submodule checkout.
4. Confirm no target patch creates or modifies `packages/gcc/15.2.0`.
5. Confirm the target config contains `CT_GCC_V_16=y` and
   `CT_MUSL_V_1_2_6=y`, and no longer contains `CT_GCC_V_15=y` or a 1.2.5
   mirror path.

### Resolved configuration gate

Build crosstool-NG from the pinned submodule in an isolated temporary build
directory, run `ct-ng olddefconfig` on the target configuration, and require:

```text
CT_GCC_V_16=y
CT_GCC_VERSION="16.1.0"
CT_MUSL_V_1_2_6=y
CT_MUSL_VERSION="1.2.6"
CT_CC_GCC_LIBSANITIZER=y
```

### Full build matrix

Run the release build for all four supported environments:

- Amazon Linux 2;
- Alibaba Cloud Linux 3;
- CentOS 7;
- Ubuntu 22.04.

Each job must build and package an artifact without falling back to another
compiler or libc version. Preserve `fail-fast: false` so all environments
produce independent evidence.

### Artifact and runtime gates

For every successful artifact:

1. Verify the archive checksum.
2. Extract the archive into an isolated directory.
3. Run `x86_64-unknown-linux-musl-gcc --version` and require `16.1.0`.
4. Inspect or execute the sysroot musl loader and require `Version 1.2.6`.
5. Compile and execute a C hello-world binary statically.
6. Compile and execute a C++ hello-world binary statically.
7. Compile a dynamically linked binary and execute it through the packaged
   `ld-musl-x86_64.so.1` with the packaged sysroot library path.
8. Exercise GB18030-to-UTF-8 conversion through `iconv`, including the
   CVE-2026-6042 regression input, under a timeout.
9. Compile an OpenMP program with `-fopenmp`, run it, and require successful
   parallel execution.
10. Confirm the target `libquadmath` exists, compile a program that calls
   `quadmath_snprintf`, and execute it successfully.
11. Invoke the packaged target mold linker, then compile and execute a program
    with `-fuse-ld=mold`.
12. Confirm `libasan`, `liblsan`, `libubsan`, and `libtsan` exist in the
    installed target runtime.
13. Compile an AddressSanitizer heap-overflow program, execute it through the
    packaged loader, and require a nonzero exit plus an AddressSanitizer error.
14. Compile an UndefinedBehaviorSanitizer signed-overflow program, execute it,
    and require a runtime-error diagnostic.
15. Compile a LeakSanitizer leak program, execute it, and require a leak
    diagnostic.
16. Compile a ThreadSanitizer data-race program, execute it with `setarch -R`,
    and require a data-race diagnostic. A container that cannot disable ASLR
    fails the gate; it does not silently skip TSan.

## Acceptance Criteria

The upgrade is complete only when all of the following are proven:

- `builder` is pinned to
  `27cd8380e72bb1cf3e7cf4a06a9cdbdc57df6f72`.
- The resolved configuration reports GCC 16.1.0 and musl 1.2.6.
- No GCC 15.2.0-specific local source patch remains.
- The musl sanitizer configuration patch applies and sanitizer runtimes work.
- The kernel mirror fallback patch applies to the new crosstool-NG source.
- Amazon Linux 2, Alibaba Cloud Linux 3, CentOS 7, and Ubuntu 22.04 all produce
  valid artifacts.
- Artifact checksum, C, C++, dynamic loading, iconv, OpenMP, quadmath, mold,
  ASan, LSan, UBSan, and TSan gates pass for every release artifact.
- The verified source changes are folded into the current root commit with
  `git commit --amend --no-edit` and pushed to both configured remotes with
  `git push --force-with-lease`; generated build intermediates are kept out of
  the committed source tree.
- Both repositories complete the full matrix before their existing `v0.0.1`
  release tag, assets, title, and notes are replaced.

## Rollback

Rollback means amending the previous `builder` gitlink, target config, two
target patches, build scripts, and workflow behavior back together, then using
`--force-with-lease` so a concurrently updated remote is never overwritten.
The release tag must move with the rolled-back commit and its four artifact
pairs. No generated toolchain or compatibility shim is part of source rollback.
