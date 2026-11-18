#!/usr/bin/env python3
"""Link a local Flint package into an app target of an existing .xcodeproj.

    python3 add-to-xcodeproj.py path/to/App.xcodeproj AppTargetName path/to/Flint

Adds an XCLocalSwiftPackageReference (Xcode 15+), the Flint product dependency,
and a "Flint in Frameworks" build file, creating the target's Frameworks build
phase if it has none. Makes a .bak copy of project.pbxproj first and refuses to
run twice. Don't use it on XcodeGen/Tuist projects: edit their spec instead.
"""
import os
import re
import secrets
import shutil
import subprocess
import sys


def fail(message):
    sys.exit(f"error: {message}")


def new_id(text):
    while True:
        candidate = secrets.token_hex(12).upper()
        if candidate not in text:
            return candidate


def object_block(text, object_id):
    """Span of `ID ... = { ... };` for an object, using the tab indentation pbxproj files use."""
    match = re.search(rf"\n\t\t{object_id}\b[^\n]*= \{{\n.*?\n\t\t\}};", text, re.S)
    return match.span() if match else None


def add_to_list(block, key, entry, before_key):
    """Append `entry` to the `key = ( ... );` list in an object block, creating the list if needed."""
    pattern = rf"(\n\t\t\t{key} = \()(.*?)(\n\t\t\t\);)"
    if re.search(pattern, block, re.S):
        return re.sub(pattern, lambda m: m.group(1) + m.group(2) + f"\n\t\t\t\t{entry}," + m.group(3), block, count=1, flags=re.S)
    anchor = re.search(rf"\n\t\t\t{before_key} = ", block) or re.search(r"\n\t\t\};$", block)
    insert = f"\n\t\t\t{key} = (\n\t\t\t\t{entry},\n\t\t\t);"
    return block[: anchor.start()] + insert + block[anchor.start():]


def insert_objects(text, section, objects):
    end_marker = f"/* End {section} section */"
    if end_marker in text:
        return text.replace(end_marker, objects + end_marker, 1)
    block = f"\n/* Begin {section} section */\n{objects}/* End {section} section */\n"
    close = text.rindex("\t};\n\trootObject = ")
    return text[:close] + block + text[close:]


def main():
    if len(sys.argv) != 4:
        fail(__doc__.strip().splitlines()[2].strip())
    project, target, package = sys.argv[1:]
    pbxproj = os.path.join(project, "project.pbxproj")
    if not os.path.isfile(pbxproj):
        fail(f"{pbxproj} not found")
    if not os.path.isfile(os.path.join(package, "Package.swift")):
        fail(f"{package} has no Package.swift")

    text = open(pbxproj, encoding="utf-8").read()
    relative = os.path.relpath(os.path.abspath(package), os.path.dirname(os.path.abspath(project)))
    if re.search(rf"relativePath = \"?{re.escape(relative)}\"?;", text):
        fail(f"{relative} is already referenced; nothing to do")

    # The app target.
    target_id = None
    for match in re.finditer(r"\n\t\t(\w+) /\*[^\n]*\*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?\n\t\t\};", text, re.S):
        if re.search(rf"\n\t\t\tname = \"?{re.escape(target)}\"?;", match.group(0)):
            target_id = match.group(1)
    if not target_id:
        names = re.findall(r"isa = PBXNativeTarget;.*?\n\t\t\tname = \"?([^\";]+)\"?;", text, re.S)
        fail(f"no target named {target!r}; targets: {', '.join(names)}")

    package_id, product_id, build_file_id = new_id(text), new_id(text), new_id(text)
    text = insert_objects(text, "PBXBuildFile",
        f"\t\t{build_file_id} /* Flint in Frameworks */ = {{isa = PBXBuildFile; productRef = {product_id} /* Flint */; }};\n")
    text = insert_objects(text, "XCLocalSwiftPackageReference",
        f"\t\t{package_id} /* XCLocalSwiftPackageReference \"{relative}\" */ = {{\n"
        f"\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = \"{relative}\";\n\t\t}};\n")
    text = insert_objects(text, "XCSwiftPackageProductDependency",
        f"\t\t{product_id} /* Flint */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tpackage = {package_id} /* XCLocalSwiftPackageReference \"{relative}\" */;\n\t\t\tproductName = Flint;\n\t\t}};\n")

    # Frameworks build phase: reuse the target's, or create one.
    start, end = object_block(text, target_id)
    phases = re.search(r"buildPhases = \((.*?)\);", text[start:end], re.S).group(1)
    frameworks_id = next((pid for pid in re.findall(r"(\w+) /\*", phases)
                          if object_block(text, pid) and "isa = PBXFrameworksBuildPhase;" in text[slice(*object_block(text, pid))]), None)
    if frameworks_id is None:
        frameworks_id = new_id(text)
        text = insert_objects(text, "PBXFrameworksBuildPhase",
            f"\t\t{frameworks_id} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n"
            f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
            f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
        start, end = object_block(text, target_id)
        text = text[:start] + add_to_list(text[start:end], "buildPhases", f"{frameworks_id} /* Frameworks */", "buildRules") + text[end:]

    start, end = object_block(text, frameworks_id)
    text = text[:start] + add_to_list(text[start:end], "files", f"{build_file_id} /* Flint in Frameworks */", "runOnlyForDeploymentPostprocessing") + text[end:]

    start, end = object_block(text, target_id)
    text = text[:start] + add_to_list(text[start:end], "packageProductDependencies", f"{product_id} /* Flint */", "productName") + text[end:]

    project_match = re.search(r"\n\t\t(\w+) /\*[^\n]*\*/ = \{\n\t\t\tisa = PBXProject;", text)
    start, end = object_block(text, project_match.group(1))
    text = text[:start] + add_to_list(text[start:end], "packageReferences",
        f"{package_id} /* XCLocalSwiftPackageReference \"{relative}\" */", "projectDirPath") + text[end:]

    shutil.copyfile(pbxproj, pbxproj + ".bak")
    open(pbxproj, "w", encoding="utf-8").write(text)
    lint = subprocess.run(["plutil", "-lint", pbxproj], capture_output=True, text=True)
    if lint.returncode != 0:
        shutil.copyfile(pbxproj + ".bak", pbxproj)
        fail(f"result didn't parse, restored the original: {lint.stdout.strip()}")
    print(f"Linked Flint ({relative}) into {target}. Backup: {pbxproj}.bak")


if __name__ == "__main__":
    main()
