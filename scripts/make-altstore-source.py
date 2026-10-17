#!/usr/bin/env python3
"""Write the SideStore/AltStore source that lets the iPhone install builds itself.

The source lists the newest IPAs published as GitHub Release assets. Each
release also carries this source.json, so the stable URL
https://github.com/<repo>/releases/latest/download/source.json always serves
the newest list.

Usage: make-altstore-source.py IPA RELEASES_JSON OUT --repo owner/name --tag TAG [--previous SOURCE]
RELEASES_JSON is `gh api repos/<repo>/releases` output (may be []); the new
release named by --tag is added from the IPA itself. --previous is the last
published source.json, which keeps each older build's own minimum iOS.
"""
import argparse
import json
import plistlib
import re
import zipfile
from datetime import datetime, timezone
from pathlib import Path

MAX_VERSIONS = 10
IPA_NAME = re.compile(r'^RK-Motion-(?P<version>[^-]+)-build(?P<build>\d+)-[0-9a-z]+\.ipa$')


def ipa_info(ipa):
    with zipfile.ZipFile(ipa) as z:
        name = next(n for n in z.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n))
        return plistlib.loads(z.read(name))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('ipa', type=Path)
    p.add_argument('releases', type=Path)
    p.add_argument('out', type=Path)
    p.add_argument('--repo', required=True)
    p.add_argument('--tag', required=True)
    p.add_argument('--previous', type=Path)
    a = p.parse_args()

    info = ipa_info(a.ipa)
    base = f'https://github.com/{a.repo}'
    raw = f'https://raw.githubusercontent.com/{a.repo}/main'
    current = {
        'version': info['CFBundleShortVersionString'],
        'buildVersion': info['CFBundleVersion'],
        'date': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'localizedDescription': f"Build {info['CFBundleVersion']} ({info.get('RKCommit', '')})",
        'downloadURL': f'{base}/releases/download/{a.tag}/{a.ipa.name}',
        'size': a.ipa.stat().st_size,
        'minOSVersion': info.get('MinimumOSVersion', '17.0'),
    }
    known_min_os = {}
    if a.previous and a.previous.is_file():
        for app in json.loads(a.previous.read_text()).get('apps', []):
            for v in app.get('versions', []):
                known_min_os[v.get('buildVersion')] = v.get('minOSVersion')
    versions = []
    for rel in json.loads(a.releases.read_text()):
        if rel.get('draft') or rel.get('prerelease') or rel.get('tag_name') == a.tag:
            continue
        for asset in rel.get('assets', []):
            m = IPA_NAME.match(asset['name'])
            if m:
                versions.append({
                    'version': m['version'],
                    'buildVersion': m['build'],
                    'date': rel['published_at'],
                    'localizedDescription': f"Build {m['build']}",
                    'downloadURL': asset['browser_download_url'],
                    'size': asset['size'],
                    'minOSVersion': known_min_os.get(m['build']) or current['minOSVersion'],
                })
                break
    versions.sort(key=lambda v: int(v['buildVersion']), reverse=True)
    versions.insert(0, current)

    privacy = {k: v for k, v in info.items() if k.startswith('NS') and k.endswith('UsageDescription')}
    source = {
        'name': 'RK Motion',
        'identifier': f"{info['CFBundleIdentifier']}.source",
        'subtitle': 'On-device AI video editor',
        'website': base,
        'iconURL': f'{raw}/ios/RKMotion/Resources/AppIcon.png',
        'apps': [{
            'name': 'RK Motion',
            'bundleIdentifier': info['CFBundleIdentifier'],
            'developerName': a.repo.split('/')[0],
            'subtitle': 'On-device AI video editor',
            'localizedDescription': 'Pick a video; RK Motion detects what it is and cuts the best '
                                    'moments into one movie with your music, all on the iPhone.',
            'iconURL': f'{raw}/ios/RKMotion/Resources/AppIcon.png',
            'tintColor': '#C8F542',
            'category': 'photo-video',
            'versions': versions[:MAX_VERSIONS],
            'appPermissions': {'entitlements': [], 'privacy': privacy},
        }],
        'news': [],
    }
    a.out.write_text(json.dumps(source, indent=2, ensure_ascii=False) + '\n')
    print(f"{a.out}: {len(source['apps'][0]['versions'])} version(s), newest {current['version']} build {current['buildVersion']}")


if __name__ == '__main__':
    main()
