#!/usr/bin/env python3
"""Regenerate GitFolderUploader.xcodeproj from the source tree.

The generated project is committed to the repository, so neither developers nor
CI need this script to build. Run it only after adding, removing or moving
files:

    python3 Scripts/generate_xcodeproj.py

Object identifiers are derived from a hash of each object's role and path, so
regenerating produces a byte-identical project and diffs stay readable.
"""

from __future__ import annotations

import hashlib
import os
import sys

# --------------------------------------------------------------------------- #
# Project configuration
# --------------------------------------------------------------------------- #

PROJECT_NAME = "GitFolderUploader"
SOURCE_DIR = "GitFolderUploader"          # relative to the repository root
BUNDLE_ID = "com.gitfolderuploader.app"
DEPLOYMENT_TARGET = "16.0"
SWIFT_VERSION = "5.0"
MARKETING_VERSION = "1.0.0"
CURRENT_PROJECT_VERSION = "1"
KNOWN_REGIONS = ["en", "ar", "Base"]
LOCALIZED_RESOURCE = "Localizable.strings"
LOCALIZATIONS = ["en", "ar"]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def uid(*parts: str) -> str:
    """Deterministic 24 character hexadecimal object identifier."""
    digest = hashlib.md5("::".join(parts).encode("utf-8")).hexdigest()
    return digest[:24].upper()


def file_type(name: str) -> str:
    """Maps a file name to the Xcode `lastKnownFileType` value."""
    mapping = {
        ".swift": "sourcecode.swift",
        ".h": "sourcecode.c.h",
        ".m": "sourcecode.c.objc",
        ".plist": "text.plist.xml",
        ".strings": "text.plist.strings",
        ".json": "text.json",
        ".png": "image.png",
        ".md": "net.daringfireball.markdown",
        ".xcassets": "folder.assetcatalog",
    }
    return mapping.get(os.path.splitext(name)[1], "text")


# --------------------------------------------------------------------------- #
# Source tree discovery
# --------------------------------------------------------------------------- #


class Node:
    """A group (directory) in the project navigator."""

    def __init__(self, name: str, path: str):
        self.name = name
        self.path = path              # repository-relative
        self.groups: list["Node"] = []
        self.files: list[str] = []    # repository-relative file paths

    @property
    def uid(self) -> str:
        return uid("group", self.path)


def build_tree(directory: str) -> Node:
    """Walks `directory`, skipping localization folders and hidden entries."""
    node = Node(os.path.basename(directory), directory)
    absolute = os.path.join(ROOT, directory)

    for entry in sorted(os.listdir(absolute)):
        if entry.startswith("."):
            continue
        relative = os.path.join(directory, entry)
        full = os.path.join(ROOT, relative)

        if os.path.isdir(full):
            if entry.endswith(".lproj"):
                continue              # handled by the variant group
            if entry.endswith(".xcassets"):
                node.files.append(relative)
                continue
            node.groups.append(build_tree(relative))
        else:
            node.files.append(relative)

    return node


def collect(node: Node, sources: list[str], resources: list[str]) -> None:
    """Splits discovered files into the Sources and Resources build phases."""
    for path in node.files:
        name = os.path.basename(path)
        if name.endswith(".swift"):
            sources.append(path)
        elif name.endswith(".xcassets"):
            resources.append(path)
        elif name == "Info.plist":
            pass                      # referenced through INFOPLIST_FILE only
        else:
            resources.append(path)
    for child in node.groups:
        collect(child, sources, resources)


# --------------------------------------------------------------------------- #
# pbxproj emission
# --------------------------------------------------------------------------- #


def quote(value: str) -> str:
    """Quotes a value when the old-style plist grammar requires it."""
    if value == "":
        return '""'
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./")
    if all(character in allowed for character in value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def build_settings(configuration: str) -> dict:
    """Project-level build settings shared by both configurations."""
    debug = configuration == "Debug"
    settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "MTL_FAST_MATH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": SWIFT_VERSION,
        # The app ships unsigned from CI; signing is opt-in per developer.
        "CODE_SIGNING_ALLOWED": "NO",
        "CODE_SIGNING_REQUIRED": "NO",
        "CODE_SIGN_IDENTITY": "",
        "CODE_SIGN_STYLE": "Manual",
        "DEVELOPMENT_TEAM": "",
        "PROVISIONING_PROFILE_SPECIFIER": "",
    }
    if debug:
        settings.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": "(\"DEBUG=1\", \"$(inherited)\", )",
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        })
    else:
        settings.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "VALIDATE_PRODUCT": "YES",
        })
    return settings


