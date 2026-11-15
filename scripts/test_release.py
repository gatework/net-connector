#!/usr/bin/env python3
"""Exercise release identity, committed source, payload integrity and reproducibility."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('release.py').resolve()
BINS = ('netman', 'tftp-archive')


def command(root, *args):
    return subprocess.run(args, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def fixture(root):
    (root / 'go.mod').write_text('module github.com/gatework/net-connector\n\ngo 1.26.0\n')
    (root / 'VERSION').write_text('v0.1.0\n')
    (root / 'README.md').write_text('release fixture\n')
    (root / 'LICENSE').write_text('fixture license\n')
    (root / 'internal/buildinfo').mkdir(parents=True)
    (root / 'internal/buildinfo/version.go').write_text('package buildinfo\nvar Identity = "net-connector development revision unknown"\n')
    for name in BINS:
        p = root / 'cmd' / name
        p.mkdir(parents=True)
        (p / 'main.go').write_text('package main\nimport("fmt"; "github.com/gatework/net-connector/internal/buildinfo")\nfunc main(){fmt.Println(buildinfo.Identity)}\n')
    (root / 'executable').write_text('#!/bin/sh\nexit 0\n')
    (root / 'executable').chmod(0o755)
    (root / 'readme-link').symlink_to('README.md')
    (root / 'readme-chain').symlink_to('readme-link')
    (root / 'directory-link').symlink_to('internal/buildinfo')
    (root / 'back-link').symlink_to('directory-link/../../README.md')
    (root / 'root-link').symlink_to('.')
    (root / 'safe-repeat').symlink_to('root-link/root-link/README.md')
    for args in [('init', '-q'), ('config', 'user.email', 'fixture@example.invalid'), ('config', 'user.name', 'Fixture'), ('add', '.'), ('commit', '-qm', 'fixture')]:
        result = command(root, 'git', *args)
        if result.returncode:
            raise RuntimeError(result.stderr)
    return command(root, 'git', 'rev-parse', 'HEAD').stdout.strip()


class SourceSymlinkTests(unittest.TestCase):
    def test_component_resolved_escape_rejects_before_output(self):
        with tempfile.TemporaryDirectory(prefix='nc-link-escape-') as temp:
            root = Path(temp) / 'repo'
            root.mkdir()
            fixture(root)
            (root / 'anchor').symlink_to('.')
            (root / 'escape').symlink_to('anchor/../outside')
            command(root, 'git', 'add', '.')
            command(root, 'git', 'commit', '-qm', 'chained escape')
            output = Path(temp) / 'dist'
            result = command(root, 'python3', str(SCRIPT), 'package', '--output', str(output))
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('symlink escapes', result.stderr)
            self.assertFalse(output.exists())

    def test_cycles_and_git_metadata_targets_reject_before_output(self):
        for links, message in [
            ({'a': 'b', 'b': 'a'}, 'symlink cycle'),
            ({'anchor': '.', 'escape': 'anchor/.git/config'}, 'Git metadata'),
            ({'nested': 'internal', 'escape': 'nested/../../outside'}, 'symlink escapes'),
            ({'escape': 'README.md/../README.md'}, 'non-directory'),
            ({'escape': 'missing/../README.md'}, 'untracked'),
            ({'escape': '/outside'}, 'symlink escapes'),
            ({'anchor': '.', 'escape': '/'.join(['anchor'] * 41)}, 'safe resolution limit'),
        ]:
            with self.subTest(links=links), tempfile.TemporaryDirectory(prefix='nc-link-graph-') as temp:
                root = Path(temp) / 'repo'
                root.mkdir()
                fixture(root)
                for name, target in links.items():
                    (root / name).symlink_to(target)
                command(root, 'git', 'add', '.')
                command(root, 'git', 'commit', '-qm', 'unsafe link graph')
                output = Path(temp) / 'dist'
                result = command(root, 'python3', str(SCRIPT), 'package', '--output', str(output))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(message, result.stderr)
                self.assertFalse(output.exists())


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='nc-release-tests-')
        cls.root = Path(cls.temp.name) / 'repo'
        cls.root.mkdir()
        cls.sha = fixture(cls.root)
        cls.dist = Path(cls.temp.name) / 'original'
        cls.built = command(cls.root, 'python3', str(SCRIPT), 'package', '--output', str(cls.dist))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(prefix='nc-release-case-')
        self.addCleanup(self.case.cleanup)
        self.output = Path(self.case.name) / 'dist'

    def release(self, action, *args):
        return command(self.root, 'python3', str(SCRIPT), action, '--output', str(self.output), *args)

    def good_copy(self):
        self.assertEqual(self.built.returncode, 0, self.built.stderr)
        shutil.copytree(self.dist, self.output)

    def rehash(self):
        names = sorted(p.name for p in self.output.iterdir() if p.name != 'SHA256SUMS')
        (self.output / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256((self.output / n).read_bytes()).hexdigest()}  {n}\n' for n in names))

    def rewrite_archive(self, path, mutate):
        with tarfile.open(path, 'r:gz') as archive:
            entries = [(m, archive.extractfile(m).read() if m.isfile() else None) for m in archive]
        entries = mutate(entries)
        with path.open('wb') as output:
            with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as gz:
                with tarfile.open(fileobj=gz, mode='w', format=tarfile.PAX_FORMAT) as archive:
                    for member, content in entries:
                        if content is not None:
                            member.size = len(content)
                        archive.addfile(member, io.BytesIO(content) if content is not None else None)
        self.rehash()

    def test_package_is_reproducible_and_contains_all_platforms(self):
        self.good_copy()
        verified = self.release('verify', '--sha', self.sha, '--version', 'v0.1.0')
        self.assertEqual(verified.returncode, 0, verified.stderr)
        # An untracked build input must never leak into committed-tree releases.
        untracked = self.root / 'cmd/netman/untracked.go'
        untracked.write_text('deliberately invalid Go source')
        self.addCleanup(untracked.unlink)
        second = Path(self.case.name) / 'second'
        built = command(self.root, 'python3', str(SCRIPT), 'package', '--output', str(second))
        self.assertEqual(built.returncode, 0, built.stderr)
        self.assertEqual({p.name: p.read_bytes() for p in self.output.iterdir()}, {p.name: p.read_bytes() for p in second.iterdir()})
        archives = list(self.output.glob('*.tar.gz'))
        self.assertEqual(len(archives), 5)
        for path in archives:
            if '_source.tar.gz' in path.name:
                with tarfile.open(path) as source:
                    self.assertEqual(source.extractfile('net-connector/README.md').read(), b'release fixture\n')
                    self.assertEqual(source.getmember('net-connector/executable').mode, 0o755)
                    self.assertTrue(source.getmember('net-connector/readme-link').issym())
                    self.assertEqual(source.getmember('net-connector/readme-chain').linkname, 'readme-link')
                    self.assertEqual(source.getmember('net-connector/back-link').linkname, 'directory-link/../../README.md')
                    self.assertEqual(source.getmember('net-connector/safe-repeat').linkname, 'root-link/root-link/README.md')
                continue
            with tarfile.open(path) as archive:
                self.assertEqual(set(m.name for m in archive if m.name.startswith('bin/')), {'bin/' + name for name in BINS})
                self.assertEqual(archive.extractfile('VERSION').read(), b'v0.1.0\n')
                self.assertEqual(archive.extractfile('REVISION').read(), (self.sha + '\n').encode())
                self.assertIn(b'Go standard library', archive.extractfile('THIRD_PARTY_NOTICES.txt').read())

    def test_output_is_never_overwritten(self):
        self.good_copy()
        original = (self.output / 'REVISION').read_bytes()
        self.assertNotEqual(self.release('package').returncode, 0)
        self.assertEqual((self.output / 'REVISION').read_bytes(), original)

    def test_missing_extra_and_corrupt_assets_are_rejected(self):
        for mutation in ('missing', 'extra', 'corrupt'):
            with self.subTest(mutation=mutation):
                self.good_copy()
                if mutation == 'missing':
                    (self.output / 'REVISION').unlink()
                elif mutation == 'extra':
                    (self.output / 'extra').write_text('unexpected')
                else:
                    (self.output / 'REVISION').write_text('corrupt')
                self.assertNotEqual(self.release('verify', '--sha', self.sha).returncode, 0)
                shutil.rmtree(self.output)

    def test_wrong_revision_and_version_are_rejected(self):
        self.good_copy()
        for args in [('--sha', '0' * 40), ('--sha', self.sha, '--version', 'v0.2.0')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.release('verify', *args).returncode, 0)
        (self.output / 'REVISION').write_text('0' * 40 + '\n')
        self.rehash()
        self.assertNotEqual(self.release('verify', '--sha', self.sha).returncode, 0)

    def test_rehashed_source_corruption_modes_and_unsafe_symlinks_are_rejected(self):
        for mutation in ('bytes', 'mode', 'link', 'missing', 'extra'):
            with self.subTest(mutation=mutation):
                self.good_copy()
                source = next(self.output.glob('*_source.tar.gz'))
                def mutate(entries):
                    if mutation == 'missing':
                        return [(m, b) for m, b in entries if not m.name.endswith('/README.md')]
                    if mutation == 'extra':
                        member = tarfile.TarInfo('net-connector/untracked')
                        member.mode = 0o644
                        return entries + [(member, b'untracked')]
                    changed = []
                    for member, content in entries:
                        if mutation == 'bytes' and member.name.endswith('/README.md'):
                            content = b'corrupt\n'
                        elif mutation == 'mode' and member.name.endswith('/executable'):
                            member.mode = 0o644
                        elif mutation == 'link' and member.issym():
                            member.linkname = '../../outside'
                        changed.append((member, content))
                    return changed
                self.rewrite_archive(source, mutate)
                self.assertNotEqual(self.release('verify', '--sha', self.sha).returncode, 0)
                shutil.rmtree(self.output)

    def test_rehashed_binary_payload_mismatch_is_rejected(self):
        for mutation in ('missing', 'extra', 'version', 'bytes'):
            with self.subTest(mutation=mutation):
                self.good_copy()
                path = next(self.output.glob('*_linux_amd64.tar.gz'))
                def mutate(entries):
                    if mutation == 'missing':
                        return [(m,b) for m,b in entries if m.name != 'bin/netman']
                    if mutation == 'extra':
                        m = tarfile.TarInfo('bin/unexpected'); m.mode = 0o755
                        return entries + [(m,b'wrong')]
                    return [(m, b'v0.2.0\n' if mutation == 'version' and m.name == 'VERSION' else b'corrupt' if mutation == 'bytes' and m.name == 'bin/netman' else b) for m,b in entries]
                self.rewrite_archive(path, mutate)
                self.assertNotEqual(self.release('verify', '--sha', self.sha).returncode, 0)
                shutil.rmtree(self.output)

    def test_dirty_tracked_source_placeholder_replace_and_unsafe_link_fail_before_output(self):
        for mutation in ('dirty', 'staged', 'placeholder', 'replace', 'link', 'version', 'floor'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); fixture(root)
                if mutation in ('dirty', 'staged'):
                    (root / 'README.md').write_text('dirty')
                    if mutation == 'staged':
                        command(root, 'git', 'add', 'README.md')
                elif mutation == 'placeholder':
                    with (root / 'go.mod').open('a') as out: out.write('require example.invalid/unpublished v0.0.0\n')
                elif mutation == 'replace':
                    with (root / 'go.mod').open('a') as out: out.write('replace example.invalid/local => ../local\n')
                elif mutation == 'version':
                    (root / 'VERSION').write_text('v0.0.0\n')
                elif mutation == 'floor':
                    (root / 'go.mod').write_text('module github.com/gatework/net-connector\n\ngo 1.25.0\n')
                else:
                    (root / 'unsafe-link').symlink_to('../outside')
                if mutation not in ('dirty', 'staged'):
                    command(root, 'git', 'add', '.'); command(root, 'git', 'commit', '-qm', mutation)
                result = command(root, 'python3', str(SCRIPT), 'package', '--output', str(self.output))
                self.assertNotEqual(result.returncode, 0)
                expected = {'dirty': 'dirty tracked', 'staged': 'dirty tracked', 'placeholder': 'unpublished v0.0.0', 'replace': 'replace directives', 'link': 'symlink escapes', 'version': 'non-placeholder', 'floor': 'Go 1.26 floor'}[mutation]
                self.assertIn(expected, result.stderr)
                self.assertFalse(self.output.exists(), result.stderr)

    def test_existing_output_symlink_is_not_followed(self):
        target = Path(self.case.name) / 'target'
        self.output.symlink_to(target, target_is_directory=True)
        result = self.release('package')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())

    def test_binary_identity_and_platform_are_checked_beyond_manifest(self):
        for mutation in ('version', 'revision', 'platform'):
            with self.subTest(mutation=mutation):
                self.good_copy()
                path = next(self.output.glob('*_linux_amd64.tar.gz'))
                with tarfile.open(path) as archive:
                    content = archive.extractfile('bin/netman').read()
                if mutation == 'version':
                    content = content.replace(b'net-connector v0.1.0 revision ', b'net-connector v0.2.0 revision ')
                elif mutation == 'revision':
                    content = content.replace(self.sha.encode(), b'0' * 40)
                else:
                    with tarfile.open(next(self.output.glob('*_darwin_amd64.tar.gz'))) as archive:
                        content = archive.extractfile('bin/netman').read()
                self.rewrite_archive(path, lambda entries: [(m, content if m.name == 'bin/netman' else b) for m,b in entries])
                manifest_path = self.output / 'MANIFEST.json'
                manifest = json.loads(manifest_path.read_text())
                manifest['platforms']['linux_amd64']['bin/netman'].update(sha256=hashlib.sha256(content).hexdigest(), size=len(content))
                manifest_path.write_text(json.dumps(manifest))
                self.rehash()
                result = self.release('verify', '--sha', self.sha)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('binary identity', result.stderr)
                shutil.rmtree(self.output)


if __name__ == '__main__':
    unittest.main()
