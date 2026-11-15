#!/usr/bin/env python3
"""从已提交的 Git 源码生成并校验不可变发布文件；不执行发布。"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import tempfile

BINS = ('netman', 'tftp-archive')
PLATFORMS = ('darwin_amd64', 'darwin_arm64', 'linux_amd64', 'linux_arm64')
MODULE = 'github.com/gatework/net-connector'
SEMVER = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z')


def run(root, *args, env=None):
    return subprocess.run(args, cwd=root, env=env, stdout=subprocess.PIPE, check=True).stdout


def git(root, *args):
    return run(root, 'git', *args).decode().strip()


def go_env():
    env = os.environ.copy()
    env.update(GOWORK='off', GOFLAGS='-mod=readonly', GOTOOLCHAIN='local', CGO_ENABLED='0', GOENV='off', GOEXPERIMENT='', GOAMD64='v1', GOARM64='v8.0')
    # Never inherit a caller's cross-compile target into host tools or dependency discovery.
    env.pop('GOOS', None)
    env.pop('GOARCH', None)
    return env


def go(root, *args):
    return run(root, 'go', *args, env=go_env())


def version_at(root, sha):
    version = git(root, 'show', sha + ':VERSION')
    if not SEMVER.fullmatch(version) or version == 'v0.0.0':
        raise ValueError('VERSION must contain a non-placeholder vMAJOR.MINOR.PATCH')
    return version


def identity(root, sha, version=None):
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('expected a full commit SHA')
    actual = version_at(root, sha)
    if version is not None and actual != version:
        raise ValueError('version does not match the committed VERSION')
    return actual


def check_modules(root):
    mod = json.loads(go(root, 'mod', 'edit', '-json'))
    if mod.get('Replace'):
        raise ValueError('release rejects all replace directives')
    if any(m['Version'] == 'v0.0.0' for m in (mod.get('Require') or [])):
        raise ValueError('release rejects unpublished v0.0.0 dependencies')
    if tuple(map(int, mod['Go'].split('.')[:2])) < (1, 26):
        raise ValueError('module must declare the Go 1.26 floor or newer')
    if mod['Module']['Path'] != MODULE:
        raise ValueError('unexpected module path')


def source_tree(root, sha):
    entries = {}
    for record in run(root, 'git', 'ls-tree', '-rz', '--full-tree', sha).split(b'\0'):
        if not record:
            continue
        metadata, raw_name = record.split(b'\t', 1)
        mode, kind, oid = metadata.decode().split()
        name = raw_name.decode('utf-8')
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or str(path) != name or '.git' in path.parts:
            raise ValueError('unsafe tracked source path')
        if kind != 'blob' or mode not in ('100644', '100755', '120000'):
            raise ValueError('source requires ordinary files or safe symlinks, without submodules')
        content = run(root, 'git', 'cat-file', 'blob', oid)
        entries[name] = (int(mode[-3:], 8) if mode != '120000' else 0o777, content, mode == '120000')
    validate_symlinks(entries)
    return entries


def validate_symlinks(entries):
    """Resolve the complete committed link graph in filesystem component order."""
    directories = {''}
    for name in entries:
        parts = name.split('/')
        directories.update('/'.join(parts[:n]) for n in range(1, len(parts)))

    def resolve(parts, base, active, remaining):
        resolved = list(base)
        for index, component in enumerate(parts):
            if component in ('', '.'):
                continue
            if component == '..':
                if not resolved:
                    raise ValueError('source symlink escapes the archive')
                resolved.pop()
            elif component == '.git':
                raise ValueError('source symlink refers to Git metadata')
            else:
                name = '/'.join((*resolved, component))
                entry = entries.get(name)
                if entry is not None and entry[2]:
                    if name in active:
                        raise ValueError('source symlink cycle')
                    if remaining[0] == 0:
                        raise ValueError('source symlink chain exceeds safe resolution limit')
                    remaining[0] -= 1
                    target = entry[1].decode('utf-8')
                    if not target or target.startswith('/'):
                        raise ValueError('source symlink escapes the archive or has an empty target')
                    resolved = resolve(target.split('/'), resolved, active | {name}, remaining)
                else:
                    resolved.append(component)
            if index < len(parts) - 1 and '/'.join(resolved) not in directories:
                raise ValueError('source symlink crosses an untracked or non-directory component')
        return resolved

    for name, (_, _, symlink) in entries.items():
        if symlink:
            resolve(name.split('/'), [], set(), [40])


def archive_bytes(entries):
    output = io.BytesIO()
    with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w', format=tarfile.PAX_FORMAT) as archive:
            for name, (mode, content, symlink) in sorted(entries.items()):
                member = tarfile.TarInfo(name)
                member.mode = mode
                if symlink:
                    member.type = tarfile.SYMTYPE
                    member.linkname = content.decode('utf-8')
                else:
                    member.size = len(content)
                archive.addfile(member, None if symlink else io.BytesIO(content))
    return output.getvalue()


def read_archive(path):
    entries = {}
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or str(path) != member.name or member.name in entries:
                raise ValueError('unsafe or duplicate archive member')
            if member.uid != 0 or member.gid != 0 or member.mtime != 0 or member.uname or member.gname:
                raise ValueError('archive metadata is not canonical')
            if member.isfile():
                content = archive.extractfile(member).read()
            elif member.issym():
                content = member.linkname.encode('utf-8')
            else:
                raise ValueError('archive contains an unexpected file type')
            entries[member.name] = (member.mode, content, member.issym())
    return entries


def materialize(entries, root):
    # Git trees cannot have symlink parents; validated targets stay within this fresh tree.
    for name, (mode, content, symlink) in entries.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if symlink:
            path.symlink_to(content.decode('utf-8'))
        else:
            path.write_bytes(content)
            path.chmod(mode)


def json_stream(raw):
    text = raw.decode()
    decoder = json.JSONDecoder()
    while text.strip():
        item, end = decoder.raw_decode(text.lstrip())
        yield item
        text = text.lstrip()[end:]


def third_party_notices(root):
    lines = ['Third-party notices for net-connector\n\n']
    goroot = Path(go(root, 'env', 'GOROOT').decode().strip())
    lines.append('Go standard library (' + go(root, 'env', 'GOVERSION').decode().strip() + ')\n')
    for name in ('LICENSE', 'PATENTS'):
        if (goroot / name).is_file():
            lines.append('\n' + name + '\n' + (goroot / name).read_text())
    for module in sorted(json_stream(go(root, 'list', '-m', '-json', 'all')), key=lambda m: m['Path']):
        if module.get('Main'):
            continue
        if module.get('Replace') or module['Version'] == 'v0.0.0':
            raise ValueError('resolved module is replaced or unpublished')
        downloaded = json.loads(go(root, 'mod', 'download', '-json', module['Path'] + '@' + module['Version']))
        directory = Path(downloaded['Dir'])
        notices = sorted(p for p in directory.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'PATENTS')))
        if not any(p.name.upper().startswith(('LICENSE', 'COPYING')) for p in notices):
            raise ValueError('missing license for ' + module['Path'])
        lines.append('\n\n' + module['Path'] + ' ' + module['Version'] + '\n')
        for path in notices:
            lines.append('\n' + path.name + '\n' + path.read_text())
    return ''.join(lines).encode()


def asset_names(version, sha):
    prefix = 'net-connector_' + version + '_' + sha + '_'
    return {platform: prefix + platform + '.tar.gz' for platform in (*PLATFORMS, 'source')}


def checksum_text(directory):
    return ''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n'
                   for path in sorted(directory.iterdir()) if path.name != 'SHA256SUMS')


def payload_manifest(entries):
    return {name: {'sha256': hashlib.sha256(content).hexdigest(), 'mode': mode, 'size': len(content)}
            for name, (mode, content, _) in sorted(entries.items())}


def package(root, directory, sha):
    version = identity(root, sha)
    if git(root, 'rev-parse', 'HEAD') != sha:
        raise ValueError('package requires the checked-out commit')
    if run(root, 'git', 'status', '--porcelain', '--untracked-files=no'):
        raise ValueError('package rejects dirty tracked source and index')
    if directory.exists() or directory.is_symlink():
        raise ValueError('output already exists; never overwrite a release artifact')
    tree = source_tree(root, sha)
    names = asset_names(version, sha)
    manifest = {'schema': 1, 'version': version, 'revision': sha, 'toolchain': go(root, 'env', 'GOVERSION').decode().strip(), 'platforms': {}}
    with tempfile.TemporaryDirectory(prefix='net-connector-release-') as temp:
        source = Path(temp) / 'source'
        source.mkdir()
        materialize(tree, source)
        check_modules(source)
        go(source, 'mod', 'verify')
        notices = third_party_notices(source)
        # Explicit downloads must not fill missing checksums behind read-only builds.
        for module_file in ('go.mod', 'go.sum'):
            path = source / module_file
            expected = tree.get(module_file)
            if (path.exists() and (expected is None or path.read_bytes() != expected[1])) or (expected is not None and not path.exists()):
                raise ValueError('module resolution changed committed build inputs; run tidy before packaging')
        staged = Path(temp) / 'dist'
        staged.mkdir()
        (staged / names['source']).write_bytes(archive_bytes({'net-connector/' + name: value for name, value in tree.items()}))
        for platform, name in ((p, names[p]) for p in PLATFORMS):
            env = go_env()
            env.update(zip(('GOOS', 'GOARCH'), platform.split('_')))
            entries = {n: (0o644, data, False) for n, data in {
                'README.md': tree['README.md'][1], 'LICENSE': tree['LICENSE'][1],
                'VERSION': (version + '\n').encode(), 'REVISION': (sha + '\n').encode(),
                'THIRD_PARTY_NOTICES.txt': notices}.items()}
            for binary in BINS:
                output = Path(temp) / binary
                flags = "-s -w -buildid= -X '" + MODULE + "/internal/buildinfo.Identity=" + binary_identity(version, sha) + "'"
                run(source, 'go', 'build', '-trimpath', '-buildvcs=false', '-ldflags=' + flags, '-o', str(output), './cmd/' + binary, env=env)
                entries['bin/' + binary] = (0o755, output.read_bytes(), False)
            manifest['platforms'][platform] = payload_manifest(entries)
            (staged / name).write_bytes(archive_bytes(entries))
        (staged / 'REVISION').write_text(sha + '\n')
        (staged / 'MANIFEST.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        (staged / 'SHA256SUMS').write_text(checksum_text(staged))
        verify(root, staged, sha, version)
        # Reserve only after every build and verification succeeded; never merge into existing output.
        directory.mkdir(parents=True, exist_ok=False)
        for path in staged.iterdir():
            (directory / path.name).write_bytes(path.read_bytes())


def binary_identity(version, sha):
    return 'net-connector ' + version + ' revision ' + sha


def verify_binary(root, content, platform, binary, version, sha, toolchain):
    with tempfile.TemporaryDirectory(prefix='nc-verify-binary-') as temp:
        path = Path(temp) / binary
        path.write_bytes(content)
        info = go(root, 'version', '-m', str(path)).decode()
    settings = {}
    for line in info.splitlines()[1:]:
        fields = line.strip().split('\t', 1)
        if len(fields) == 2 and fields[0] == 'build' and '=' in fields[1]:
            key, value = fields[1].split('=', 1)
            settings[key] = value
    os_name, arch = platform.split('_')
    if (not info.splitlines()[0].endswith(': ' + toolchain) or
            '\tpath\t' + MODULE + '/cmd/' + binary + '\n' not in info or
            settings.get('GOOS') != os_name or settings.get('GOARCH') != arch or
            settings.get('CGO_ENABLED') != '0' or
            binary_identity(version, sha).encode() not in content):
        raise ValueError('binary identity, platform, toolchain or build metadata mismatch')


def verify(root, directory, sha, version=None):
    version = identity(root, sha, version)
    names = asset_names(version, sha)
    expected = set(names.values()) | {'REVISION', 'MANIFEST.json', 'SHA256SUMS'}
    if set(p.name for p in directory.iterdir()) != expected or any(not p.is_file() or p.is_symlink() for p in directory.iterdir()):
        raise ValueError('missing, unexpected or non-regular release asset')
    if (directory / 'REVISION').read_text() != sha + '\n':
        raise ValueError('artifact revision does not match the tested commit')
    if (directory / 'SHA256SUMS').read_text() != checksum_text(directory):
        raise ValueError('artifact checksum mismatch')
    tree = source_tree(root, sha)
    if read_archive(directory / names['source']) != {'net-connector/' + name: value for name, value in tree.items()}:
        raise ValueError('source bytes, modes, symlinks or file set differ from the committed tree')
    manifest = json.loads((directory / 'MANIFEST.json').read_text())
    if (set(manifest) != {'schema', 'version', 'revision', 'toolchain', 'platforms'} or manifest['schema'] != 1 or
            manifest['version'] != version or manifest['revision'] != sha or set(manifest['platforms']) != set(PLATFORMS) or
            not re.fullmatch(r'go1\.(?:2[6-9]|[3-9][0-9])\.\d+', manifest['toolchain'])):
        raise ValueError('manifest identity or schema mismatch')
    notices = None
    for platform in PLATFORMS:
        entries = read_archive(directory / names[platform])
        expected_payload = {'bin/' + b for b in BINS} | {'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.txt', 'VERSION', 'REVISION'}
        if set(entries) != expected_payload or any(link or mode != (0o755 if n.startswith('bin/') else 0o644) for n, (mode, _, link) in entries.items()):
            raise ValueError('binary archive file set, mode or type mismatch')
        for name, data in {'README.md': tree['README.md'][1], 'LICENSE': tree['LICENSE'][1], 'VERSION': (version + '\n').encode(), 'REVISION': (sha + '\n').encode()}.items():
            if entries[name][1] != data:
                raise ValueError('binary archive documentation or identity mismatch')
        current_notices = entries['THIRD_PARTY_NOTICES.txt'][1]
        if b'Go standard library' not in current_notices or (notices is not None and current_notices != notices):
            raise ValueError('missing or inconsistent third-party notices')
        notices = current_notices
        if manifest['platforms'][platform] != payload_manifest(entries):
            raise ValueError('payload manifest mismatch')
        for binary in BINS:
            verify_binary(root, entries['bin/' + binary][1], platform, binary, version, sha, manifest['toolchain'])


class ChineseHelpFormatter(argparse.HelpFormatter):
    def _format_usage(self, usage, actions, groups, prefix):
        return super()._format_usage(usage, actions, groups, prefix or '用法：')


class ChineseArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(2, f'{self.prog}：参数无效，请使用 --help 查看用法。\n')


def main():
    parser = ChineseArgumentParser(description=__doc__, formatter_class=ChineseHelpFormatter, usage='%(prog)s [选项] {package,verify,check-modules}', add_help=False)
    parser.add_argument('-h', '--help', action='help', help='显示帮助并退出')
    parser._positionals.title = '位置参数'
    parser._optionals.title = '选项'
    parser.add_argument('action', help='操作：package 打包、verify 校验、check-modules 检查模块', choices=('package', 'verify', 'check-modules'))
    parser.add_argument('--output', type=Path, default=Path('dist'), help='输出目录；默认 dist')
    parser.add_argument('--sha', help='已测试的完整提交 SHA；默认使用 HEAD')
    parser.add_argument('--version', help='用于校验的预期版本')
    args = parser.parse_args()
    root = Path(git(Path.cwd(), 'rev-parse', '--show-toplevel'))
    if args.action == 'check-modules':
        check_modules(root)
        return
    sha = args.sha or git(root, 'rev-parse', 'HEAD')
    if args.action == 'package':
        if args.version is not None:
            identity(root, sha, args.version)
        package(root, args.output.absolute(), sha)
    else:
        verify(root, args.output.absolute(), sha, args.version)
    print(args.action + ' 已校验：' + sha)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
