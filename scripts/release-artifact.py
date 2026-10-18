#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Record, authorize and publish a validated main artifact. Never builds code."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = '.github/workflows/ci.yml'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path):
    with Path(path).open('rb') as stream:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
        return checksum.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def gh(*args):
    return command('gh', *args)


def api(path, optional=False):
    result = subprocess.run(['gh', 'api', path], capture_output=True, text=True, cwd=ROOT)
    if optional and result.returncode and '(HTTP 404)' in result.stderr:
        return None
    result.check_returncode()
    return json.loads(result.stdout)


def record_guest(directory):
    directory = Path(directory)
    write_json(directory / 'guest.json', {
        'source_revision': command('git', 'rev-parse', 'HEAD'),
        'sha256': digest(directory / 'msl-guest'),
        'rust': command('rustc', '--version', cwd=ROOT / 'guest'),
        'protoc': command('protoc', '--version'),
        'target': 'aarch64-unknown-linux-musl',
        'lock_sha256': digest(ROOT / 'guest/Cargo.lock'),
        'toolchain_sha256': digest(ROOT / 'guest/rust-toolchain.toml'),
        'config_sha256': digest(ROOT / 'guest/.cargo/config.toml'),
    })


def check_guest(directory):
    directory = Path(directory)
    guest = json.loads((directory / 'guest.json').read_text())
    require(guest['source_revision'] == command('git', 'rev-parse', 'HEAD'), 'guest source revision mismatch')
    require(guest['target'] == 'aarch64-unknown-linux-musl', 'wrong guest target')
    for field, path in [('sha256', directory / 'msl-guest'),
                        ('lock_sha256', ROOT / 'guest/Cargo.lock'),
                        ('toolchain_sha256', ROOT / 'guest/rust-toolchain.toml'),
                        ('config_sha256', ROOT / 'guest/.cargo/config.toml')]:
        require(guest[field] == digest(path), f'guest {field} mismatch')
    return guest


def version_tuple(value):
    require(bool(re.fullmatch(r'\d+\.\d+\.\d+', value)), 'expected a stable semantic version')
    return tuple(map(int, value.split('.')))


def validate_bundle(directory, manifest):
    directory = Path(directory)
    require(manifest['schema'] == 1, 'unsupported artifact schema')
    version = manifest['version']
    version_tuple(version)
    require(bool(re.fullmatch(r'[0-9a-f]{40}', manifest['source_revision'])), 'invalid source revision')
    files = manifest['files']
    require(bool(files), 'empty artifact')
    for name, checksum in files.items():
        require(bool(re.fullmatch(r'[A-Za-z0-9_.+-]+', name)) and name not in ('.', '..', 'manifest.json'), 'unsafe artifact filename')
        require(bool(re.fullmatch(r'[0-9a-f]{64}', checksum)), 'invalid file digest')
        path = directory / name
        require(path.is_file() and not path.is_symlink(), f'missing artifact file: {name}')
        require(digest(path) == checksum, f'artifact digest mismatch: {name}')
    require({p.name for p in directory.iterdir()} == set(files) | {'manifest.json'}, 'unexpected artifact files')
    name = f'msl-{version}-macos-arm64.tar.gz'
    require(name in files and name + '.sha256' in files and 'update.json' in files, 'package assets missing')
    require((directory / (name + '.sha256')).read_text().split() == [files[name], name], 'checksum file mismatch')
    update = json.loads((directory / 'update.json').read_text())['channels']['stable']
    require(update['version'] == version and update['sha256'] == files[name], 'update metadata mismatch')
    require(update['minimumMacOS'] == manifest['minimum_macos'], 'minimum macOS mismatch')
    expected_url = f"https://github.com/{manifest['repository']}/releases/download/v{version}/{name}"
    require(update['url'] == expected_url, 'update URL mismatch')


