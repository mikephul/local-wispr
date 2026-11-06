#!/usr/bin/env python3
"""Create the Xcode application project."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
objects = []
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, value):
    objects.append(f'{ident(name)} = {{ {value} }};')
    return ident(name)
def refs(names): return '(' + ','.join(ident(n) for n in names) + ',)'
files = sorted((root / 'Sources/LocalSTT').glob('*.swift'))
for f in files:
    add(f.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Sources/LocalSTT/{f.name}"; sourceTree = SOURCE_ROOT;')
    add('build'+f.name, f'isa = PBXBuildFile; fileRef = {ident(f.name)};')
add('icon', 'isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/AppIcon.icns; sourceTree = SOURCE_ROOT;')
add('buildicon', f'isa = PBXBuildFile; fileRef = {ident("icon")};')
add('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["buildicon","buildmodelcatalog","buildlicenses"])}; runOnlyForDeploymentPostprocessing = 0;')
add('licenses', 'isa = PBXFileReference; lastKnownFileType = folder; path = Resources/Licenses; sourceTree = SOURCE_ROOT;')
add('buildlicenses', f'isa = PBXBuildFile; fileRef = {ident("licenses")};')
add('signing', 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Config/Signing.xcconfig; sourceTree = SOURCE_ROOT;')
add('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = "local-wispr.app"; sourceTree = BUILT_PRODUCTS_DIR;')
add('products', f'isa = PBXGroup; children = {refs(["app"])}; name = Products; sourceTree = "<group>";')
add('group', f'isa = PBXGroup; children = {refs([f.name for f in files]+["icon","modelcatalog","licenses","signing","products"])}; sourceTree = "<group>";')
add('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["build"+f.name for f in files])}; runOnlyForDeploymentPostprocessing = 0;')
for name, url, version, product in [
    ('whisper', 'https://github.com/argmaxinc/WhisperKit.git', '0.18.0', 'WhisperKit'),
    ('transformers', 'https://github.com/huggingface/swift-transformers.git', '1.1.6', 'Tokenizers')
]:
    add(name+'package', f'isa = XCRemoteSwiftPackageReference; repositoryURL = "{url}"; requirement = {{ kind = exactVersion; version = {version}; }};')
    add(name+'product', f'isa = XCSwiftPackageProductDependency; package = {ident(name+"package")}; productName = {product};')
    add(name+'build', f'isa = PBXBuildFile; productRef = {ident(name+"product")};')
add('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs(["whisperbuild","transformersbuild"])}; runOnlyForDeploymentPostprocessing = 0;')
add('modelcatalog', 'isa = PBXFileReference; lastKnownFileType = text.json; path = Sources/LocalSTT/LocalModels.json; sourceTree = SOURCE_ROOT;')
add('buildmodelcatalog', f'isa = PBXBuildFile; fileRef = {ident("modelcatalog")};')
for mode in ['Debug', 'Release']:
    add('project'+mode, f'isa = XCBuildConfiguration; buildSettings = {{ MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_VERSION = 5.0; ALWAYS_SEARCH_USER_PATHS = NO; }}; name = {mode};')
    add('target'+mode, f'isa = XCBuildConfiguration; baseConfigurationReference = {ident("signing")}; buildSettings = {{ PRODUCT_BUNDLE_IDENTIFIER = com.localstt.mac; PRODUCT_NAME = "local-wispr"; EXECUTABLE_NAME = LocalSTT; INFOPLIST_FILE = Info.plist; ENABLE_APP_SANDBOX = NO; SWIFT_OPTIMIZATION_LEVEL = "{"-Onone" if mode == "Debug" else "-O"}"; }}; name = {mode};')
for name in ['project','target']:
    add(name+'configs', f'isa = XCConfigurationList; buildConfigurations = {refs([name+"Debug",name+"Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('target', f'isa = PBXNativeTarget; buildConfigurationList = {ident("targetconfigs")}; buildPhases = {refs(["sources","frameworks","resources"])}; buildRules = (); dependencies = (); name = LocalSTT; productName = "local-wispr"; productReference = {ident("app")}; productType = "com.apple.product-type.application"; packageProductDependencies = {refs(["whisperproduct","transformersproduct"])};')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }}; buildConfigurationList = {ident("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base,); mainGroup = {ident("group")}; productRefGroup = {ident("products")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["target"])}; packageReferences = {refs(["whisperpackage","transformerspackage"])};')
folder = root / 'LocalSTT.xcodeproj'
folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {ident("project")}; }}\n')
