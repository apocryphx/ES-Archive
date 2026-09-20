#!/usr/bin/env python3
"""Build a local ChatGPT/Codex plugin from the canonical Codex skills.

Does not register a marketplace, change client settings, or install the plugin.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/ES Archive MCP.app'))
    parser.add_argument('--author', default='ChatGPT', help='Archive persona shared by clients using this plugin')
    parser.add_argument('--output', type=Path, required=True, help='New output directory (must not exist)')
    args = parser.parse_args()
    if not args.author.strip():
        parser.error('--author must not be empty')
    app = args.app.expanduser().resolve()
    with (app / 'Contents/Info.plist').open('rb') as f:
        info = plistlib.load(f)
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error(f'App executable is unavailable: {executable}')
    if info['CFBundleExecutable'] != 'ES Archive MCP':
        parser.error('Choose ES Archive MCP.app; the Server app does not serve STDIO')
    output = args.output.expanduser().absolute()
    if output.exists():
        parser.error(f'Output already exists: {output}')
    repo = Path(__file__).resolve().parent.parent
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        stage = Path(temporary) / 'package'
        plugin = stage / 'es-archive'
        shutil.copytree(repo / 'packaging/chatgpt/es-archive', plugin)
        for skill in sorted((repo / 'skills/codex').iterdir()):
            if (skill / 'SKILL.md').is_file():
                shutil.copytree(skill, plugin / 'skills' / skill.name)
        if not list((plugin / 'skills').glob('*/SKILL.md')):
            parser.error('No Codex skills found')
        config = {'mcpServers': {'es-archive': {
            'command': str(executable), 'args': ['--author', args.author]
        }}}
        (plugin / '.mcp.json').write_text(json.dumps(config, indent=2) + '\n')
        shutil.copy2(repo / 'packaging/chatgpt/README.md', plugin / 'README.md')
        shutil.copy2(repo / 'LICENSE', plugin / 'LICENSE')
        with zipfile.ZipFile(stage / 'es-archive.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
            for file in sorted(plugin.rglob('*')):
                if file.is_file():
                    archive.write(file, file.relative_to(stage))
        stage.rename(output)
    print(f'Plugin: {output / "es-archive"}')
    print(f'ZIP: {output / "es-archive.zip"}')
    print(f'Archive author: {args.author}')


if __name__ == '__main__':
    main()
