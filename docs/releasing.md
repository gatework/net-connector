# Releasing net-connector

The release owner publishes the downloaded bytes from one successful **exact commit** of the `Go` workflow. The workflow has read-only repository permissions and creates no tag or GitHub release. Branch pushes and manual runs may produce artifacts after every gate passes; pull requests run checks without packaging.

## Gates and dependency boundary

The runtime matrix is Ubuntu/macOS with the latest Go 1.26 and 1.27 patches. Every cell verifies module checksums and `go mod tidy -diff`, builds both commands (`netman` and `tftp-archive`), enables the installed archive-worker test, then runs shuffled, uncached race tests and vet. `make check` is the shared entry point; `project-checks` retains the installed-worker, PostgreSQL, fuzz and consumer gates in `scripts/ci`. Temporary PostgreSQL integration runs when `initdb` and `pg_ctl` are installed; otherwise the log explicitly reports that skip. This is separate from real network-device evidence.

The runtime and quality jobs use the published go-standards v1.0.2 configuration and tools through `make check`. The quality job adds actionlint v1.7.12 and release-fixture verification through `CHECK_EXTRA=project-quality`. Action versions are pinned to reviewed upstream commit SHAs in the workflow. Packaging and security use the latest Go 1.27 patch; the exact compiler version is recorded in `MANIFEST.json` and checked against every binary's Go build information. Go 1.27-built Darwin binaries require macOS 13 or newer.

All release checks and builds use `GOWORK=off`, read-only module resolution and the selected local toolchain. `scripts/release.py check-modules` rejects every `replace` directive and `v0.0.0` dependency. The module pins published go-expect `v0.6.0`; future dependency changes must also use a compatible published version before packaging.

## Artifact contract

Set the committed `VERSION` to a non-placeholder `vMAJOR.MINOR.PATCH`. From a checkout of the intended SHA:

```sh
make check
python3 scripts/test_release.py -v
python3 scripts/release.py package --sha "$(git rev-parse HEAD)"
python3 scripts/release.py verify --sha "$(git rev-parse HEAD)" --version "$(cat VERSION)"
```

Packaging rejects tracked worktree/index changes and existing output paths. It reads all build inputs from the committed Git tree into a temporary directory, so untracked files and local workspace replacements never enter the build. Submodules and symlinks escaping the source root are rejected. Existing output is never overwritten; use a new directory with `--output` for an independent verification build.

The single CI artifact is named `release-FULL_SHA-RUN_ATTEMPT` and contains eight files:

- Four `net-connector_VERSION_FULL_SHA_OS_ARCH.tar.gz` archives for Linux/Darwin × amd64/arm64. Each includes both commands (`netman` and `tftp-archive`) under `bin/`, README, project license, complete dependency license/notice texts, VERSION and REVISION.
- `net-connector_VERSION_FULL_SHA_source.tar.gz`, containing the exact committed tree under `net-connector/`, preserving executable modes and safe symlinks.
- `REVISION`, `MANIFEST.json` and `SHA256SUMS`.

The manifest records version, SHA, compiler and every platform payload's file sizes, modes and SHA-256 digests. `SHA256SUMS` covers all other files, including the manifest. Tar entries have deterministic ordering, ownership and timestamps; gzip records no local filename and uses a zero timestamp. Go builds use `CGO_ENABLED=0`, `-trimpath`, no build ID and an embedded version/SHA identity. Reproducibility means the same tree and toolchain; changing a compiler patch can change binaries. Verification checks the source bytes and modes against Git, the exact archive/asset file sets, checksums, payload manifests, embedded identity and Go command/platform/toolchain metadata. It does not trust a rewritten checksum list alone.

The package job runs both Linux archive binaries' `--version`, uses the archive's installed worker in its pipe integration test, then tests the extracted source with published dependencies. Fixture tests cross-build all eight platform binaries twice and cover rehashed corruption, missing/extra payloads, wrong identity, dirty source, placeholders, replacements, unsafe links and refusal to overwrite artifacts.

## Manual publication by the release owner

1. Verify the repository identity, current visibility and intended release scope. Preserve its visibility. Commit and push the reviewed source and dependency pin. Wait for a successful `Go` run whose `headSha` is the intended commit and whose matrix, quality and package jobs all passed. A different SHA's green run does not authorize this release.
2. Record the workflow run ID, run attempt and immutable upload-artifact ID. Download **that run's** `release-FULL_SHA-RUN_ATTEMPT` artifact to a fresh directory. Do not build publication bytes locally and do not substitute an artifact from a later run.
3. Check out the same SHA in a clean release checkout and run the verifier against the downloaded directory. Inspect `MANIFEST.json`, source correspondence, dependency notices and the platform archives. Retain the artifact ID and GitHub-reported artifact digest alongside the release evidence.
4. Confirm the intended tag and release do not already exist. Create the tag at the verified full SHA, then create the GitHub release with all eight downloaded files. For example, after filling in the recorded values:

```sh
gh run view "$release_run" --json headSha,conclusion,jobs
gh run download "$release_run" --name "release-$release_sha-$release_attempt" --dir "$release_download"
python3 scripts/release.py verify --sha "$release_sha" --version "$release_version" --output "$release_download"
# Execute only after the owner has reviewed the exact run/artifact and absent tag/release.
git tag "$release_version" "$release_sha"
git push origin "refs/tags/$release_version"
gh release create "$release_version" "$release_download"/* --verify-tag --title "$release_version" --notes-file "$release_notes"
```

5. Read back the remote tag target, release state, all asset names/bytes/checksums and unchanged visibility. Download the release assets to a second fresh directory and run the same verifier. Test installed binaries and an extracted-source consumer independently; record local, CI, consumer and publication evidence separately.

Never force a tag, clobber existing assets or rebuild for an upload retry. If a tag/release already exists, compare its target and assets before deciding how to recover. Artifact retention is 30 days; download and retain the reviewed CI bytes before they expire.

## Reviewed upstream version evidence

Verified from upstream GitHub release/tag APIs on 2026-10-26:

| Component | Version | Pinned commit / source |
| --- | --- | --- |
| checkout | v7.0.1 | [`3d3c42e5aac5ba805825da76410c181273ba90b1`](https://github.com/actions/checkout/releases/tag/v7.0.1) |
| setup-go | v7.0.0 | [`b7ad1dad31e06c5925ef5d2fc7ad053ef454303e`](https://github.com/actions/setup-go/releases/tag/v7.0.0) |
| upload-artifact | v7.0.2 | [`cf430e030ddbb5b0abf93d22962f4752f3646cd9`](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) |
| golangci-lint-action | v9.3.0 | [`ba0d7d2ec06a0ea1cb5fa41b2e4a3ab91d21278a`](https://github.com/golangci/golangci-lint-action/releases/tag/v9.3.0) |
| golangci-lint | v2.15.0 | [Upstream release](https://github.com/golangci/golangci-lint/releases/tag/v2.15.0) |
| actionlint | v1.7.12 | [Upstream release](https://github.com/rhysd/actionlint/releases/tag/v1.7.12) |
| govulncheck | v1.9.0 | [Go module metadata](https://proxy.golang.org/golang.org/x/vuln/@v/v1.9.0.info), origin `e672cbe8fbc8c76e28fcb6db0efd9ce354e0dac5` |
