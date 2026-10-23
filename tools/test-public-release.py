"""Exercise release gates with deliberately corrupted copies of an actual Core RBZ."""
import argparse
import json
import sys
import tempfile
import zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from public_release import VERSION, validate_core

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--artifact', type=Path, default=Path(__file__).resolve().parents[1] / 'dist/su_zhongshu-core.rbz')
args = parser.parse_args()
original = validate_core(args.artifact)
with zipfile.ZipFile(args.artifact) as archive:
    members = {item.filename: archive.read(item.filename) for item in archive.infolist() if not item.is_dir()}

cases = []
cases.append(('unexpected executable', lambda data: data.update({'su_zhongshu/ui/unreviewed.exe': b'MZ'})))
cases.append(('ZIP traversal', lambda data: data.update({'../escape.rb': b'unsafe'})))
cases.append(('missing built-in', lambda data: data.pop('su_zhongshu/plugins/su-scale/manifest.json')))
cases.append(('missing license', lambda data: data.pop('su_zhongshu/LICENSE')))

def bad_catalog(data):
    catalog = json.loads(data['su_zhongshu/market/catalog.json'].decode('utf-8-sig'))
    catalog['plugins'][0]['url'] = 'releases/missing.zip'
    data['su_zhongshu/market/catalog.json'] = json.dumps(catalog).encode('utf-8')

cases.append(('dangling local install', bad_catalog))

def prerelease_in_stable(data):
    config = json.loads(data['su_zhongshu/release.json'].decode('utf-8-sig'))
    config['channel'] = 'stable'
    data['su_zhongshu/release.json'] = json.dumps(config).encode('utf-8')
    for name in ('su_zhongshu.rb', 'su_zhongshu/hub/main.rb'):
        source = data[name].decode('utf-8-sig')
        source = VERSION.sub(lambda match: match.group(0).replace(match.group(1), '0.2.3-beta.1'), source, count=1)
        data[name] = source.encode('utf-8')

cases.append(('prerelease version in stable channel', prerelease_in_stable))
with tempfile.TemporaryDirectory(prefix='release-gates-', dir=args.artifact.resolve().parent) as temporary:
    for number, (name, mutate) in enumerate(cases):
        changed = dict(members)
        mutate(changed)
        target = Path(temporary) / (str(number) + '.rbz')
        with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for member, payload in changed.items():
                archive.writestr(member, payload)
        try:
            validate_core(target)
        except (ValueError, KeyError):
            pass
        else:
            raise AssertionError('Release gate accepted: ' + name)
    try:
        validate_core(args.artifact, 'wrong-destination-owner/wrong-repository')
    except ValueError:
        pass
    else:
        raise AssertionError('Mismatched repository accepted.')
print('PASS: valid Core accepted; executable, traversal, missing plugin/license, dangling install, stable/prerelease mismatch and wrong repository rejected.')
