"""Isolated tests for the release preparation helper; no real project edits."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / 'tools' / 'prepare-next-release.py'
SPEC = importlib.util.spec_from_file_location('prepare_next_release', SCRIPT)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleasePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'tt-su-hub'
        version = '0.2.3-beta.1'
        self.write('src/su_zhongshu.rb', "# preserve comment\nmodule SUHub\n  VERSION = '" + version + "' unless const_defined?(:VERSION, false)\nend\n")
        self.write('src/hub/main.rb', 'module SUHub\r\n  VERSION = "' + version + '" unless const_defined?(:VERSION, false)\r\nend\r\n', bom=True)
        self.write_json('package.json', {'name': 'tt-su-hub', 'version': version, 'private': True, 'scripts': {'test:ui': 'keep me'}})
        self.write_json('package-lock.json', {'name': 'tt-su-hub', 'version': version, 'lockfileVersion': 3,
                                            'packages': {'': {'name': 'tt-su-hub', 'version': version},
                                                         'node_modules/example': {'version': '9.9.9', 'integrity': 'preserve-this'}}})
        self.write_json('src/release.json', {'schemaVersion': 1, 'repository': '', 'channel': 'preview',
                                           'assetName': 'su_zhongshu-core.rbz', 'futureField': {'keep': True}})
        self.write('docs/public-release-notes.md', '# Written by the maintainer\n')

    def write(self, relative, text, bom=False):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((b'\xef\xbb\xbf' if bom else b'') + text.encode('utf-8'))

    def write_json(self, relative, value):
        self.write(relative, json.dumps(value, ensure_ascii=False, indent=2) + '\n')

    def read_json(self, relative):
        return json.loads((self.root / relative).read_text(encoding='utf-8-sig'))

    def snapshot(self):
        return {path.relative_to(self.root).as_posix(): path.read_bytes() for path in self.root.rglob('*') if path.is_file()}

    def prepare(self, version='0.2.3-beta.2', **kwargs):
        return release.make_plan(self.root, version, **kwargs)

    def test_dry_run_does_not_create_or_modify_any_file(self):
        before = self.snapshot()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(release.main(['--root', str(self.root), '--version', '0.2.3-beta.2']), 0)
        self.assertIn('DRY RUN', output.getvalue())
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.root / 'dist').exists())

    def test_apply_updates_all_versions_and_preserves_dependencies_and_notes(self):
        before = self.snapshot()
        plan = self.prepare(repository='test-maintainer/tt-su-hub')
        backup = release.apply_plan(plan)
        self.assertEqual(self.read_json('package.json')['version'], '0.2.3-beta.2')
        lock = self.read_json('package-lock.json')
        self.assertEqual(lock['version'], '0.2.3-beta.2')
        self.assertEqual(lock['packages']['']['version'], '0.2.3-beta.2')
        self.assertEqual(lock['packages']['node_modules/example'], {'version': '9.9.9', 'integrity': 'preserve-this'})
        for relative in release.FILES[:2]:
            self.assertIn('0.2.3-beta.2', (self.root / relative).read_text(encoding='utf-8-sig'))
        config = self.read_json('src/release.json')
        self.assertEqual(config['repository'], 'test-maintainer/tt-su-hub')
        self.assertEqual(config['channel'], 'preview')
        self.assertEqual(config['futureField'], {'keep': True})
        self.assertEqual((self.root / 'docs/public-release-notes.md').read_bytes(), before['docs/public-release-notes.md'])
        self.assertEqual(self.read_json('package.json')['scripts'], {'test:ui': 'keep me'})
        for relative in release.FILES:
            self.assertEqual((backup / relative).read_bytes(), before[relative])
        self.assertEqual(json.loads((backup / 'plan.json').read_text(encoding='utf-8'))['releaseTag'], 'v0.2.3-beta.2')

    def test_ruby_bom_crlf_and_comment_are_preserved(self):
        release.apply_plan(self.prepare())
        host = (self.root / 'src/hub/main.rb').read_bytes()
        self.assertTrue(host.startswith(b'\xef\xbb\xbf'))
        self.assertIn(b'\r\n', host)
        self.assertNotIn(b'\n', host.replace(b'\r\n', b''))
        self.assertTrue((self.root / 'src/su_zhongshu.rb').read_bytes().startswith(b'# preserve comment\n'))

    def test_stable_version_defaults_to_stable_channel(self):
        release.apply_plan(self.prepare('0.2.3'))
        self.assertEqual(self.read_json('src/release.json')['channel'], 'stable')

    def test_explicit_preview_channel_can_contain_final_version(self):
        release.apply_plan(self.prepare('0.2.3', channel='preview'))
        self.assertEqual(self.read_json('src/release.json')['channel'], 'preview')

    def test_stable_channel_rejects_prerelease_before_writing(self):
        before = self.snapshot()
        with self.assertRaisesRegex(release.ReleaseError, 'prerelease.*stable'):
            self.prepare(channel='stable')
        self.assertEqual(self.snapshot(), before)

    def test_version_precedence_uses_semver(self):
        ordered = ['0.2.3-alpha', '0.2.3-alpha.1', '0.2.3-alpha.beta', '0.2.3-beta',
                   '0.2.3-beta.2', '0.2.3-beta.10', '0.2.3-rc.1', '0.2.3', '0.2.4', '1.0.0']
        for left, right in zip(ordered, ordered[1:]):
            with self.subTest(left=left, right=right):
                self.assertLess(release.compare_versions(left, right), 0)
                self.assertGreater(release.compare_versions(right, left), 0)
                self.assertEqual(release.compare_versions(left, left), 0)

    def test_same_and_downgrade_versions_are_refused(self):
        before = self.snapshot()
        for value in ['0.2.3-beta.1', '0.2.3-alpha.9', '0.2.2', '0.1.999']:
            with self.subTest(version=value), self.assertRaisesRegex(release.ReleaseError, 'must be greater'):
                self.prepare(value)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_versions_and_unsupported_build_metadata_are_refused(self):
        for value in ['v0.2.4', '0.2', '01.2.3', '0.2.4-beta.01', '0.2.4-', '0.2.4-beta..2',
                      '0.2.4\n', '0.2.4+build.1', '0.2.4 beta', None, 42]:
            with self.subTest(version=value), self.assertRaises(release.ReleaseError):
                self.prepare(value)

    def test_version_mismatch_is_refused_without_writes(self):
        for relative in ['package.json', 'package-lock.json', 'src/su_zhongshu.rb', 'src/hub/main.rb']:
            original = (self.root / relative).read_bytes()
            (self.root / relative).write_bytes(original.replace(b'0.2.3-beta.1', b'0.1.0', 1))
            before = self.snapshot()
            with self.subTest(file=relative), self.assertRaisesRegex(release.ReleaseError, 'versions disagree'):
                self.prepare()
            self.assertEqual(self.snapshot(), before)
            (self.root / relative).write_bytes(original)

    def test_nested_lockfile_version_mismatch_is_detected(self):
        lock = self.read_json('package-lock.json')
        lock['packages']['']['version'] = '0.2.2'
        self.write_json('package-lock.json', lock)
        with self.assertRaisesRegex(release.ReleaseError, 'versions disagree'):
            self.prepare()

    def test_repeat_apply_does_not_create_another_backup_or_change_files(self):
        release.apply_plan(self.prepare())
        before = self.snapshot()
        with self.assertRaisesRegex(release.ReleaseError, 'same versions'):
            release.apply_plan(self.prepare())
        self.assertEqual(self.snapshot(), before)

    def test_apply_error_rolls_back_original_bytes_and_retains_backup(self):
        before = self.snapshot()
        real_write = release.atomic_write
        calls = 0

        def fail_once(path, data):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError('simulated disk failure')
            real_write(path, data)

        with mock.patch.object(release, 'atomic_write', side_effect=fail_once):
            with self.assertRaisesRegex(release.ReleaseError, 'All attempted source changes were restored'):
                release.apply_plan(self.prepare())
        for relative, original in before.items():
            self.assertEqual((self.root / relative).read_bytes(), original)
        backups = list((self.root / 'dist/release-preparation').iterdir())
        self.assertEqual(len(backups), 1)
        for relative in release.FILES:
            self.assertEqual((backups[0] / relative).read_bytes(), before[relative])
        self.assertFalse(list(self.root.rglob('.release-*.tmp')))

    def test_failure_after_replacement_still_restores_attempted_file(self):
        before = self.snapshot()
        real_write = release.atomic_write
        calls = 0

        def fail_after_write(path, data):
            nonlocal calls
            calls += 1
            real_write(path, data)
            if calls == 2:
                raise OSError('simulated post-replacement failure')

        with mock.patch.object(release, 'atomic_write', side_effect=fail_after_write):
            with self.assertRaisesRegex(release.ReleaseError, 'restored'):
                release.apply_plan(self.prepare())
        for relative, original in before.items():
            self.assertEqual((self.root / relative).read_bytes(), original)

    def test_backup_failure_does_not_modify_sources(self):
        before = self.snapshot()
        with mock.patch.object(Path, 'write_bytes', side_effect=OSError('backup disk full')):
            with self.assertRaisesRegex(OSError, 'backup disk full'):
                release.apply_plan(self.prepare())
        for relative, original in before.items():
            self.assertEqual((self.root / relative).read_bytes(), original)

    def test_persistent_disk_error_reports_incomplete_restore_and_keeps_backup(self):
        before = self.snapshot()
        real_write = release.atomic_write
        calls = 0

        def fail_after_first(path, data):
            nonlocal calls
            calls += 1
            if calls > 1:
                raise OSError('persistent disk failure')
            real_write(path, data)

        with mock.patch.object(release, 'atomic_write', side_effect=fail_after_first):
            with self.assertRaisesRegex(release.ReleaseError, 'ROLLBACK INCOMPLETE.*src/su_zhongshu.rb'):
                release.apply_plan(self.prepare())
        backups = list((self.root / 'dist/release-preparation').iterdir())
        self.assertEqual(len(backups), 1)
        for relative in release.FILES:
            self.assertEqual((backups[0] / relative).read_bytes(), before[relative])

    def test_source_changed_after_preview_refuses_apply(self):
        plan = self.prepare()
        self.write('src/su_zhongshu.rb', 'a concurrent edit\n')
        before = self.snapshot()
        with self.assertRaisesRegex(release.ReleaseError, 'changed after preview'):
            release.apply_plan(plan)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.root / 'dist').exists())

    def test_invalid_repository_is_refused(self):
        for value in ['https://github.com/a/b', 'a/b/c', 'a b/repo', 'a/中文', 'a/', '/repo', '']:
            with self.subTest(repository=value), self.assertRaisesRegex(release.ReleaseError, 'Repository must'):
                self.prepare(repository=value)

    def test_existing_repository_is_preserved_without_argument(self):
        config = self.read_json('src/release.json')
        config['repository'] = 'test-maintainer/existing-repo'
        self.write_json('src/release.json', config)
        release.apply_plan(self.prepare())
        self.assertEqual(self.read_json('src/release.json')['repository'], config['repository'])

    def test_wrong_project_and_missing_files_are_refused(self):
        with self.assertRaisesRegex(release.ReleaseError, 'incomplete'):
            release.make_plan(self.root / 'wrong-root', '1.0.0')
        package = self.read_json('package.json')
        package['name'] = 'unrelated-project'
        self.write_json('package.json', package)
        with self.assertRaisesRegex(release.ReleaseError, 'Root must'):
            self.prepare()

    def test_duplicate_ruby_assignment_and_duplicate_json_keys_are_refused(self):
        source = (self.root / 'src/su_zhongshu.rb').read_text(encoding='utf-8')
        self.write('src/su_zhongshu.rb', source + "VERSION = '0.2.3-beta.1'\n")
        with self.assertRaisesRegex(release.ReleaseError, 'exactly one'):
            self.prepare()
        self.write('src/su_zhongshu.rb', source)
        self.write('src/release.json', '{"channel": "preview", "channel": "stable"}')
        with self.assertRaisesRegex(release.ReleaseError, 'Duplicate JSON key'):
            self.prepare()

    def test_cli_apply_and_required_version(self):
        result = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root), '--version', '0.2.3-beta.2', '--apply'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Version files updated', result.stdout)
        missing = subprocess.run([sys.executable, str(SCRIPT), '--root', str(self.root)], capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('--version', missing.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