def prepare(version, guest_directory, destination):
    version_tuple(version)
    guest = check_guest(guest_directory)
    destination = Path(destination)
    require(not destination.exists(), 'artifact destination already exists; use a fresh directory')
    destination.mkdir(parents=True)
    name = f'msl-{version}-macos-arm64.tar.gz'
    for filename in [name, name + '.sha256', 'update.json']:
        shutil.copyfile(ROOT / 'dist' / filename, destination / filename)
    for component in ['busybox', 'e2fsprogs']:
        for source in command('sh', 'scripts/gpl-sources.sh', component).splitlines():
            shutil.copyfile(source, destination / Path(source).name)
    inputs = {
        'swift_lock_sha256': digest(ROOT / 'Package.resolved'),
        'guest': guest,
        'kernel_tag': (ROOT / 'kernel/release.tag').read_text().strip(),
        'kernel_checksums': (ROOT / 'kernel/release.sha256').read_text(),
        'vscode_tag': (ROOT / 'extensions/vscode/release.tag').read_text().strip(),
        'vscode_checksums': (ROOT / 'extensions/vscode/release.sha256').read_text(),
        'xcode': command('xcodebuild', '-version'),
        'swift': command('swift', '--version'),
        'macos': command('sw_vers', '-productVersion'),
        'architecture': command('uname', '-m'),
        'configuration': os.environ.get('CONFIG', 'release'),
        'signing_identity': os.environ.get('MSL_SIGN_IDENTITY', 'ad-hoc'),
    }
    require(inputs['configuration'] == 'release' and inputs['architecture'] == 'arm64', 'expected a release build for macOS arm64')
    # Fail if packaging silently fell back to an older kernel or extension.
    import tarfile
    with tarfile.open(destination / name, 'r:gz') as archive:
        for checksums, member in [('kernel_checksums', 'Image'), ('vscode_checksums', 'msl.vsix')]:
            expected = next(line.split()[0] for line in inputs[checksums].splitlines()
                            if line.split()[1].lstrip('*') == member or member == 'msl.vsix')
            data = archive.extractfile(f'msl-{version}/share/msl/{member}').read()
            require(hashlib.sha256(data).hexdigest() == expected, f'packaged {member} differs from resolved release')
    manifest = {
        'schema': 1, 'repository': os.environ['GITHUB_REPOSITORY'],
        'source_revision': command('git', 'rev-parse', 'HEAD'),
        'source_tree': command('git', 'rev-parse', 'HEAD^{tree}'),
        'run_id': int(os.environ['GITHUB_RUN_ID']),
        'run_attempt': int(os.environ.get('GITHUB_RUN_ATTEMPT', '1')),
        'version': version, 'inputs': inputs,
        'minimum_macos': json.loads((destination / 'update.json').read_text())['channels']['stable']['minimumMacOS'],
    }
    write_json(destination / 'build-info.txt', manifest)
    manifest['files'] = {p.name: digest(p) for p in sorted(destination.iterdir())}
    write_json(destination / 'manifest.json', manifest)
    validate_bundle(destination, manifest)


def authorize_run(run, repository, workflow_id):
    require((run.get('repository') or {}).get('id') == repository['id']
            and (run.get('head_repository') or {}).get('id') == repository['id'], 'foreign build repository')
    require(run['event'] == 'push' and run['head_branch'] == 'main', 'release requires a main push build')
    require(run['workflow_id'] == workflow_id and run['path'] == WORKFLOW, 'wrong build workflow')
    require(run['status'] == 'completed' and run['conclusion'] == 'success', 'build has not passed all validation')


def validate_manifest_run(manifest, run, repo):
    require(manifest['repository'] == repo, 'manifest repository mismatch')
    require(manifest['source_revision'] == run['head_sha'], 'manifest source revision mismatch')
    require(manifest['run_id'] == run['id'], 'manifest run mismatch')
    require(1 <= manifest['run_attempt'] <= run['run_attempt'], 'invalid artifact attempt')


def extract_artifact(archive, destination, checksum):
    require(checksum == 'sha256:' + digest(archive), 'GitHub artifact archive digest mismatch')
    destination.mkdir()
    with zipfile.ZipFile(archive) as bundle:
        seen = set()
        for entry in bundle.infolist():
            require(not entry.is_dir() and entry.filename == Path(entry.filename).name, 'artifact must contain flat files')
            require(entry.filename not in seen, 'duplicate artifact file')
            seen.add(entry.filename)
            (destination / entry.filename).write_bytes(bundle.read(entry))


def download(repo, run_id, destination):
    repository = api(f'repos/{repo}')
    workflow = api(f'repos/{repo}/actions/workflows/ci.yml')
    run = api(f'repos/{repo}/actions/runs/{run_id}')
    authorize_run(run, repository, workflow['id'])
    subprocess.run(['git', 'merge-base', '--is-ancestor', run['head_sha'], 'origin/main'], cwd=ROOT, check=True)
    artifacts = api(f'repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100')['artifacts']
    matches = [a for a in artifacts if a['name'] == 'package' and not a['expired']]
    require(len(matches) == 1, 'validated package artifact missing or expired; rerun the main build')
    artifact = matches[0]
    require(artifact['workflow_run']['id'] == run_id and artifact['workflow_run']['head_sha'] == run['head_sha'], 'artifact run mismatch')
    archive = destination.parent / 'artifact.zip'
    with archive.open('wb') as output:
        subprocess.run(['gh', 'api', f"repos/{repo}/actions/artifacts/{artifact['id']}/zip"], stdout=output, check=True)
    extract_artifact(archive, destination, artifact.get('digest'))
    manifest = json.loads((destination / 'manifest.json').read_text())
    validate_manifest_run(manifest, run, repo)
    require(manifest['source_tree'] == command('git', 'rev-parse', run['head_sha'] + '^{tree}'), 'manifest source tree mismatch')
    validate_bundle(destination, manifest)
    print(f"Verified artifact {artifact['id']} ({artifact['digest']}), source {run['head_sha']}, version {manifest['version']}")
    return manifest


def tag_source(repo, tag):
    ref = api(f'repos/{repo}/git/ref/tags/{tag}', optional=True)
    if ref is None:
        return None
    obj = ref['object']
    for _ in range(10):
        if obj['type'] == 'commit':
            return obj['sha']
        require(obj['type'] == 'tag', 'release tag does not resolve to a commit')
        obj = api(f"repos/{repo}/git/tags/{obj['sha']}")['object']
    raise ValueError('release tag nesting is too deep')


