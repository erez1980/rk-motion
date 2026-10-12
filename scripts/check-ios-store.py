#!/usr/bin/env python3
"""Fail early for Store metadata mistakes, including generated resource drift."""
import plistlib
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
app = ROOT / 'ios/RKMotion'
privacy = plistlib.loads((app / 'PrivacyInfo.xcprivacy').read_bytes())
reasons = {item['NSPrivacyAccessedAPIType']: item['NSPrivacyAccessedAPITypeReasons']
           for item in privacy['NSPrivacyAccessedAPITypes']}
assert reasons['NSPrivacyAccessedAPICategoryUserDefaults'] == ['CA92.1']
assert reasons['NSPrivacyAccessedAPICategoryDiskSpace'] == ['E174.1']
assert privacy['NSPrivacyTracking'] is False
assert privacy['NSPrivacyCollectedDataTypes'] == []
icon = (app / 'Assets.xcassets/AppIcon.appiconset/icon.png').read_bytes()
assert icon[:8] == b'\x89PNG\r\n\x1a\n'
width, height, depth, color = struct.unpack('>IIBB', icon[16:26])
assert (width, height, depth, color) == (1024, 1024, 8, 2), 'Primary icon must be opaque RGB'
assert icon == (app / 'Resources/AppIcon.png').read_bytes(), 'Regenerate the Xcode project'
project = (ROOT / 'ios/RKMotion.xcodeproj/project.pbxproj').read_text()
assert 'path = PrivacyInfo.xcprivacy' in project
privacy_ref = project.split('path = PrivacyInfo.xcprivacy')[0].rsplit('\n', 1)[-1].split(' = ')[0].strip()
assert f'fileRef = {privacy_ref};' in project
assert 'NSPhotoLibraryAddUsageDescription' in plistlib.loads((app / 'Info.plist').read_bytes())
print('Store metadata checks passed (signing, App Store validation and device tests remain separate).')
