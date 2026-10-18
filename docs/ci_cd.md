# CI and releases

MSL validates pull requests, builds a distributable on main, then publishes that exact artifact through a manual Release workflow. GitHub Releases is the distribution target; this repository has no separate application deployment environment.

## Event paths

| Event | Source validated | Work and output |
|---|---|---|
| Activity-branch push without a PR | None in Actions | Run local checks; activity branches do not trigger push CI. |
| PR opened, synchronized, reopened, edited or marked ready | GitHub's proposed merge commit with the PR target | Host build/tests, native Linux guest tests, static musl guest build, lint and release-tool regression tests. No publishing secrets or release artifacts. |
| PR retargeted | Updated proposed merge commit | `pull_request: edited` starts validation. |
| Target branch receives a commit | The pushed main revision | Main validation runs. GitHub does not automatically refresh every open PR's checks on a base-only push; update the PR branch to obtain a new integration check. |
| Merge queue requests checks | GitHub's `merge_group` SHA | The same source checks. No merge queue is enabled by these workflows. |
| Merge or direct push to main | Exact pushed SHA | All source checks, then version selection, dependency resolution, packaging and isolated installation/startup validation. Stores guest and package artifacts. |
| Manual Release on main | Explicit successful main build run ID | Authorizes and downloads its package artifact, verifies digests and metadata, signs its checksum if configured, publishes it and checks the deployed bytes. No compilation or version changes. |
| Tag creation or release publication | Already validated source/artifact | No extra build workflow is triggered. |

PR concurrency uses the PR number and cancels superseded runs. Main builds use distinct source-SHA groups, so a later push does not cancel the earlier distributable build. Release uses its own serialized group with `cancel-in-progress: false`; active publication is never canceled by PR updates. GitHub may replace an older pending release with a newer pending one; retry the intended run ID explicitly.

The repository's existing merge policy remains unchanged. At inspection it required one approval and squash merging, with an administrator bypass, but no required-status, strict up-to-date or merge-queue rule. The workflows preserve the `Host (Swift)`, `Guest (Rust)`, `Lint` and `Latest dependency package check` names. No path filters prevent these checks from appearing. If pre-merge freshness must be enforced, an owner must configure required checks plus up-to-date branches or a merge queue. A green PR run alone does not establish that its integration is still current at merge time.

## Building the distributable

Main retains source validation even after a successful PR. Squash commits have a different source revision; release versions depend on tags/history; main resolves Latest kernel and extension releases; and debug/native tests differ from optimized/static builds. These inputs are not proven equivalent, so skipping main checks would be unsafe. A direct push receives the same main validation.

The package job starts only after host, guest and lint jobs pass. It fetches full history and tags, chooses the version with `scripts/next-version.py`, and resolves Latest kernel and extension releases once. The versioning scheme is unchanged: conventional breaking changes bump major, `feat:` bumps minor, other changes bump patch, and `VERSION` supplies a floor. There is no version commit or release-trigger loop.

The Linux guest job builds the static binary once. Its same-run artifact records the source revision, digest, lockfile, target configuration and pinned Rust toolchain. The macOS package job verifies these before passing the binary to `scripts/build.sh` through `MSL_GUEST_BINARY`. Native Linux tests and static musl compilation are both retained because their configurations differ. The four Swift products build in one SwiftPM invocation.

Dependency caches accelerate compilation; they are never promoted as release artifacts. Cache keys include architecture, dependency locks and toolchain/configuration inputs. Debug and release Swift caches are separate. PR cache scope does not provide artifacts to Release. Swift uses resolved versions and Cargo uses `--locked`.

The macOS package smoke test installs the actual archive into a temporary prefix, checks signatures, starts the installed CLI and daemon, verifies the embedded version and source revision, checks daemon version information, then stops the daemon. It disables LaunchAgent, IDE and shell-profile changes and uses private MSL state. It does not boot a VM. Run the VM e2e suites locally when runtime behavior changes; hosted package validation does not replace those tests.

The `package` artifact contains the archive, checksum, update channel, build information, corresponding BusyBox/e2fsprogs sources and `manifest.json`. The manifest records the full source revision/tree, build run/attempt, version, toolchains, resolved dependency checksums, signing configuration and every payload digest. GitHub supplies an additional immutable artifact ID and archive digest. Retention is 90 days. A rerun may replace an artifact name with a new immutable artifact ID; Release captures and verifies the selected ID rather than treating a cache or filename as provenance.

## Publishing and retries

After a main build succeeds, select **Actions → Release → Run workflow** on `main`, and enter that MSLd run's ID. The prerelease input retains its existing meaning. From a trusted checkout with GitHub credentials, the equivalent command is:

```console
$ scripts/publish.sh <successful-main-run-id> [--prerelease]
```

Release runs on Linux and does not install Xcode or Rust. Publisher code comes from the dispatch's trusted main checkout, never from the downloaded artifact. It requires the expected workflow, repository, successful main push event, matching source revision/tree and a source reachable from main. Failed, canceled, foreign, PR and manual CI runs cannot supply releases. Missing/expired artifacts or mismatched digests fail closed.

The publisher verifies GitHub's artifact archive digest before unpacking, then verifies every manifest digest and the update channel's version, URL and checksum. It never resolves Latest dependencies again, runs downloaded programs, restamps binaries or rebuilds source. Package code signing stays in the build stage. Optional PGP checksum signing stays in the Release job using `MSL_GPG_KEY` and `MSL_GPG_PRIVATE_KEY`; the tarball remains unchanged. Executables remain ad-hoc signed by default, as described in [Security](../SECURITY.md#known-limitations).

Publication starts as a draft. A retry uploads only missing draft assets and rejects existing assets with different bytes. The release becomes public only after all uploaded asset digests match. A retry of an already published release verifies its assets without overwriting them. A tag pointing to another revision, changed prerelease policy, incomplete public release or attempt to move Latest backwards fails explicitly. If two main builds selected the same next version, publishing one does not authorize overwriting it with the other; build a new artifact with the next version instead.

After publishing, the workflow downloads the released assets and verifies their digests, including `update.json`, and checks the tag's source revision. This validates the distribution endpoint; there is no running server health endpoint in this repository. No production release should be dispatched merely to test workflow changes. Release authorization, failure cases and retries have local regression tests; real promotion can only be verified after the workflow is merged and deliberately used.

## Local checks

```console
$ swift test
$ scripts/test-guest.sh
$ python3 -m unittest discover -s tests -p 'test_*.py' -v
$ actionlint
$ shellcheck -S warning install.sh scripts/*.sh
$ scripts/check-links.py
```

`actionlint` uses `.github/actionlint.yaml` to recognize the existing `xcode-27` runner label. The Python release tools require Python 3.9 or later. Main's package/startup test uses macOS 27 and the released Xcode 27 toolchain; it cannot be replaced by a Linux-only package inspection.
