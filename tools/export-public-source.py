"""Export an allowlisted, independent public source tree; never delete an existing export."""
import argparse
import json
import shutil
import sys
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from public_release import BUILTINS, BLOCKED_SUFFIXES, public_catalog, repository, write_json

ROOT_FILES = ('LICENSE', 'THIRD_PARTY_NOTICES.md', '.gitignore', 'package.json', 'package-lock.json')
TOOLS = ('build-rbz.ps1', 'public_release.py', 'create-release-manifest.py', 'verify-public-release.py', 'test-public-release.py', 'export-public-source.py', 'prepare-next-release.py')
TESTS = ('run_all.rb', 'test_host_boot.rb', 'test_backend_contract.rb', 'test_builtin_outcomes.rb',
         'test_command_results.rb', 'test_geom.rb', 'test_plugin_contracts.rb', 'test_settings_migration.rb',
         'test_updates.rb', 'test_update_bridge.rb', 'ui-test-helpers.cjs', 'verify-diagnostics.cjs', 'verify-host-updates.cjs', 'test_prepare_next_release.py')
DOCS = ('github-setup.md', 'public-release-readme.md', 'public-release-notes.md', 'public-release-checklist.md', 'skill-sharing.md', 'maintenance-commands.md')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--repository', type=repository)
    args = parser.parse_args()
    root = args.root.resolve()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8]
    destination = root / 'dist/public-source' / ('tt-su-hub-' + stamp)
    destination.mkdir(parents=True, exist_ok=False)

    def copy_file(relative):
        source = root / relative
        if source.is_symlink() or not source.is_file():
            raise ValueError('Missing or symbolic-link allowlist member: ' + str(relative))
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

    for relative in ROOT_FILES:
        copy_file(relative)
    for folder in ('src/hub', 'src/ui', '.github'):
        for source in sorted((root / folder).rglob('*')):
            if source.is_symlink():
                raise ValueError('Symbolic links are not allowed: ' + str(source))
            if source.is_file():
                if source.suffix.lower() not in ('.rb', '.html', '.js', '.css', '.svg', '.png', '.json', '.yml', '.yaml', '.md'):
                    raise ValueError('Non-source file in public source: ' + str(source))
                copy_file(source.relative_to(root))
    for plugin_id in sorted(BUILTINS):
        for relative in (f'src/plugins/{plugin_id}/manifest.json', f'src/plugins/{plugin_id}/{plugin_id}.rb'):
            copy_file(relative)
    for name in TOOLS:
        copy_file('tools/' + name)
    for name in TESTS:
        copy_file('tests/' + name)
    for name in DOCS:
        copy_file('docs/' + name)
    for relative in ('skills/tt-su-hub/SKILL.md', 'skills/tt-su-hub/agents/openai.yaml'):
        copy_file(relative)
    for source in sorted((root / 'skills/tt-su-hub/references').glob('*.md')):
        copy_file(source.relative_to(root))
    copy_file('docs/images/about-update.png')
    copy_file('src/su_zhongshu.rb')
    config = json.loads((root / 'src/release.json').read_text(encoding='utf-8-sig'))
    if args.repository:
        config['repository'] = args.repository
    write_json(destination / 'src/release.json', config)
    original_catalog = json.loads((root / 'src/market/catalog.json').read_text(encoding='utf-8-sig'))
    write_json(destination / 'src/market/catalog.json', public_catalog(original_catalog))
    readme = (root / 'docs/public-release-readme.md').read_text(encoding='utf-8-sig')
    readme = readme.replace('(github-setup.md)', '(docs/github-setup.md)').replace('(../LICENSE)', '(LICENSE)').replace('(../THIRD_PARTY_NOTICES.md)', '(THIRD_PARTY_NOTICES.md)')
    readme = readme.replace('(skill-sharing.md)', '(docs/skill-sharing.md)').replace('(maintenance-commands.md)', '(docs/maintenance-commands.md)').replace('(images/about-update.png)', '(docs/images/about-update.png)')
    readme = readme.replace('（在仓库首页请打开 `docs/github-setup.md`）', '').replace('；在仓库首页请直接打开根目录对应文件', '')
    (destination / 'README.md').write_text(readme, encoding='utf-8')

    # Old diagnostics test stores browser fixtures beside private planning evidence.
    # Keep the test assertions but redirect only its output in the exported copy.
    test_path = destination / 'tests/verify-diagnostics.cjs'
    test_text = test_path.read_text(encoding='utf-8-sig')
    test_path.write_text(test_text.replace("'docs/product-plan-2026-10-18/upgrade-2026-10-22'", "'test-results'"), encoding='utf-8')
    # Public tests resolve the pinned npm dependency; no local skill paths are needed.
    helper = destination / 'tests/ui-test-helpers.cjs'
    helper.write_text("const path = require('path');\nconst { pathToFileURL } = require('url');\nconst { chromium } = require('playwright');\nconst root = path.resolve(__dirname, '..');\nmodule.exports = { chromium, root, fileURL: name => pathToFileURL(path.join(root, 'src/ui', name + '.html')).href };\n", encoding='utf-8')

    files = sorted(path for path in destination.rglob('*') if path.is_file())
    for path in files:
        relative = path.relative_to(destination)
        if path.suffix.lower() in BLOCKED_SUFFIXES or any(part in {'vendor', 'runtime', '.git', 'fixtures', 'releases'} for part in relative.parts):
            raise ValueError('Unexpected private or binary member: ' + str(relative))
    archive_path = destination.with_suffix('.zip')
    with zipfile.ZipFile(archive_path, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, str(Path('tt-su-hub') / path.relative_to(destination)))
    report = {'sourceDirectory': str(destination), 'sourceArchive': str(archive_path),
              'files': len(files), 'repository': config['repository'], 'catalogLinks': len(original_catalog['plugins'])}
    write_json(root / 'dist/public-source/latest-export.json', report)
    print(json.dumps(report, ensure_ascii=True))


if __name__ == '__main__':
    main()
