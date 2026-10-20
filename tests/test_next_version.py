# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VersionHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        shutil.copyfile(ROOT / 'scripts/next-version.py', self.root / 'scripts/next-version.py')
        (self.root / 'VERSION').write_text('0.1.0\n')
        self.git('init', '-q')
        self.git('config', 'tag.gpgsign', 'false')
        self.git('config', 'user.name', 'Release test')
        self.git('config', 'user.email', 'release-test@example.invalid')
        self.commit('Initial source')
        self.git('tag', 'v0.1.4')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def commit(self, message):
        self.git('add', '.')
        self.git('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', message)

    def version(self):
        return subprocess.check_output(['python3', 'scripts/next-version.py'], cwd=self.root, text=True).strip()

    def test_full_history_selects_patch_then_feature_and_breaking_versions(self):
        self.commit('Fix startup')
        self.assertEqual(self.version(), '0.1.5')
        self.commit('feat: Add a command')
        self.assertEqual(self.version(), '0.2.0')
        self.commit('feat!: Change a command')
        self.assertEqual(self.version(), '1.0.0')

    def test_version_floor_is_preserved(self):
        (self.root / 'VERSION').write_text('2.0.0\n')
        self.commit('Set next major version')
        self.assertEqual(self.version(), '2.0.0')

    def test_tag_creation_changes_next_build_but_not_previous_artifact_version(self):
        self.commit('Fix startup')
        artifact_version = self.version()
        self.git('tag', 'v' + artifact_version)
        self.assertEqual(self.version(), '0.1.6')
        self.assertEqual(artifact_version, '0.1.5')


if __name__ == '__main__':
    unittest.main()
