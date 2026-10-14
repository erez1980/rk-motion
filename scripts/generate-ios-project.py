#!/usr/bin/env python3
"""Generate a dependency-free Xcode project; no XcodeGen/CocoaPods required."""
import hashlib
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"
def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
objects = []
def add(name, body):
    objects.append(f"\t\t{uid(name)} = {{ {body} }};")
    return uid(name)
files = sorted((IOS / "RKMotion").glob("*.swift"))
refs, builds = [], []
for file in files:
    refs.append(add(file.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{file.name}"; sourceTree = "<group>";'))
    builds.append(add("build-" + file.name, f'isa = PBXBuildFile; fileRef = {uid(file.name)};'))
iconset = IOS / "RKMotion" / "Assets.xcassets" / "AppIcon.appiconset"
iconset.mkdir(parents=True, exist_ok=True)
shutil.copyfile(IOS / "RKMotion" / "Resources" / "AppIcon.png", iconset / "icon.png")
(iconset / "Contents.json").write_text(json.dumps({"images": [{"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2))
(iconset.parent / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
refs.append(add("assets", 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";'))
refs.append(add("info", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";'))
refs.append(add("privacy", 'isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>";'))
refs.append(add("strings", 'isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = Localizable.xcstrings; sourceTree = "<group>";'))
refs.append(add("info-strings", 'isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = InfoPlist.xcstrings; sourceTree = "<group>";'))
# Rubik, the web app's typeface, so both read as one product.
refs.append(add("font", 'isa = PBXFileReference; lastKnownFileType = file; path = Fonts/Rubik.ttf; sourceTree = "<group>";'))
refs.append(add("font-license", 'isa = PBXFileReference; lastKnownFileType = text; path = Fonts/OFL.txt; sourceTree = "<group>";'))
add("font-build", f'isa = PBXBuildFile; fileRef = {uid("font")};')
add("font-license-build", f'isa = PBXBuildFile; fileRef = {uid("font-license")};')
add("strings-build", f'isa = PBXBuildFile; fileRef = {uid("strings")};')
add("info-strings-build", f'isa = PBXBuildFile; fileRef = {uid("info-strings")};')
add("privacy-build", f'isa = PBXBuildFile; fileRef = {uid("privacy")};')
add("asset-build", f'isa = PBXBuildFile; fileRef = {uid("assets")};')
add("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = RKMotion.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_files = sorted((IOS / "RKMotionTests").glob("*.swift"))
test_refs, test_builds = [], []
for file in test_files:
    test_refs.append(add("test-" + file.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{file.name}"; sourceTree = "<group>";'))
    test_builds.append(add("test-build-" + file.name, f'isa = PBXBuildFile; fileRef = {uid("test-" + file.name)};'))
add("test-product", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = RKMotionTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
add("test-group", f'isa = PBXGroup; children = ({",".join(test_refs)},); path = RKMotionTests; sourceTree = "<group>";')
add("test-sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(test_builds)},); runOnlyForDeploymentPostprocessing = 0;')
add("test-frameworks", 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
add("test-proxy", f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target")}; remoteInfo = RKMotion;')
add("test-dependency", f'isa = PBXTargetDependency; target = {uid("target")}; targetProxy = {uid("test-proxy")};')
for kind in ("Debug", "Release"):
    add("test-" + kind, f'isa = XCBuildConfiguration; name = {kind}; buildSettings = {{GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; SDKROOT = iphoneos; PRODUCT_BUNDLE_IDENTIFIER = com.rkmotion.tests; PRODUCT_NAME = RKMotionTests; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/RKMotion.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/RKMotion"; BUNDLE_LOADER = "$(TEST_HOST)"; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks";}};')
add("test-configs", f'isa = XCConfigurationList; buildConfigurations = ({uid("test-Debug")},{uid("test-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
add("test-target", f'isa = PBXNativeTarget; buildConfigurationList = {uid("test-configs")}; buildPhases = ({uid("test-sources")},{uid("test-frameworks")},); buildRules = (); dependencies = ({uid("test-dependency")},); name = RKMotionTests; productName = RKMotionTests; productReference = {uid("test-product")}; productType = "com.apple.product-type.bundle.unit-test";')
add("products", f'isa = PBXGroup; children = ({uid("app")},{uid("test-product")},); name = Products; sourceTree = "<group>";')
add("sources-group", f'isa = PBXGroup; children = ({",".join(refs)},); path = RKMotion; sourceTree = "<group>";')
add("main", f'isa = PBXGroup; children = ({uid("sources-group")},{uid("test-group")},{uid("products")},); sourceTree = "<group>";')
add("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
add("resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("asset-build")},{uid("privacy-build")},{uid("strings-build")},{uid("info-strings-build")},{uid("font-build")},{uid("font-license-build")},); runOnlyForDeploymentPostprocessing = 0;')
# YouTubeKit fetches a song's audio from a YouTube link, on the device.
add("ytkit-package", 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/alexeichhorn/YouTubeKit.git"; requirement = {kind = exactVersion; version = 0.4.9;};')
add("ytkit-product", f'isa = XCSwiftPackageProductDependency; package = {uid("ytkit-package")}; productName = YouTubeKit;')
add("ytkit-build", f'isa = PBXBuildFile; productRef = {uid("ytkit-product")};')
add("frameworks", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({uid("ytkit-build")},); runOnlyForDeploymentPostprocessing = 0;')
for kind in ("Debug", "Release"):
    # Packages build only the active architecture in Debug. The app must match,
    # or its other slice cannot find YouTubeKit (Xcode's own Debug default).
    debug_arch = " ONLY_ACTIVE_ARCH = YES;" if kind == "Debug" else ""
    add("project-" + kind, f'isa = XCBuildConfiguration; name = {kind}; buildSettings = {{CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0;{debug_arch}}};')
    settings = '''ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
        CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 3; MARKETING_VERSION = 0.20.0; RK_COMMIT = local;
        GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = RKMotion/Info.plist;
        IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = com.rkmotion.companion;
        PRODUCT_NAME = RKMotion; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1;
        SUPPORTS_MACCATALYST = NO; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
        SWIFT_EMIT_LOC_STRINGS = YES; RK_BACKGROUND_GPU_ENABLED = NO;'''
    settings += 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES;' if kind == "Debug" else 'SWIFT_OPTIMIZATION_LEVEL = "-O";'
    add("target-" + kind, f'isa = XCBuildConfiguration; name = {kind}; buildSettings = {{{settings}}};')
for prefix in ("project", "target"):
    add(prefix + "-configs", f'isa = XCConfigurationList; buildConfigurations = ({uid(prefix + "-Debug")},{uid(prefix + "-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add("target", f'isa = PBXNativeTarget; buildConfigurationList = {uid("target-configs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")},); buildRules = (); dependencies = (); name = RKMotion; packageProductDependencies = ({uid("ytkit-product")},); productName = RKMotion; productReference = {uid("app")}; productType = "com.apple.product-type.application";')
add("project", f'isa = PBXProject; attributes = {{LastUpgradeCheck = 1640;}}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = he; hasScannedForEncodings = 0; knownRegions = (he,en,Base,); mainGroup = {uid("main")}; packageReferences = ({uid("ytkit-package")},); productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},{uid("test-target")},);')
project = IOS / "RKMotion.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text('// !$*UTF8*$!\n{\narchiveVersion = 1; classes = {}; objectVersion = 56;\nobjects = {\n' + '\n'.join(objects) + '\n};\nrootObject = ' + uid("project") + ';\n}\n')
scheme = project / "xcshareddata" / "xcschemes"
scheme.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="RKMotion.app" BlueprintName="RKMotion" ReferencedContainer="container:RKMotion.xcodeproj"/>'
(scheme / "RKMotion.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("test-target")}" BuildableName="RKMotionTests.xctest" BlueprintName="RKMotionTests" ReferencedContainer="container:RKMotion.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>\n''')
print(project)
