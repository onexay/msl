# SPDX-License-Identifier: Apache-2.0
import copy
import importlib.util
import json
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_artifact', ROOT / 'scripts/release-artifact.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.source = 'a' * 40
        self.repo = {'id': 10, 'full_name': 'onexay/msl'}
        self.run = dict(id=23, event='push', head_branch='main', path=release.WORKFLOW,
                        status='completed', conclusion='success', workflow_id=7,
                        repository=self.repo, head_repository=self.repo,
                        head_sha=self.source, run_attempt=2)
        self.name = 'msl-0.1.5-macos-arm64.tar.gz'
        (self.directory / self.name).write_bytes(b'validated package')
        sha = release.digest(self.directory / self.name)
        (self.directory / (self.name + '.sha256')).write_text(f'{sha}  {self.name}\n')
        release.write_json(self.directory / 'update.json', {'channels': {'stable': {
            'version': '0.1.5', 'sha256': sha, 'minimumMacOS': 27,
            'url': f'https://github.com/onexay/msl/releases/download/v0.1.5/{self.name}'}}})
        self.manifest = dict(schema=1, repository='onexay/msl', source_revision=self.source,
                             version='0.1.5', minimum_macos=27, run_id=23, run_attempt=1, source_tree='b' * 40,
                             files={p.name: release.digest(p) for p in self.directory.iterdir()})
        release.write_json(self.directory / 'manifest.json', self.manifest)

    def test_only_successful_main_push_from_expected_workflow_is_authorized(self):
        release.authorize_run(self.run, self.repo, 7)
        for field, values in {
            'event': ['pull_request', 'merge_group', 'workflow_dispatch'],
            'head_branch': ['feature'], 'status': ['in_progress', 'queued'],
            'conclusion': ['failure', 'cancelled', 'skipped'],
            'workflow_id': [8], 'path': ['.github/workflows/other.yml'],
            'head_repository': [{'id': 99}, None], 'repository': [{'id': 99}],
        }.items():
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    release.authorize_run(dict(self.run, **{field: value}), self.repo, 7)

    def test_manifest_cannot_change_source_repository_or_run(self):
        release.validate_manifest_run(self.manifest, self.run, 'onexay/msl')
        for field, value in [('source_revision', 'b' * 40), ('repository', 'foreign/repo'),
                             ('run_id', 24), ('run_attempt', 3), ('run_attempt', 0)]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                release.validate_manifest_run(dict(self.manifest, **{field: value}), self.run, 'onexay/msl')

    def test_bundle_digest_and_embedded_update_metadata(self):
        release.validate_bundle(self.directory, self.manifest)
        (self.directory / self.name).write_bytes(b'changed package')
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            release.validate_bundle(self.directory, self.manifest)

    def test_wrong_update_version_is_rejected_even_with_valid_file_digests(self):
        update_path = self.directory / 'update.json'
        update = json.loads(update_path.read_text())
        update['channels']['stable']['version'] = '0.1.6'
        release.write_json(update_path, update)
        self.manifest['files']['update.json'] = release.digest(update_path)
        with self.assertRaisesRegex(ValueError, 'update metadata mismatch'):
            release.validate_bundle(self.directory, self.manifest)

    def test_missing_extra_and_unsafe_files_are_rejected(self):
        for filename in ['../escape', '/escape', '..', 'manifest.json']:
            bad = copy.deepcopy(self.manifest)
            bad['files'][filename] = '0' * 64
            with self.subTest(filename=filename), self.assertRaises(ValueError):
                release.validate_bundle(self.directory, bad)
        extra = self.directory / 'extra'
        extra.write_text('unlisted')
        with self.assertRaisesRegex(ValueError, 'unexpected artifact files'):
            release.validate_bundle(self.directory, self.manifest)
        extra.unlink()
        (self.directory / self.name).unlink()
        with self.assertRaisesRegex(ValueError, 'missing artifact file'):
            release.validate_bundle(self.directory, self.manifest)

    def test_archive_digest_and_paths_are_checked_before_extraction(self):
        archive = self.directory / 'artifact.zip'
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.writestr('../escape', 'bad')
        with self.assertRaisesRegex(ValueError, 'archive digest mismatch'):
            release.extract_artifact(archive, self.directory / 'bad-digest', 'sha256:' + '0' * 64)
        with self.assertRaisesRegex(ValueError, 'flat files'):
            release.extract_artifact(archive, self.directory / 'bad-path', 'sha256:' + release.digest(archive))
        with zipfile.ZipFile(archive, 'w') as bundle:
            bundle.writestr('safe', 'good')
        release.extract_artifact(archive, self.directory / 'safe', 'sha256:' + release.digest(archive))
        self.assertEqual((self.directory / 'safe/safe').read_text(), 'good')

    def test_missing_expired_and_foreign_artifacts_fail_closed(self):
        artifact = {'name': 'package', 'expired': False, 'id': 44,
                    'workflow_run': {'id': 23, 'head_sha': self.source}}
        for artifacts in [[], [dict(artifact, expired=True)],
                          [dict(artifact, workflow_run={'id': 24, 'head_sha': self.source})]]:
            def fake_api(path):
                if path.endswith('/workflows/ci.yml'):
                    return {'id': 7}
                if path.endswith('/runs/23'):
                    return self.run
                if '/artifacts?' in path:
                    return {'artifacts': artifacts}
                return self.repo
            with self.subTest(artifacts=artifacts), patch.object(release, 'api', side_effect=fake_api), \
                 patch.object(release.subprocess, 'run'), self.assertRaises(ValueError):
                release.download('onexay/msl', 23, self.directory / 'download')

    def test_authorized_artifact_download_round_trip(self):
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as bundle:
            for path in self.directory.iterdir():
                bundle.write(path, path.name)
        blob = archive.getvalue()
        artifact = dict(name='package', expired=False, id=44,
                        digest='sha256:' + __import__('hashlib').sha256(blob).hexdigest(),
                        workflow_run=dict(id=23, head_sha=self.source))
        def fake_api(path):
            if path.endswith('/workflows/ci.yml'):
                return {'id': 7}
            if path.endswith('/runs/23'):
                return self.run
            if '/artifacts?' in path:
                return {'artifacts': [artifact]}
            return self.repo
        def fake_run(args, **kwargs):
            if args[0] == 'gh':
                kwargs['stdout'].write(blob)
            return subprocess.CompletedProcess(args, 0)
        with patch.object(release, 'api', side_effect=fake_api), \
             patch.object(release, 'command', return_value='b' * 40), \
             patch.object(release.subprocess, 'run', side_effect=fake_run):
            manifest = release.download('onexay/msl', 23, self.directory / 'download')
        self.assertEqual(manifest, self.manifest)
        self.assertEqual((self.directory / 'download' / self.name).read_bytes(), b'validated package')

    def test_stale_guest_source_lock_target_or_bytes_are_not_reused(self):
        root = self.directory / 'source'
        (root / 'guest/.cargo').mkdir(parents=True)
        for name in ['Cargo.lock', 'rust-toolchain.toml', '.cargo/config.toml']:
            (root / 'guest' / name).write_text(name)
        guest = self.directory / 'guest'
        guest.mkdir()
        (guest / 'msl-guest').write_bytes(b'static binary')
        with patch.object(release, 'ROOT', root), patch.object(release, 'command', return_value=self.source):
            release.record_guest(guest)
            original = release.check_guest(guest)
            for field in ['source_revision', 'target', 'sha256', 'lock_sha256', 'toolchain_sha256', 'config_sha256']:
                bad = dict(original, **{field: 'changed'})
                release.write_json(guest / 'guest.json', bad)
                with self.subTest(field=field), self.assertRaises(ValueError):
                    release.check_guest(guest)

    def test_failed_upload_does_not_publish_the_draft(self):
        existing = dict(draft=True, prerelease=False, target_commitish=self.source, assets=[])
        calls = []
        def fake_api(path, optional=False):
            return {'tag_name': 'v0.1.4'} if path.endswith('/latest') else existing
        def fake_gh(*args):
            calls.append(args)
            raise subprocess.CalledProcessError(1, args)
        with patch.object(release, 'api', side_effect=fake_api), \
             patch.object(release, 'tag_source', return_value=self.source), \
             patch.object(release, 'gh', side_effect=fake_gh), self.assertRaises(subprocess.CalledProcessError):
            release.publish_bundle('onexay/msl', self.directory, self.manifest, False)
        self.assertTrue(all(call[:2] == ('release', 'upload') for call in calls))

    def test_retry_uploads_only_missing_draft_assets_and_never_overwrites(self):
        files = self.manifest['files']
        first = next(iter(files))
        existing = [{'name': first, 'digest': 'sha256:' + files[first]}]
        self.assertEqual(set(release.missing_assets(existing, files)), set(files) - {first})
        self.assertEqual(release.missing_assets([
            {'name': name, 'digest': 'sha256:' + sha} for name, sha in files.items()], files), [])
        for bad in [[{'name': first, 'digest': 'sha256:' + '0' * 64}],
                    [{'name': 'unexpected', 'digest': 'sha256:' + '0' * 64}]]:
            with self.assertRaises(ValueError):
                release.missing_assets(bad, files)

    def test_finished_release_retry_only_checks_deployed_bytes(self):
        files = dict(self.manifest['files'], **{'manifest.json': release.digest(self.directory / 'manifest.json')})
        existing = dict(draft=False, prerelease=False, target_commitish=self.source,
                        assets=[{'name': name, 'digest': 'sha256:' + sha} for name, sha in files.items()])
        calls = []
        def fake_gh(*args):
            calls.append(args)
            self.assertEqual(args[:2], ('release', 'download'))
            destination = Path(args[args.index('--dir') + 1])
            for name in files:
                (destination / name).write_bytes((self.directory / name).read_bytes())
        with patch.object(release, 'api', return_value=existing), \
             patch.object(release, 'tag_source', return_value=self.source), \
             patch.object(release, 'gh', side_effect=fake_gh):
            release.publish_bundle('onexay/msl', self.directory, self.manifest, False)
        self.assertEqual(len(calls), 1)

    def test_draft_retry_publishes_once_after_upload_verification(self):
        files = dict(self.manifest['files'], **{'manifest.json': release.digest(self.directory / 'manifest.json')})
        existing = dict(draft=True, prerelease=False, target_commitish=self.source, assets=[])
        calls = []
        def fake_api(path, optional=False):
            if path.endswith('/latest'):
                return {'tag_name': 'v0.1.5' if existing.get('published') else 'v0.1.4'}
            return existing
        def fake_gh(*args):
            calls.append(args)
            if args[:2] == ('release', 'upload'):
                name = Path(args[3]).name
                existing['assets'].append({'name': name, 'digest': 'sha256:' + files[name]})
            elif args[:2] == ('release', 'edit'):
                existing['published'] = True
            elif args[:2] == ('release', 'download'):
                destination = Path(args[args.index('--dir') + 1])
                for name in files:
                    (destination / name).write_bytes((self.directory / name).read_bytes())
        with patch.object(release, 'api', side_effect=fake_api), \
             patch.object(release, 'tag_source', return_value=self.source), \
             patch.object(release, 'gh', side_effect=fake_gh):
            release.publish_bundle('onexay/msl', self.directory, self.manifest, False)
        self.assertEqual(len([c for c in calls if c[:2] == ('release', 'edit')]), 1)
        self.assertEqual(len([c for c in calls if c[:2] == ('release', 'upload')]), len(files))

    def test_collision_and_incomplete_published_release_are_not_modified(self):
        existing = dict(draft=False, prerelease=False, target_commitish=self.source, assets=[])
        for tagged in ['b' * 40, self.source]:
            with self.subTest(tagged=tagged), patch.object(release, 'api', return_value=existing), \
                 patch.object(release, 'tag_source', return_value=tagged), \
                 patch.object(release, 'gh') as mocked, self.assertRaises(ValueError):
                release.publish_bundle('onexay/msl', self.directory, self.manifest, False)
            mocked.assert_not_called()

    def test_publish_tool_contains_no_build_or_restamp_commands(self):
        text = (ROOT / 'scripts/publish.sh').read_text()
        for forbidden in ['package.sh', 'pin.sh', 'next-version.py', 'cargo build', 'swift build', 'set-version.sh']:
            self.assertNotIn(forbidden, text)


