"""Check a Core RBZ and, optionally, its release manifest without SketchUp."""
import argparse
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from public_release import validate_core

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--artifact', type=Path, default=Path(__file__).resolve().parents[1] / 'dist/su_zhongshu-core.rbz')
parser.add_argument('--repository')
parser.add_argument('--manifest', type=Path)
args = parser.parse_args()
info = validate_core(args.artifact, args.repository)
if args.manifest:
    manifest = json.loads(args.manifest.read_text(encoding='utf-8-sig'))
    expected = {key: info[key] for key in ('repository', 'channel', 'version', 'sha256', 'bytes')}
    expected.update(schemaVersion=1, assetName=args.artifact.name,
                    compatibility={'platforms': ['windows'], 'minSketchUp': 2024, 'maxSketchUp': 2024})
    if manifest != expected:
        raise ValueError('Manifest differs from the final package, repository, or tested compatibility.')
print(json.dumps({'result': 'PASS', **info}, ensure_ascii=True))
