#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 HandMark.xcodeproj（用于 Xcode 归档 / 上传 App Store Connect）。

为什么需要它：SwiftPM 可执行目标无法被 Xcode 归档成 .app 包（archive 只产出裸可执行文件），
而 App Store 上传必须是 .app → .xcarchive → .pkg。因此这里显式生成一个最小的
macOS Application Target 工程，源文件直接指向 Sources/ 下的 Swift 文件。

用法：python3 tools/make_xcodeproj.py
"""
import os
import hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def oid(key: str) -> str:
    """由字符串稳定地派生一个 24 位十六进制对象 ID（保证多次生成结果一致）。"""
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:24].upper()


APP_DIR = "Sources/HandMark"
# 动态枚举主 target 的全部 Swift 源文件：新增 .swift 自动进入 Xcode 工程，无需手动维护清单。
APP_SOURCES = sorted(
    os.path.join(APP_DIR, f) for f in os.listdir(os.path.join(ROOT, APP_DIR))
    if f.endswith(".swift")
)
CORE_DIR = "Sources/HandMarkCore"
CORE_SOURCES = sorted(
    os.path.join(CORE_DIR, f) for f in os.listdir(os.path.join(ROOT, CORE_DIR))
    if f.endswith(".swift")
)
# 应用图标（静态 icns，暂不统一源） + 菜单栏深色/浅色图标（按系统外观切换）。
RESOURCES = [
    "Resources/AppIcon.icns",
    "assets/menubar/MenuBarIconDark.png",
    "assets/menubar/MenuBarIconLight.png",
]

PROJECT = oid("PBXProject")
TARGET = oid("PBXNativeTarget")
PRODUCT_REF = oid("product HandMark.app")
MAIN_GROUP = oid("group main")
APP_GROUP = oid("group HandMark")
CORE_GROUP = oid("group HandMarkCore")
RES_GROUP = oid("group Resources")
PRODUCTS_GROUP = oid("group Products")
FRAMEWORKS_GROUP = oid("group Frameworks")
SOURCES_PHASE = oid("phase sources")
RESOURCES_PHASE = oid("phase resources")
FRAMEWORKS_PHASE = oid("phase frameworks")
PROJ_CONFIG_LIST = oid("configlist project")
TARGET_CONFIG_LIST = oid("configlist target")
PROJ_DEBUG = oid("config project debug")
PROJ_RELEASE = oid("config project release")
TARGET_DEBUG = oid("config target debug")
TARGET_RELEASE = oid("config target release")
COREAUDIO_REF = oid("framework CoreAudio")

lines = []
w = lines.append

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")
w("")
w("/* Begin PBXBuildFile section */")

build_files = []


def file_ref(path: str, kind: str, group_key: str, ref_path: str = None):
    key = "file " + path
    fid = oid(key)
    bid = oid("buildfile " + path)
    name = os.path.basename(path)
    w("\t\t%s /* %s in %s */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
      % (bid, name, group_key, fid, name))
    build_files.append((fid, ref_path or name, kind, name))
    return fid, bid


src_build_files = []
for p in APP_SOURCES + CORE_SOURCES:
    fid, bid = file_ref(p, "sourcecode.swift", "Sources")
    src_build_files.append(bid)

res_build_files = []
for p in RESOURCES:
    kind = "image.png" if p.lower().endswith(".png") else "image.icns"
    fid, bid = file_ref(p, kind, "Resources", ref_path=p)
    res_build_files.append(bid)

w("/* End PBXBuildFile section */")
w("")

# ---------------------------------------------------------------- file refs
w("/* Begin PBXFileReference section */")
w("\t\t%s /* HandMark.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = HandMark.app; sourceTree = BUILT_PRODUCTS_DIR; };"
  % PRODUCT_REF)
for fid, path, kind, name in build_files:
    w("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = \"<group>\"; };"
      % (fid, name, kind, path))
w("\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; };"
  % oid("file Info.plist"))
w("\t\t%s /* HandMark-Direct.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = HandMark-Direct.entitlements; sourceTree = \"<group>\"; };"
  % oid("file HandMark-Direct.entitlements"))
w("\t\t%s /* CoreAudio.framework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = CoreAudio.framework; path = System/Library/Frameworks/CoreAudio.framework; sourceTree = SDKROOT; };"
  % COREAUDIO_REF)
w("/* End PBXFileReference section */")
w("")

# ------------------------------------------------------------- frameworks
w("/* Begin PBXFrameworksBuildPhase section */")
w("\t\t%s /* Frameworks */ = {" % FRAMEWORKS_PHASE)
w("\t\t\tisa = PBXFrameworksBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
w("\t\t\t\t%s /* CoreAudio.framework in Frameworks */," % oid("buildfile CoreAudio.framework"))
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXFrameworksBuildPhase section */")
w("")

# ---------------------------------------------------------------- groups
w("/* Begin PBXGroup section */")
w("\t\t%s = {" % MAIN_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* Info.plist */," % oid("file Info.plist"))
w("\t\t\t\t%s /* HandMark-Direct.entitlements */," % oid("file HandMark-Direct.entitlements"))
w("\t\t\t\t%s /* HandMark */," % APP_GROUP)
w("\t\t\t\t%s /* HandMarkCore */," % CORE_GROUP)
w("\t\t\t\t%s /* Resources */," % RES_GROUP)
w("\t\t\t\t%s /* Products */," % PRODUCTS_GROUP)
w("\t\t\t);")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* HandMark */ = {" % APP_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for p in APP_SOURCES:
    w("\t\t\t\t%s /* %s */," % (oid("file " + p), os.path.basename(p)))
w("\t\t\t);")
w("\t\t\tname = HandMark;")
w("\t\t\tpath = Sources/HandMark;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* HandMarkCore */ = {" % CORE_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for p in CORE_SOURCES:
    w("\t\t\t\t%s /* %s */," % (oid("file " + p), os.path.basename(p)))
w("\t\t\t);")
w("\t\t\tname = HandMarkCore;")
w("\t\t\tpath = %s;" % CORE_DIR)
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* Resources */ = {" % RES_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for p in RESOURCES:
    w("\t\t\t\t%s /* %s */," % (oid("file " + p), os.path.basename(p)))
w("\t\t\t);")
w("\t\t\tname = Resources;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* Products */ = {" % PRODUCTS_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* HandMark.app */," % PRODUCT_REF)
w("\t\t\t);")
w("\t\t\tname = Products;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* Frameworks */ = {" % FRAMEWORKS_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* CoreAudio.framework */," % COREAUDIO_REF)
w("\t\t\t);")
w("\t\t\tname = Frameworks;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")
w("/* End PBXGroup section */")
w("")

# ------------------------------------------------------------ native target
w("/* Begin PBXNativeTarget section */")
w("\t\t%s /* HandMark */ = {" % TARGET)
w("\t\t\tisa = PBXNativeTarget;")
w("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"HandMark\" */;" % TARGET_CONFIG_LIST)
w("\t\t\tbuildPhases = (")
w("\t\t\t\t%s /* Sources */," % SOURCES_PHASE)
w("\t\t\t\t%s /* Frameworks */," % FRAMEWORKS_PHASE)
w("\t\t\t\t%s /* Resources */," % RESOURCES_PHASE)
w("\t\t\t);")
w("\t\t\tbuildRules = (")
w("\t\t\t);")
w("\t\t\tdependencies = (")
w("\t\t\t);")
w("\t\t\tname = HandMark;")
w("\t\t\tproductName = HandMark;")
w("\t\t\tproductReference = %s /* HandMark.app */;" % PRODUCT_REF)
w("\t\t\tproductType = \"com.apple.product-type.application\";")
w("\t\t};")
w("/* End PBXNativeTarget section */")
w("")

# ---------------------------------------------------------------- project
w("/* Begin PBXProject section */")
w("\t\t%s /* Project object */ = {" % PROJECT)
w("\t\t\tisa = PBXProject;")
w("\t\t\tattributes = {")
w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
w("\t\t\t\tLastSwiftUpdateCheck = 2600;")
w("\t\t\t\tLastUpgradeCheck = 2600;")
w("\t\t\t\tTargetAttributes = {")
w("\t\t\t\t\t%s = {" % TARGET)
w("\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;")
w("\t\t\t\t\t};")
w("\t\t\t\t};")
w("\t\t\t};")
w("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"HandMark\" */;" % PROJ_CONFIG_LIST)
w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
w("\t\t\tdevelopmentRegion = en;")
w("\t\t\thasScannedForEncodings = 0;")
w("\t\t\tknownRegions = (")
w("\t\t\t\ten,")
w("\t\t\t\tBase,")
w("\t\t\t);")
w("\t\t\tmainGroup = %s;" % MAIN_GROUP)
w("\t\t\tproductRefGroup = %s /* Products */;" % PRODUCTS_GROUP)
w("\t\t\tprojectDirPath = \"\";")
w("\t\t\tprojectRoot = \"\";")
w("\t\t\ttargets = (")
w("\t\t\t\t%s /* HandMark */," % TARGET)
w("\t\t\t);")
w("\t\t};")
w("/* End PBXProject section */")
w("")

# ------------------------------------------------------------ build phases
w("/* Begin PBXResourcesBuildPhase section */")
w("\t\t%s /* Resources */ = {" % RESOURCES_PHASE)
w("\t\t\tisa = PBXResourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for bid in res_build_files:
    w("\t\t\t\t%s," % bid)
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXResourcesBuildPhase section */")
w("")

w("/* Begin PBXSourcesBuildPhase section */")
w("\t\t%s /* Sources */ = {" % SOURCES_PHASE)
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for bid in src_build_files:
    w("\t\t\t\t%s," % bid)
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXSourcesBuildPhase section */")
w("")

# ----------------------------------------------------------- build configs
COMMON_PROJECT = [
    ("ALWAYS_SEARCH_USER_PATHS", "NO"),
    ("CLANG_ENABLE_MODULES", "YES"),
    ("CLANG_ENABLE_OBJC_ARC", "YES"),
    ("COPY_PHASE_STRIP", "NO"),
    ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
    ("GCC_C_LANGUAGE_STANDARD", "gnu17"),
    ("GCC_NO_COMMON_BLOCKS", "YES"),
    ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
    ("GCC_WARN_UNUSED_FUNCTION", "YES"),
    ("GCC_WARN_UNUSED_VARIABLE", "YES"),
    ("MACOSX_DEPLOYMENT_TARGET", "13.0"),
    ("MTL_ENABLE_DEBUG_INFO", "NO"),
    ("SDKROOT", "macosx"),
    ("SWIFT_EMIT_LOC_STRINGS", "YES"),
]

COMMON_TARGET = [
    ("ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS", "YES"),
    ("CLANG_ENABLE_MODULES", "YES"),
    ("CODE_SIGN_ENTITLEMENTS", "HandMark-Direct.entitlements"),
    ("CODE_SIGN_STYLE", "Automatic"),
    ("COMBINE_HIDPI_IMAGES", "YES"),
    ("CURRENT_PROJECT_VERSION", "1"),
    ("DEVELOPMENT_TEAM", "wangguangzheng"),
    ("ENABLE_HARDENED_RUNTIME", "YES"),
    ("ENABLE_APP_SANDBOX", "NO"),
    ("GENERATE_INFOPLIST_FILE", "NO"),
    ("INFOPLIST_FILE", "Info.plist"),
    ("LD_RUNPATH_SEARCH_PATHS", "\"$(inherited) @executable_path/../Frameworks\""),
    ("MACOSX_DEPLOYMENT_TARGET", "13.0"),
    ("MARKETING_VERSION", "1.0"),
    ("PRODUCT_BUNDLE_IDENTIFIER", "com.handmark.HandMark"),
    ("PRODUCT_NAME", "HandMark"),
    ("SKIP_INSTALL", "NO"),
    ("SWIFT_VERSION", "5.0"),
]


def emit_config(cid, name, pairs, extra=None):
    w("\t\t%s /* %s */ = {" % (cid, name))
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    for k, v in pairs:
        w("\t\t\t\t%s = %s;" % (k, v))
    if extra:
        for k, v in extra:
            w("\t\t\t\t%s = %s;" % (k, v))
    w("\t\t\t};")
    w("\t\t\tname = %s;" % name)
    w("\t\t};")


w("/* Begin XCBuildConfiguration section */")
emit_config(PROJ_DEBUG, "Debug", COMMON_PROJECT, [
    ("DEBUG_INFORMATION_FORMAT", "dwarf"),
    ("ENABLE_TESTABILITY", "YES"),
    ("GCC_OPTIMIZATION_LEVEL", "0"),
    ("MTL_ENABLE_DEBUG_INFO", "YES"),
    ("ONLY_ACTIVE_ARCH", "YES"),
    ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "\"$(inherited) DEBUG\""),
    ("SWIFT_OPTIMIZATION_LEVEL", "\"-Onone\""),
])
emit_config(PROJ_RELEASE, "Release", COMMON_PROJECT, [
    ("DEBUG_INFORMATION_FORMAT", "\"dwarf-with-dsym\""),
    ("ENABLE_NS_ASSERTIONS", "NO"),
    ("SWIFT_COMPILATION_MODE", "wholemodule"),
])
emit_config(TARGET_DEBUG, "Debug", COMMON_TARGET, [
    ("CODE_SIGN_IDENTITY", "\"Apple Development\""),
    ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "\"$(inherited) DEBUG\""),
])
emit_config(TARGET_RELEASE, "Release", COMMON_TARGET, [
    ("CODE_SIGN_IDENTITY", "\"Developer ID Application\""),
])
w("/* End XCBuildConfiguration section */")
w("")

w("/* Begin XCConfigurationList section */")
w("\t\t%s /* Build configuration list for PBXProject \"HandMark\" */ = {" % PROJ_CONFIG_LIST)
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w("\t\t\t\t%s /* Debug */," % PROJ_DEBUG)
w("\t\t\t\t%s /* Release */," % PROJ_RELEASE)
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")
w("\t\t%s /* Build configuration list for PBXNativeTarget \"HandMark\" */ = {" % TARGET_CONFIG_LIST)
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w("\t\t\t\t%s /* Debug */," % TARGET_DEBUG)
w("\t\t\t\t%s /* Release */," % TARGET_RELEASE)
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")
w("/* End XCConfigurationList section */")
w("\t};")
w("\trootObject = %s /* Project object */;" % PROJECT)
w("}")

proj_dir = os.path.join(ROOT, "HandMark.xcodeproj")
os.makedirs(proj_dir, exist_ok=True)
with open(os.path.join(proj_dir, "project.pbxproj"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

# shared scheme（让 xcodebuild -scheme HandMark 可用）
scheme_path = os.path.join(proj_dir, "xcshareddata", "xcschemes", "HandMark.xcscheme")
os.makedirs(os.path.dirname(scheme_path), exist_ok=True)
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TARGET}"
               BuildableName = "HandMark.app"
               BlueprintName = "HandMark"
               ReferencedContainer = "container:HandMark.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{TARGET}"
            BuildableName = "HandMark.app"
            BlueprintName = "HandMark"
            ReferencedContainer = "container:HandMark.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{TARGET}"
            BuildableName = "HandMark.app"
            BlueprintName = "HandMark"
            ReferencedContainer = "container:HandMark.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
with open(scheme_path, "w", encoding="utf-8") as f:
    f.write(scheme)

print("已生成:", proj_dir)