class WorkflowPathTests(unittest.TestCase):
    def test_event_and_cancellation_paths(self):
        ci = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('branches: [main]', ci)  # no activity-branch or tag pushes
        self.assertIn('types: [opened, synchronize, reopened, edited, ready_for_review]', ci)
        self.assertIn('merge_group:\n    types: [checks_requested]', ci)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", ci)
        self.assertIn('github.event.pull_request.number || github.sha', ci)
        self.assertNotIn('paths:', ci)
        self.assertNotIn('pull_request_target', ci)
        self.assertNotIn('          ref:', ci)  # PR checks use the integration ref
        self.assertIn('needs: [host, guest, lint]', ci)
        self.assertIn('fetch-depth: 0', ci)
        self.assertLess(ci.index('Determine version'), ci.index('scripts/package.sh'))
        self.assertLess(ci.index('scripts/check-package.py'), ci.index('path: dist/release/'))

    def test_release_is_explicit_serialized_and_does_not_run_pr_code(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertIn('workflow_dispatch:', workflow)
        for event in ['\n  push:', '\n  release:', '\n  workflow_run:']:
            self.assertNotIn(event, workflow)
        self.assertIn('cancel-in-progress: false', workflow)
        self.assertIn("if: github.ref == 'refs/heads/main'", workflow)
        for command in ['package.sh', 'build.sh', 'set-version', 'pin.sh']:
            self.assertNotIn(command, workflow)
        self.assertNotIn('secrets.', (ROOT / '.github/workflows/ci.yml').read_text())


if __name__ == '__main__':
    unittest.main()
