"""Shared, standard-library-only validation for the public Core distribution."""
import copy
import hashlib
import json
import re
import zipfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

BUILTINS = {'su-demo-stats', 'su-roundcorner', 'su-pushpull', 'su-loft', 'su-terrain', 'su-paint', 'su-scale'}
BLOCKED_SUFFIXES = {'.zip', '.rbz', '.dll', '.exe', '.so', '.dylib', '.skp', '.skb', '.log'}
VERSION = re.compile(r"\bVERSION\s*=\s*['\"](\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)['\"]")
REPOSITORY = re.compile(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}')


def repository(value):
    if not REPOSITORY.fullmatch(value):
        raise ValueError('Repository must be GitHub owner/repo, with no URL or placeholder.')
    return value


def version(text):
    found = VERSION.search(text)
    if not found:
        raise ValueError('Missing semantic VERSION constant.')
    return found.group(1)


def public_catalog(original):
    catalog = copy.deepcopy(original)
    catalog.pop('host', None)
    catalog['distribution'] = 'public-core-official-links'
    for item in catalog['plugins']:
        location = urlsplit(item.get('homepage', ''))
        if location.scheme != 'https' or not location.hostname or location.username or location.password:
            raise ValueError('Missing HTTPS official homepage for ' + str(item.get('id')))
        item['official'] = True
        for key in ('url', 'sha256', 'integration', 'adapter_version', 'changelog'):
            item.pop(key, None)
    return catalog


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def validate_core(path, expected_repository=None):
    path = Path(path)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip():
            raise ValueError('ZIP CRC validation failed.')
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate archive members.')
        for name in names:
            normalized = name.replace('\\', '/')
            relative = PurePosixPath(normalized)
            if name != normalized or relative.is_absolute() or '..' in relative.parts or ':' in name:
                raise ValueError('Unsafe archive path: ' + name)
            if relative.parts[0] not in ('su_zhongshu.rb', 'su_zhongshu'):
                raise ValueError('Unexpected root member: ' + name)
            if relative.suffix.lower() in BLOCKED_SUFFIXES or 'vendor' in relative.parts or 'releases' in relative.parts:
                raise ValueError('Third-party/archive/debug content in Core: ' + name)
        def text(name):
            return archive.read(name).decode('utf-8-sig')
        loader_version = version(text('su_zhongshu.rb'))
        if loader_version != version(text('su_zhongshu/hub/main.rb')):
            raise ValueError('Loader/host versions differ.')
        found = {PurePosixPath(name).parts[2] for name in names if name.startswith('su_zhongshu/plugins/') and name.endswith('/manifest.json')}
        if found != BUILTINS:
            raise ValueError('Core must include exactly the seven built-in plugins.')
        for plugin_id in found:
            manifest = json.loads(text(f'su_zhongshu/plugins/{plugin_id}/manifest.json'))
            if manifest.get('dependencies'):
                raise ValueError('Core built-in has an external dependency: ' + plugin_id)
        catalog = json.loads(text('su_zhongshu/market/catalog.json'))
        if public_catalog(catalog) != catalog:
            raise ValueError('Core catalog contains install payloads or an old host entry.')
        config = json.loads(text('su_zhongshu/release.json'))
        if config.get('schemaVersion') != 1 or config.get('assetName') != 'su_zhongshu-core.rbz' or config.get('channel') not in ('preview', 'stable'):
            raise ValueError('Invalid release configuration.')
        if config['channel'] == 'stable' and '-' in loader_version:
            raise ValueError('Stable releases cannot use a prerelease version; use preview or remove the prerelease suffix.')
        configured = config.get('repository')
        if configured:
            repository(configured)
        if expected_repository is not None and configured != repository(expected_repository):
            raise ValueError('Package repository does not match release destination; rebuild with -Repository first.')
        if 'MIT License' not in text('su_zhongshu/LICENSE'):
            raise ValueError('MIT license missing.')
        text('su_zhongshu/THIRD_PARTY_NOTICES.md')
    payload = path.read_bytes()
    return {'version': loader_version, 'repository': configured, 'channel': config['channel'],
            'sha256': hashlib.sha256(payload).hexdigest(), 'bytes': len(payload),
            'plugins': len(found), 'officialLinks': len(catalog['plugins']), 'members': len(names)}
