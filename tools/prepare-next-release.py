"""Preview or apply a version bump; never build, contact GitHub, or publish.

Run from any directory. By default the root is the parent of this script's
tools directory. Source files and their current versions must agree before any
write. Build metadata (+...) is not supported by this project's RBZ validator.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import uuid


FILES = (
    'src/su_zhongshu.rb',
    'src/hub/main.rb',
    'package.json',
    'package-lock.json',
    'src/release.json',
)
SEMVER = re.compile(
    r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
)
RUBY_VERSION = re.compile(r'(?m)^(\s*VERSION\s*=\s*)([\'\"])([^\'\"\r\n]+)(\2)')
REPOSITORY = re.compile(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}')


class ReleaseError(ValueError):
    pass


def semver(value):
    if not isinstance(value, str) or not (match := SEMVER.fullmatch(value)):
        raise ReleaseError('Version must be SemVer, for example 0.2.3-beta.2 (no leading v).')
    prerelease = tuple(match.group(4).split('.')) if match.group(4) else ()
    if any(part.isdigit() and len(part) > 1 and part.startswith('0') for part in prerelease):
        raise ReleaseError('Numeric prerelease identifiers cannot have leading zeroes.')
    if match.group(5):
        raise ReleaseError('Build metadata (+...) is not supported by the current RBZ validator.')
    return tuple(int(match.group(index)) for index in (1, 2, 3)), prerelease


def compare_versions(left, right):
    """SemVer precedence, including numeric prerelease identifiers (2 < 10)."""
    left_core, left_pre = semver(left)
    right_core, right_pre = semver(right)
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if not left_pre or not right_pre:
        return (not left_pre) - (not right_pre)
    for first, second in zip(left_pre, right_pre):
        if first == second:
            continue
        if first.isdigit() and second.isdigit():
            return (int(first) > int(second)) - (int(first) < int(second))
        if first.isdigit() != second.isdigit():
            return -1 if first.isdigit() else 1
        return (first > second) - (first < second)
    return (len(left_pre) > len(right_pre)) - (len(left_pre) < len(right_pre))


def validate_repository(value):
    if not isinstance(value, str) or not REPOSITORY.fullmatch(value):
        raise ReleaseError('Repository must be GitHub owner/repo, without a URL or credentials.')
    return value


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ReleaseError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def json_object(raw, label):
    try:
        data = json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique_keys)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseError('Invalid UTF-8 JSON in ' + label + ': ' + str(error)) from error
    if not isinstance(data, dict):
        raise ReleaseError(label + ' must contain a JSON object.')
    return data


def encode_like(text, original):
    # Preserve each file's BOM and newline style; unrelated dependency values
    # and Ruby source remain intact.
    newline = '\r\n' if b'\r\n' in original else '\n'
    result = text.replace('\r\n', '\n').replace('\n', newline).encode('utf-8')
    return (b'\xef\xbb\xbf' if original.startswith(b'\xef\xbb\xbf') else b'') + result


def encode_json(data, original):
    return encode_like(json.dumps(data, ensure_ascii=False, indent=2) + '\n', original)


def inside_root(root, path):
    try:
        path.resolve().relative_to(root)
    except ValueError as error:
        raise ReleaseError('Managed path resolves outside the project root: ' + str(path)) from error
    return path


def make_plan(root, next_version, channel=None, repository=None):
    root = Path(root).resolve()
    semver(next_version)
    if channel is not None and channel not in ('preview', 'stable'):
        raise ReleaseError('Channel must be preview or stable.')
    next_channel = channel or ('preview' if semver(next_version)[1] else 'stable')
    if next_channel == 'stable' and semver(next_version)[1]:
        raise ReleaseError('A prerelease version cannot use the stable channel.')
    if repository is not None:
        validate_repository(repository)

    originals = {}
    for relative in FILES:
        path = inside_root(root, root / relative)
        if not path.is_file() or path.is_symlink():
            raise ReleaseError('Project root is incomplete or a managed file is a symlink: ' + relative)
        originals[relative] = path.read_bytes()

    ruby_sources = {}
    versions = {}
    for relative in FILES[:2]:
        source = originals[relative].decode('utf-8-sig')
        matches = list(RUBY_VERSION.finditer(source))
        if not re.search(r'(?m)^module SUHub\s*$', source) or len(matches) != 1:
            raise ReleaseError(relative + ' must contain module SUHub and exactly one VERSION assignment.')
        ruby_sources[relative] = source
        versions[relative] = matches[0].group(3)

    package = json_object(originals['package.json'], 'package.json')
    lock = json_object(originals['package-lock.json'], 'package-lock.json')
    config = json_object(originals['src/release.json'], 'src/release.json')
    lock_root = lock.get('packages', {}).get('') if isinstance(lock.get('packages'), dict) else None
    if (package.get('name') != 'tt-su-hub' or lock.get('name') != 'tt-su-hub'
            or not isinstance(lock_root, dict) or lock_root.get('name') != 'tt-su-hub'
            or lock.get('lockfileVersion') != 3):
        raise ReleaseError('Root must be the tt-su-hub project with an npm lockfileVersion 3 root package.')
    versions['package.json'] = package.get('version')
    versions['package-lock.json'] = lock.get('version')
    versions['package-lock.json packages[""]'] = lock_root.get('version')
    for value in versions.values():
        semver(value)
    if len(set(versions.values())) != 1:
        raise ReleaseError('Current versions disagree; repair the mismatch before preparing a release: '
                           + json.dumps(versions, ensure_ascii=False))
    current = versions['src/su_zhongshu.rb']
    if compare_versions(next_version, current) <= 0:
        raise ReleaseError('New version must be greater than ' + current + '; same versions and downgrades are refused.')
    if (config.get('schemaVersion') != 1 or config.get('assetName') != 'su_zhongshu-core.rbz'
            or config.get('channel') not in ('preview', 'stable')):
        raise ReleaseError('Current release configuration is invalid.')
    if config['channel'] == 'stable' and semver(current)[1]:
        raise ReleaseError('Current prerelease version incorrectly uses the stable channel; repair it first.')
    current_repository = config.get('repository')
    if not isinstance(current_repository, str):
        raise ReleaseError('Current repository must be a string (empty is allowed before setup).')
    if current_repository:
        validate_repository(current_repository)

    replacements = {}
    for relative, source in ruby_sources.items():
        updated = RUBY_VERSION.sub(lambda match: match.group(1) + match.group(2) + next_version + match.group(4), source)
        replacements[relative] = encode_like(updated, originals[relative])
    package['version'] = lock['version'] = lock_root['version'] = next_version
    replacements['package.json'] = encode_json(package, originals['package.json'])
    replacements['package-lock.json'] = encode_json(lock, originals['package-lock.json'])
    config['channel'] = next_channel
    if repository is not None:
        config['repository'] = repository
    replacements['src/release.json'] = encode_json(config, originals['src/release.json'])
    plan = {
        'root': str(root), 'currentVersion': current, 'nextVersion': next_version,
        'channel': {'before': json_object(originals['src/release.json'], 'src/release.json')['channel'], 'after': next_channel},
        'repository': {'before': current_repository, 'after': config['repository']},
        'files': [name for name in FILES if originals[name] != replacements[name]],
        'releaseTag': 'v' + next_version,
        'reminder': 'Edit docs/public-release-notes.md, run tests, then create and verify a draft release. Nothing is published by this tool.',
    }
    return root, originals, replacements, plan


def atomic_write(path, payload):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix='.release-', suffix='.tmp', dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(path.stat().st_mode))
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def apply_plan(prepared):
    root, originals, replacements, plan = prepared
    for name, original in originals.items():
        if inside_root(root, root / name).read_bytes() != original:
            raise ReleaseError('File changed after preview; no files written: ' + name)

    backup_parent = inside_root(root, root / 'dist' / 'release-preparation')
    backup_parent.mkdir(parents=True, exist_ok=True)
    backup = backup_parent / (datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8])
    backup.mkdir()
    # Finish all backups before replacing the first source file. Backup failures
    # leave source files untouched, and successful backups are never removed.
    for name, original in originals.items():
        saved = backup / name
        saved.parent.mkdir(parents=True, exist_ok=True)
        saved.write_bytes(original)
        if saved.read_bytes() != original:
            raise ReleaseError('Backup verification failed; sources were not modified: ' + str(saved))
    record = dict(plan, originalSha256={name: hashlib.sha256(raw).hexdigest() for name, raw in originals.items()})
    (backup / 'plan.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    attempted = []
    try:
        for name in plan['files']:
            path = inside_root(root, root / name)
            if path.read_bytes() != originals[name]:
                raise ReleaseError('Source changed while preparing release: ' + name)
            attempted.append(name)
            atomic_write(path, replacements[name])
        for name in FILES:
            if (root / name).read_bytes() != replacements[name]:
                raise ReleaseError('Post-write verification failed: ' + name)
    except Exception as error:
        failures = []
        for name in reversed(attempted):
            try:
                path = inside_root(root, root / name)
                if path.read_bytes() != originals[name]:
                    atomic_write(path, originals[name])
                if path.read_bytes() != originals[name]:
                    raise OSError('Restored bytes do not match the backup.')
            except Exception as restore_error:
                failures.append(name + ': ' + str(restore_error))
        outcome = ('ROLLBACK INCOMPLETE: ' + '; '.join(failures)) if failures else 'All attempted source changes were restored.'
        raise ReleaseError(str(error) + '\n' + outcome + '\nBackup: ' + str(backup)) from error
    return backup


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True, help='Strictly newer SemVer, e.g. 0.2.3-beta.2; no v prefix or +build metadata.')
    parser.add_argument('--channel', choices=('preview', 'stable'), help='Default: preview for prerelease, stable for a final version.')
    parser.add_argument('--repository', help='Optional GitHub owner/repo to bind or change the update source.')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1], help='Project root (normally detected from this script).')
    parser.add_argument('--apply', action='store_true', help='Back up and apply the plan. Without this flag, write nothing.')
    args = parser.parse_args(argv)
    try:
        prepared = make_plan(args.root, args.version, args.channel, args.repository)
        print(('APPLY' if args.apply else 'DRY RUN - no files written') + '\n' + json.dumps(prepared[3], ensure_ascii=False, indent=2))
        if args.apply:
            backup = apply_plan(prepared)
            print('Version files updated. Backup: ' + str(backup))
        return 0
    except (ReleaseError, OSError, UnicodeError) as error:
        print('Release preparation refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