def target_settings() -> dict:
    return {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CURRENT_PROJECT_VERSION": CURRENT_PROJECT_VERSION,
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{SOURCE_DIR}/Resources/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": "(\"$(inherited)\", \"@executable_path/Frameworks\", )",
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS": "\"iphoneos iphonesimulator\"",
        "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }


def render_settings(settings: dict, indent: str) -> str:
    lines = []
    for key in sorted(settings):
        value = settings[key]
        if value.startswith("(") or value.startswith('"') or value == "":
            rendered = value if value != "" else '""'
        else:
            rendered = quote(value)
        lines.append(f"{indent}{key} = {rendered};")
    return "\n".join(lines)


def generate() -> str:
    tree = build_tree(SOURCE_DIR)
    sources: list[str] = []
    resources: list[str] = []
    collect(tree, sources, resources)
    sources.sort()
    resources.sort()

    # ---- Identifiers ------------------------------------------------------ #
    project_uid = uid("project", PROJECT_NAME)
    target_uid = uid("target", PROJECT_NAME)
    product_uid = uid("product", PROJECT_NAME)
    main_group_uid = uid("group", "<main>")
    products_group_uid = uid("group", "<products>")
    sources_phase_uid = uid("phase", "sources")
    resources_phase_uid = uid("phase", "resources")
    frameworks_phase_uid = uid("phase", "frameworks")
    project_config_list_uid = uid("configlist", "project")
    target_config_list_uid = uid("configlist", "target")
    variant_group_uid = uid("variant", LOCALIZED_RESOURCE)

    out: list[str] = []
    add = out.append

    add("// !$*UTF8*$!")
    add("{")
    add("\tarchiveVersion = 1;")
    add("\tclasses = {")
    add("\t};")
    add("\tobjectVersion = 56;")
    add("\tobjects = {")

    # ---- PBXBuildFile ----------------------------------------------------- #
    add("\n/* Begin PBXBuildFile section */")
    for path in sources:
        add(f"\t\t{uid('buildfile', path)} /* {os.path.basename(path)} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {uid('fileref', path)} /* {os.path.basename(path)} */; }};")
    for path in resources:
        add(f"\t\t{uid('buildfile', path)} /* {os.path.basename(path)} in Resources */ = "
            f"{{isa = PBXBuildFile; fileRef = {uid('fileref', path)} /* {os.path.basename(path)} */; }};")
    add(f"\t\t{uid('buildfile', 'variant')} /* {LOCALIZED_RESOURCE} in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {variant_group_uid} /* {LOCALIZED_RESOURCE} */; }};")
    add("/* End PBXBuildFile section */")

    # ---- PBXFileReference ------------------------------------------------- #
    add("\n/* Begin PBXFileReference section */")
    add(f"\t\t{product_uid} /* {PROJECT_NAME}.app */ = {{isa = PBXFileReference; "
        f"explicitFileType = wrapper.application; includeInIndex = 0; "
        f"path = {PROJECT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")

    referenced = sorted(set(sources) | set(resources) | {os.path.join(SOURCE_DIR, "Resources", "Info.plist")})
    for path in referenced:
        name = os.path.basename(path)
        add(f"\t\t{uid('fileref', path)} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = {file_type(name)}; path = {quote(name)}; sourceTree = \"<group>\"; }};")

    for language in LOCALIZATIONS:
        relative = f"{language}.lproj/{LOCALIZED_RESOURCE}"
        add(f"\t\t{uid('lproj', relative)} /* {language} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = text.plist.strings; name = {language}; "
            f"path = {quote(relative)}; sourceTree = \"<group>\"; }};")
    add("/* End PBXFileReference section */")

    # ---- PBXFrameworksBuildPhase ------------------------------------------ #
    add("\n/* Begin PBXFrameworksBuildPhase section */")
    add(f"\t\t{frameworks_phase_uid} /* Frameworks */ = {{")
    add("\t\t\tisa = PBXFrameworksBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXFrameworksBuildPhase section */")

    # ---- PBXGroup --------------------------------------------------------- #
    add("\n/* Begin PBXGroup section */")
    add(f"\t\t{main_group_uid} = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{tree.uid} /* {SOURCE_DIR} */,")
    add(f"\t\t\t\t{products_group_uid} /* Products */,")
    add("\t\t\t);")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    add(f"\t\t{products_group_uid} /* Products */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    add(f"\t\t\t\t{product_uid} /* {PROJECT_NAME}.app */,")
    add("\t\t\t);")
    add("\t\t\tname = Products;")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")

    def emit_group(node: Node) -> None:
        add(f"\t\t{node.uid} /* {node.name} */ = {{")
        add("\t\t\tisa = PBXGroup;")
        add("\t\t\tchildren = (")
        for child in node.groups:
            add(f"\t\t\t\t{child.uid} /* {child.name} */,")
        for path in node.files:
            name = os.path.basename(path)
            add(f"\t\t\t\t{uid('fileref', path)} /* {name} */,")
        # The Resources group also owns the localized strings variant group.
        if node.path == os.path.join(SOURCE_DIR, "Resources"):
            add(f"\t\t\t\t{variant_group_uid} /* {LOCALIZED_RESOURCE} */,")
        add("\t\t\t);")
        add(f"\t\t\tpath = {quote(node.name)};")
        add("\t\t\tsourceTree = \"<group>\";")
        add("\t\t};")
        for child in node.groups:
            emit_group(child)

    emit_group(tree)
    add("/* End PBXGroup section */")

    # ---- PBXNativeTarget -------------------------------------------------- #
    add("\n/* Begin PBXNativeTarget section */")
    add(f"\t\t{target_uid} /* {PROJECT_NAME} */ = {{")
    add("\t\t\tisa = PBXNativeTarget;")
    add(f"\t\t\tbuildConfigurationList = {target_config_list_uid} "
        f"/* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */;")
    add("\t\t\tbuildPhases = (")
    add(f"\t\t\t\t{sources_phase_uid} /* Sources */,")
    add(f"\t\t\t\t{frameworks_phase_uid} /* Frameworks */,")
    add(f"\t\t\t\t{resources_phase_uid} /* Resources */,")
    add("\t\t\t);")
    add("\t\t\tbuildRules = (")
    add("\t\t\t);")
    add("\t\t\tdependencies = (")
    add("\t\t\t);")
    add(f"\t\t\tname = {PROJECT_NAME};")
    add(f"\t\t\tproductName = {PROJECT_NAME};")
    add(f"\t\t\tproductReference = {product_uid} /* {PROJECT_NAME}.app */;")
    add("\t\t\tproductType = \"com.apple.product-type.application\";")
    add("\t\t};")
    add("/* End PBXNativeTarget section */")

    # ---- PBXProject ------------------------------------------------------- #
    add("\n/* Begin PBXProject section */")
    add(f"\t\t{project_uid} /* Project object */ = {{")
    add("\t\t\tisa = PBXProject;")
    add("\t\t\tattributes = {")
    add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    add("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    add("\t\t\t\tLastUpgradeCheck = 1600;")
    add("\t\t\t\tTargetAttributes = {")
    add(f"\t\t\t\t\t{target_uid} = {{")
    add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    add("\t\t\t\t\t};")
    add("\t\t\t\t};")
    add("\t\t\t};")
    add(f"\t\t\tbuildConfigurationList = {project_config_list_uid} "
        f"/* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;")
    add("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    add("\t\t\tdevelopmentRegion = en;")
    add("\t\t\thasScannedForEncodings = 0;")
    add("\t\t\tknownRegions = (")
    for region in KNOWN_REGIONS:
        add(f"\t\t\t\t{region},")
    add("\t\t\t);")
    add(f"\t\t\tmainGroup = {main_group_uid};")
    add(f"\t\t\tproductRefGroup = {products_group_uid} /* Products */;")
    add("\t\t\tprojectDirPath = \"\";")
    add("\t\t\tprojectRoot = \"\";")
    add("\t\t\ttargets = (")
    add(f"\t\t\t\t{target_uid} /* {PROJECT_NAME} */,")
    add("\t\t\t);")
    add("\t\t};")
    add("/* End PBXProject section */")

    # ---- PBXResourcesBuildPhase ------------------------------------------- #
    add("\n/* Begin PBXResourcesBuildPhase section */")
    add(f"\t\t{resources_phase_uid} /* Resources */ = {{")
    add("\t\t\tisa = PBXResourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for path in resources:
        add(f"\t\t\t\t{uid('buildfile', path)} /* {os.path.basename(path)} in Resources */,")
    add(f"\t\t\t\t{uid('buildfile', 'variant')} /* {LOCALIZED_RESOURCE} in Resources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXResourcesBuildPhase section */")

    # ---- PBXSourcesBuildPhase --------------------------------------------- #
    add("\n/* Begin PBXSourcesBuildPhase section */")
    add(f"\t\t{sources_phase_uid} /* Sources */ = {{")
    add("\t\t\tisa = PBXSourcesBuildPhase;")
    add("\t\t\tbuildActionMask = 2147483647;")
    add("\t\t\tfiles = (")
    for path in sources:
        add(f"\t\t\t\t{uid('buildfile', path)} /* {os.path.basename(path)} in Sources */,")
    add("\t\t\t);")
    add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    add("\t\t};")
    add("/* End PBXSourcesBuildPhase section */")

    # ---- PBXVariantGroup -------------------------------------------------- #
    add("\n/* Begin PBXVariantGroup section */")
    add(f"\t\t{variant_group_uid} /* {LOCALIZED_RESOURCE} */ = {{")
    add("\t\t\tisa = PBXVariantGroup;")
    add("\t\t\tchildren = (")
    for language in LOCALIZATIONS:
        relative = f"{language}.lproj/{LOCALIZED_RESOURCE}"
        add(f"\t\t\t\t{uid('lproj', relative)} /* {language} */,")
    add("\t\t\t);")
    add(f"\t\t\tname = {LOCALIZED_RESOURCE};")
    add("\t\t\tsourceTree = \"<group>\";")
    add("\t\t};")
    add("/* End PBXVariantGroup section */")

    # ---- XCBuildConfiguration --------------------------------------------- #
    add("\n/* Begin XCBuildConfiguration section */")
    for configuration in ("Debug", "Release"):
        add(f"\t\t{uid('buildconfig', 'project', configuration)} /* {configuration} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        add("\t\t\tbuildSettings = {")
        add(render_settings(build_settings(configuration), "\t\t\t\t"))
        add("\t\t\t};")
        add(f"\t\t\tname = {configuration};")
        add("\t\t};")

        add(f"\t\t{uid('buildconfig', 'target', configuration)} /* {configuration} */ = {{")
        add("\t\t\tisa = XCBuildConfiguration;")
        add("\t\t\tbuildSettings = {")
        add(render_settings(target_settings(), "\t\t\t\t"))
        add("\t\t\t};")
        add(f"\t\t\tname = {configuration};")
        add("\t\t};")
    add("/* End XCBuildConfiguration section */")

    # ---- XCConfigurationList ---------------------------------------------- #
    add("\n/* Begin XCConfigurationList section */")
    for scope, list_uid, label in (
        ("project", project_config_list_uid, f"PBXProject \"{PROJECT_NAME}\""),
        ("target", target_config_list_uid, f"PBXNativeTarget \"{PROJECT_NAME}\""),
    ):
        add(f"\t\t{list_uid} /* Build configuration list for {label} */ = {{")
        add("\t\t\tisa = XCConfigurationList;")
        add("\t\t\tbuildConfigurations = (")
        for configuration in ("Debug", "Release"):
            add(f"\t\t\t\t{uid('buildconfig', scope, configuration)} /* {configuration} */,")
        add("\t\t\t);")
        add("\t\t\tdefaultConfigurationIsVisible = 0;")
        add("\t\t\tdefaultConfigurationName = Release;")
        add("\t\t};")
    add("/* End XCConfigurationList section */")

    add("\t};")
    add(f"\trootObject = {project_uid} /* Project object */;")
    add("}")

    return "\n".join(out) + "\n"


SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
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
               BlueprintIdentifier = "{target_uid}"
               BuildableName = "{name}.app"
               BlueprintName = "{name}"
               ReferencedContainer = "container:{name}.xcodeproj">
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
            BlueprintIdentifier = "{target_uid}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
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
            BlueprintIdentifier = "{target_uid}"
            BuildableName = "{name}.app"
            BlueprintName = "{name}"
            ReferencedContainer = "container:{name}.xcodeproj">
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


def main() -> int:
    project_dir = os.path.join(ROOT, f"{PROJECT_NAME}.xcodeproj")
    schemes_dir = os.path.join(project_dir, "xcshareddata", "xcschemes")
    os.makedirs(schemes_dir, exist_ok=True)

    with open(os.path.join(project_dir, "project.pbxproj"), "w", encoding="utf-8") as handle:
        handle.write(generate())

    with open(os.path.join(schemes_dir, f"{PROJECT_NAME}.xcscheme"), "w", encoding="utf-8") as handle:
        handle.write(SCHEME_TEMPLATE.format(target_uid=uid("target", PROJECT_NAME), name=PROJECT_NAME))

    tree = build_tree(SOURCE_DIR)
    sources: list[str] = []
    resources: list[str] = []
    collect(tree, sources, resources)
    print(f"Generated {PROJECT_NAME}.xcodeproj "
          f"({len(sources)} Swift files, {len(resources)} resources)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