def missing_assets(existing, expected):
    """Retries can add missing draft assets, never replace different bytes."""
    remote = {a['name']: a for a in existing}
    require(not (set(remote) - set(expected)), 'unexpected assets in existing release')
    for name, asset in remote.items():
        require(asset.get('digest') == 'sha256:' + expected[name], f'existing release asset differs: {name}')
    return sorted(set(expected) - set(remote))


def publish_bundle(repo, directory, manifest, prerelease):
    version, source = manifest['version'], manifest['source_revision']
    tag = 'v' + version
    existing = api(f'repos/{repo}/releases/tags/{tag}', optional=True)
    tagged = tag_source(repo, tag)
    require(tagged in (None, source), 'release tag points to a different source revision')
    if existing:
        require(existing['target_commitish'] == source or tagged == source, 'existing release source mismatch')
        require(existing['prerelease'] == prerelease, 'release retry cannot change prerelease policy')
    if not prerelease and (not existing or existing['draft']):
        latest = api(f'repos/{repo}/releases/latest', optional=True)
        if latest:
            require(version_tuple(latest['tag_name'].removeprefix('v')) <= version_tuple(version), 'refusing to move Latest backwards')
    if not existing:
        args = ['release', 'create', tag, '--repo', repo, '--target', source, '--title', tag, '--draft', '--generate-notes']
        if prerelease:
            args.append('--prerelease')
        gh(*args)
        existing = api(f'repos/{repo}/releases/tags/{tag}')
    files = dict(manifest['files'], **{'manifest.json': digest(directory / 'manifest.json')})
    signature = f'msl-{version}-macos-arm64.tar.gz.sha256.asc'
    signed = next((a for a in existing['assets'] if a['name'] == signature), None)
    if signed:
        # Reuse the original signature on retry; GPG signatures include a timestamp.
        gh('release', 'download', tag, '--repo', repo, '--pattern', signature, '--dir', str(directory))
        files[signature] = digest(directory / signature)
        if os.environ.get('MSL_GPG_KEY'):
            subprocess.run(['gpg', '--batch', '--verify', str(directory / signature),
                            str(directory / signature.removesuffix('.asc'))], check=True)
    elif os.environ.get('MSL_GPG_KEY'):
        require(existing['draft'], 'cannot add a signature to an already published release')
        subprocess.run(['gpg', '--batch', '--yes', '--local-user', os.environ['MSL_GPG_KEY'], '--armor', '--detach-sign',
                        '-o', str(directory / signature), str(directory / signature.removesuffix('.asc'))], check=True)
        files[signature] = digest(directory / signature)
    missing = missing_assets(existing['assets'], files)
    require(existing['draft'] or not missing, 'published release is incomplete; refusing to modify it')
    for name in missing:
        gh('release', 'upload', tag, str(directory / name), '--repo', repo)
    # Check upload digests before exposing the update channel.
    uploaded = api(f'repos/{repo}/releases/tags/{tag}')
    require(not missing_assets(uploaded['assets'], files), 'release upload incomplete')
    if existing['draft']:
        gh('release', 'edit', tag, '--repo', repo, '--draft=false',
           '--prerelease=' + str(prerelease).lower(), '--latest=' + str(not prerelease).lower())
        if not prerelease:
            require(api(f'repos/{repo}/releases/latest')['tag_name'] == tag, 'Latest release channel did not advance')
    require(tag_source(repo, tag) == source, 'published tag source mismatch')
    # GitHub Releases is this repository's deployment target. Check actual bytes,
    # including update.json, after publication rather than rebuilding a package.
    with tempfile.TemporaryDirectory(prefix='msl-release-health-') as scratch:
        gh('release', 'download', tag, '--repo', repo, '--dir', scratch)
        for name, checksum in files.items():
            require(digest(Path(scratch) / name) == checksum, f'deployed asset digest mismatch: {name}')
    print(f'Published and verified {repo} {tag} from {source}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    for name in ['guest', 'check-guest']:
        sub.add_parser(name).add_argument('directory', type=Path)
    prep = sub.add_parser('prepare')
    prep.add_argument('version')
    prep.add_argument('guest_directory', type=Path)
    prep.add_argument('destination', type=Path)
    pub = sub.add_parser('publish')
    pub.add_argument('run_id', type=int)
    pub.add_argument('--prerelease', action='store_true')
    args = parser.parse_args()
    if args.operation == 'guest':
        record_guest(args.directory)
    elif args.operation == 'check-guest':
        check_guest(args.directory)
    elif args.operation == 'prepare':
        prepare(args.version, args.guest_directory, args.destination)
    else:
        require(args.run_id > 0, 'run ID must be positive')
        repo = os.environ.get('GITHUB_REPOSITORY', os.environ.get('MSL_REPO', 'onexay/msl'))
        with tempfile.TemporaryDirectory(prefix='msl-publish-') as scratch:
            directory = Path(scratch) / 'package'
            manifest = download(repo, args.run_id, directory)
            publish_bundle(repo, directory, manifest, args.prerelease)


if __name__ == '__main__':
    main()
