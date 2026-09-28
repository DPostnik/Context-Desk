#!/usr/bin/env python3
"""Generate the dependency-free native iOS project from shared protocol sources."""
from pathlib import Path
import hashlib
import re
root = Path(__file__).resolve().parents[1]
project = root / 'Mobile/ContextMobile.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
if (project/'project.pbxproj').exists():
    raise SystemExit('Project already exists. Edit the checked-in project directly to preserve signing, resources and UI test targets.')
existing = (project/'project.pbxproj').read_text() if (project/'project.pbxproj').exists() else ''
team = re.search(r'DEVELOPMENT_TEAM = ([A-Z0-9]+);', existing)
def uid(value): return hashlib.sha256(value.encode()).hexdigest()[:24].upper()
files = ['Mobile/ContextMobileApp.swift', 'Mobile/TranscriptScrollController.swift', 'Sources/ContextCore/MobileRemote.swift', 'Sources/ContextCore/MobileRealtime.swift', 'Sources/ContextCore/Localization.swift']
objects = []
def add(name, value): objects.append(f'{uid(name)} = {{ {value} }};')
for f in files:
    add(f, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "../{f}"; sourceTree = SOURCE_ROOT;')
    add('build'+f, f'isa = PBXBuildFile; fileRef = {uid(f)};')
add('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = SOURCE_ROOT;')
add('buildAssets', f'isa = PBXBuildFile; fileRef = {uid("assets")};')
add('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("buildAssets")}); runOnlyForDeploymentPostprocessing = 0;')
add('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = ContextMobile.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('products', f'isa = PBXGroup; children = ({uid("app")}); name = Products; sourceTree = "<group>";')
add('root', f'isa = PBXGroup; children = ({",".join(uid(f) for f in files)},{uid("products")}); sourceTree = "<group>";')
add('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(uid("build"+f) for f in files)}); runOnlyForDeploymentPostprocessing = 0;')
for level in ['project', 'target']:
    for mode in ['Debug','Release']:
        settings = 'ALWAYS_SEARCH_USER_PATHS = NO; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 6.0;'
        if level == 'target':
            settings += ' PRODUCT_BUNDLE_IDENTIFIER = com.contextdesk.mobile; PRODUCT_NAME = ContextMobile; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = "Context Desk"; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; INFOPLIST_KEY_UIRequiresFullScreen = YES; CURRENT_PROJECT_VERSION = 2; MARKETING_VERSION = 0.1.0; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";'
            if team: settings += f' DEVELOPMENT_TEAM = {team.group(1)};'
        settings += ' SWIFT_OPTIMIZATION_LEVEL = "'+('-Onone' if mode == 'Debug' else '-O')+'";'
        add(level+mode, f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {mode};')
    add(level+'configs', f'isa = XCConfigurationList; buildConfigurations = ({uid(level+"Debug")},{uid(level+"Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetconfigs")}; buildPhases = ({uid("sources")},{uid("resources")}); buildRules = (); dependencies = (); name = ContextMobile; productName = ContextMobile; productReference = {uid("app")}; productType = "com.apple.product-type.application";')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,ru); mainGroup = {uid("root")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")});')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid("project")}; }}\n')
print(project)
