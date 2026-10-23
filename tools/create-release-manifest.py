"""Generate release metadata from the FINAL RBZ (run again after signing)."""
import argparse
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from public_release import repository, validate_core, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, default=Path(__file__).resolve().parents[1] / 'dist/su_zhongshu-core.rbz')
    parser.add_argument('--repository', required=True, type=repository)
    parser.add_argument('--tag', help='Must exactly match v + packaged version.')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.artifact.name != 'su_zhongshu-core.rbz':
        parser.error('Final artifact must be named su_zhongshu-core.rbz.')
    info = validate_core(args.artifact, args.repository)
    if args.tag and args.tag != 'v' + info['version']:
        parser.error('Tag must equal v' + info['version'])
    manifest = {key: info[key] for key in ('repository', 'channel', 'version', 'sha256', 'bytes')}
    manifest.update(schemaVersion=1, assetName=args.artifact.name,
                    compatibility={'platforms': ['windows'], 'minSketchUp': 2024, 'maxSketchUp': 2024})
    output = args.output or args.artifact.parent / 'release-manifest.json'
    write_json(output, manifest)
    (output.parent / 'SHA256SUMS.txt').write_text(info['sha256'] + '  ' + args.artifact.name + '\n', encoding='ascii')
    print('Manifest ready: ' + str(output))


if __name__ == '__main__':
    main()
