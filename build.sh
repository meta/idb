#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# Sourcing this file defines its functions and does nothing else: `set -e` and
# every side effect below live behind the dispatch guard at the bottom, so a
# test can source it, stub what it shells out to, and call one function.

# Check if xattrs are supported on the current filesystem
# Some virtual filesystems (e.g., EdenFS) don't support xattrs
function supports_xattrs() {
  local test_file=".xattr_test_$$"
  if touch "$test_file" 2>/dev/null && xattr -w com.test.xattr test "$test_file" 2>/dev/null; then
    xattr -d com.test.xattr "$test_file" 2>/dev/null
    rm -f "$test_file"
    return 0
  fi
  rm -f "$test_file" 2>/dev/null
  return 1
}

# Everything here is relative to the Source directory, including a `rm -rf Build`
# and a symlink into it, so establish that we are in it before anything runs.
# This covers `help` too: exempting it would leave the destructive setup below
# reachable from an arbitrary directory, and the error already says what to do.
function setup_build_directory() {
  for manifest in Package.swift Companion/project.yml; do
    if [ ! -f "$manifest" ]; then
      echo "error: $manifest not found; build.sh must run from the idb Source directory" >&2
      exit 1
    fi
  done

  detect_xcode_formatter

  # Use build directory outside of repo if xattrs not supported (for Xcode compatibility)
  if supports_xattrs; then
    XATTRS_SUPPORTED=true
    BUILD_DIRECTORY="$(pwd)/Build"
  else
    XATTRS_SUPPORTED=false
    BUILD_DIRECTORY="/tmp/idb-build-$(basename "$(pwd)")"
    echo "Note: Using external build directory at $BUILD_DIRECTORY (xattrs not supported)"
    # Companion/project.yml hard-codes framework refs as
    # `../Build/Products/Release/...`. Symlink the in-tree `Build` dir so
    # those references resolve to the actual external build output.
    rm -rf Build
    ln -s "$BUILD_DIRECTORY" Build
  fi
}

# =============================================================================
# XcodeGen Project Generation
# =============================================================================

function check_xcodegen() {
  if ! command -v xcodegen &> /dev/null; then
    echo "error: XcodeGen not found. Install with: brew install xcodegen"
    exit 1
  fi
}

# Check if ditto is available for xattr-free copying
function has_ditto() {
  command -v ditto &> /dev/null
}

# Validate that a generated xcodeproj is valid
# Usage: validate_xcodeproj <xcodeproj_path>
function validate_xcodeproj() {
  local xcodeproj_path="$1"
  local pbxproj="${xcodeproj_path}/project.pbxproj"

  if [ ! -d "$xcodeproj_path" ]; then
    echo "error: Generated project not found at $xcodeproj_path"
    return 1
  fi

  if [ ! -f "$pbxproj" ]; then
    echo "error: project.pbxproj not found in $xcodeproj_path"
    return 1
  fi

  if [ ! -s "$pbxproj" ]; then
    echo "error: project.pbxproj is empty in $xcodeproj_path"
    return 1
  fi

  # Basic validation: check for required Xcode project structure
  if ! grep -q "PBXProject" "$pbxproj"; then
    echo "error: project.pbxproj appears to be invalid (missing PBXProject)"
    return 1
  fi

  return 0
}

# <project.pbxproj> <directory it was generated in> <directory it will live in>.
# A reference that climbs out of the generation directory is resolved against
# it and re-expressed relative to the destination, whatever its depth and
# wherever the temporary directory was. References that stay inside a group
# (no leading `../`) are relative to their parent group and are left alone.
function rebase_pbxproj_paths() {
  python3 - "$1" "$2" "$3" <<'PY'
import os
import re
import sys

pbxproj, generated_in, destination = sys.argv[1:4]


def rebase(match):
    quote, path = match.group(1), match.group(2)
    if not path.startswith("../"):
        return match.group(0)
    absolute = os.path.normpath(os.path.join(generated_in, path))
    return f"path = {quote}{os.path.relpath(absolute, destination)}{quote};"


with open(pbxproj) as handle:
    text = handle.read()
text = re.sub(r'path = ("?)([^";]+)\1;', rebase, text)
with open(pbxproj, "w") as handle:
    handle.write(text)
PY
}

# Generate a single xcodeproj. xcodegen writes the project into a temporary
# directory and copies it into place with its xattrs, which a filesystem that
# refuses xattrs (EdenFS) rejects outright; there, the project is generated to
# a temporary directory here instead and copied in without them. The probe in
# setup_build_directory decides, so the same checkout takes the same path
# whoever runs it and wherever, and CI needs no switch to say what its
# filesystem is.
# Usage: generate_xcodeproj <project_dir> <project_name>
function generate_xcodeproj() {
  local project_dir="$1"
  local project_name="$2"
  local xcodeproj_name="${project_name}.xcodeproj"
  local dest_path="${project_dir}/${xcodeproj_name}"

  if [ "$XATTRS_SUPPORTED" != true ] && has_ditto; then
    # Generate to temp dir outside filesystem, then copy without xattrs
    local temp_dir=$(mktemp -d)
    local abs_project_dir
    abs_project_dir=$(cd "$project_dir" && pwd)

    echo "  [xattr workaround] Generating to temp: $temp_dir"
    rm -rf "$dest_path"
    (cd "$project_dir" && xcodegen generate -p "$temp_dir")

    # xcodegen spelled every reference relative to the temporary directory.
    # Re-base each one onto the directory the project is about to live in.
    local pbxproj="${temp_dir}/${xcodeproj_name}/project.pbxproj"
    if [ -f "$pbxproj" ]; then
      rebase_pbxproj_paths "$pbxproj" "$temp_dir" "$abs_project_dir"
      echo "  [xattr workaround] Fixed relative paths in project.pbxproj"
    fi

    # Validate temp project before copying
    if ! validate_xcodeproj "${temp_dir}/${xcodeproj_name}"; then
      echo "error: Generated project failed validation"
      rm -rf "$temp_dir"
      exit 1
    fi

    # Use ditto to copy without xattrs
    echo "  [xattr workaround] Copying to $dest_path (without xattrs)"
    ditto --noextattr "${temp_dir}/${xcodeproj_name}" "$dest_path"
    rm -rf "$temp_dir"

    # Validate final project
    if validate_xcodeproj "$dest_path"; then
      echo "  [xattr workaround] Project validated successfully"
    else
      echo "error: Final project failed validation"
      exit 1
    fi
  else
    # Direct generation
    (cd "$project_dir" && xcodegen generate)
    if ! validate_xcodeproj "$dest_path"; then
      echo "error: Generated project failed validation"
      exit 1
    fi
  fi
  python3 -m CI.xcodegen_headers "$dest_path/project.pbxproj"
}

# Only protoc itself. Both Swift plugins are built from pinned source below.
function check_protobuf() {
  if ! command -v protoc &> /dev/null; then
    echo "error: protoc not found"
    echo "Install with: brew install protobuf"
    exit 1
  fi
}

# Reduces the URL in the first field of each line to the repository name it ends
# in. Neither manifest states an identity, so the URL is the only thing the two
# can be matched on -- and a package is the same package however its URL is
# spelled, so both sides are reduced here rather than each parser deciding for
# itself what a name looks like.
function repository_names() {
  awk '{
    sub(/\/+$/, "", $1)
    sub(/\.git$/, "", $1)
    sub(/.*\//, "", $1)
    print
  }'
}

# Lines inside dependencies: that the extractor below cannot read. SwiftPM
# accepts a .package(...) split over several lines, and the extractor only sees
# one written on a single line -- so a split declaration lands in neither
# listing, not pinned, not unpinned, simply absent. Nothing on such a line names
# the package, so the line number is what identifies it.
function package_swift_unreadable_entries() {
  awk '
    /^[[:space:]]*\/\// { next }
    /\.package\(/ && !/\.package\(url: "[^"]*"/ { print FNR }
  ' Package.swift
}

# "<package> <version>" per dependency, and nothing at all for one that is not
# pinned exactly -- which is what makes the two listings below comparable.
# Commented-out lines go first: they declare nothing, and left in they would be
# reported as an unpinned dependency that is not there. The comment cannot be
# stripped to end of line instead, because every url: contains a // of its own.
function package_swift_pins() {
  sed -n '/^[[:space:]]*\/\//d; s|.*\.package(url: "\([^"]*\)", exact: "\([^"]*\)").*|\1 \2|p' Package.swift | repository_names
}

function package_swift_packages() {
  sed -n '/^[[:space:]]*\/\//d; s|.*\.package(url: "\([^"]*\)".*|\1|p' Package.swift | repository_names
}

# "<package> <version>" per pin in Package.resolved, keyed on the identity
# SwiftPM matches on. The trailing top-level "version" key of the file itself is
# skipped because no identity precedes it.
function resolved_pins() {
  awk -F'"' '
    /"identity"[[:space:]]*:/ { identity = $4 }
    /"version"[[:space:]]*:/  { if (identity != "") { print identity, $4; identity = "" } }
  ' Package.resolved
}


# Keyed on the URL, not on the YAML key above it. The key is a nickname XcodeGen
# never resolves anything by, so matching on it lets a rename quietly take the
# package out of the comparison with Package.swift; the URL is the identity both
# manifests actually state. An entry with no url: falls back to its key, which is
# the only thing left to call it and passes through the reduction unchanged.
#
# The packages: block ends at the first non-blank line that is not indented, and
# an entry ends where the next one begins, so neither can run on into a sibling. An entry header is a bare key with nothing after the
# colon; anything else at that indentation is an entry this cannot read, and
# companion_unreadable_entries below reports it rather than letting it vanish.
function _companion_packages_awk() {
  awk -v want_version="$1" '
    function identity() {
      return url == "" ? name : url
    }
    function flush() {
      if (name == "") return
      if (!want_version) print identity()
      else if (version != "") print identity(), version
    }
    /^packages:[[:space:]]*$/ { in_packages = 1; next }
    in_packages && NF && !/^[[:space:]]/ { in_packages = 0; flush(); name = "" }
    !in_packages { next }
    /^  [^[:space:]#][^:]*:[[:space:]]*$/ {
      flush()
      name = $1
      sub(/:$/, "", name)
      url = ""
      version = ""
      next
    }
    name != "" && $1 == "url:" {
      url = $2
      gsub(/["\047]/, "", url)
    }
    name != "" && ($1 == "exactVersion:" || $1 == "version:") {
      version = $2
      gsub(/["\047]/, "", version)
    }
    END { flush() }
  ' Companion/project.yml | repository_names
}

function companion_pins() {
  _companion_packages_awk 1
}

function companion_packages() {
  _companion_packages_awk ""
}

# Entries inside packages: that the parser above cannot read. A package written
# in flow form (`  swift-nio: {url: ..., from: "1.2.0"}`) matches no entry
# header, so it lands in neither listing -- not pinned, not unpinned, simply
# absent. Naming it is the only way the guard can refuse a manifest it cannot
# read rather than pass one it never checked.
function companion_unreadable_entries() {
  awk '
    /^packages:[[:space:]]*$/ { in_packages = 1; next }
    in_packages && NF && !/^[[:space:]]/ { in_packages = 0 }
    !in_packages { next }
    /^  [^[:space:]#][^:]*:[[:space:]]*$/ { next }
    /^  [^[:space:]#]/ {
      name = $1
      sub(/:$/, "", name)
      print name
    }
  ' Companion/project.yml
}

# Every dependency of both manifests is pinned exactly, and the ones they share
# are pinned to the same version. XcodeGen resolves the companion's packages from
# its own manifest and consults Package.swift for nothing, so agreement between
# the two can only be asserted, never derived -- and the companion is the manifest
# that builds the binary which ships.
function check_package_pins() {
  local unpinned unreadable
  local errors=0

  unreadable="$(package_swift_unreadable_entries | tr '\n' ' ')"
  if [ -n "${unreadable// /}" ]; then
    echo "error: Package.swift declares dependencies this check cannot read, on lines: ${unreadable% }" >&2
    errors=1
  fi

  unreadable="$(companion_unreadable_entries | tr '\n' ' ')"
  if [ -n "${unreadable// /}" ]; then
    echo "error: Companion/project.yml declares these in a form this check cannot read: ${unreadable% }" >&2
    errors=1
  fi

  unpinned="$(comm -23 <(package_swift_packages | sort) <(package_swift_pins | cut -d' ' -f1 | sort) | tr '\n' ' ')"
  if [ -n "${unpinned// /}" ]; then
    echo "error: Package.swift does not pin these to an exact version: ${unpinned% }" >&2
    errors=1
  fi

  unpinned="$(comm -23 <(companion_packages | sort) <(companion_pins | cut -d' ' -f1 | sort) | tr '\n' ' ')"
  if [ -n "${unpinned// /}" ]; then
    echo "error: Companion/project.yml does not pin these to an exact version: ${unpinned% }" >&2
    errors=1
  fi

  # Only the packages both manifests declare can disagree. The companion
  # declares three that Package.swift picks up transitively, so those have
  # nothing to compare against and are covered by the exactness check above
  # alone. Package.resolved, by contrast, records every package, so a pinned one
  # missing from it is itself an error.
  # Each parsed once: the loops below ask them a question per dependency.
  local companion resolved
  companion="$(companion_pins)"
  resolved="$(resolved_pins)"

  # A guard that matches nothing passes every case in it, so say so rather than
  # reporting agreement between two listings with no package in common. Asked of
  # what the manifests declare rather than what they pin, so that a manifest with
  # nothing pinned is reported by the exactness check above and not twice more.
  if [ -z "$(comm -12 <(package_swift_packages | sort) <(companion_packages | sort))" ]; then
    echo "error: Package.swift and Companion/project.yml declare no package in common" >&2
    errors=1
  fi

  local name version companion_version resolved_version
  while read -r name version; do
    companion_version="$(printf '%s\n' "$companion" | awk -v n="$name" '$1 == n { print $2 }')"
    if [ -n "$companion_version" ] && [ "$companion_version" != "$version" ]; then
      echo "error: $name is pinned to $version in Package.swift but to $companion_version in Companion/project.yml" >&2
      errors=1
    fi

    resolved_version="$(printf '%s\n' "$resolved" | awk -v n="$name" '$1 == n { print $2 }')"
    if [ -z "$resolved_version" ]; then
      echo "error: $name is pinned in Package.swift but absent from Package.resolved" >&2
      errors=1
    elif [ "$resolved_version" != "$version" ]; then
      echo "error: $name is pinned to $version in Package.swift but Package.resolved records $resolved_version" >&2
      errors=1
    fi
  done < <(package_swift_pins)

  # The three the companion declares that Package.swift only picks up
  # transitively still appear in the resolved graph, so the resolved file is
  # what they can be checked against -- and a companion pinned to a different
  # version of one is the companion linking a different library from idb-repl.
  # Absent from the resolved graph is the same error here as on the Package.swift
  # side: it is the one case where the companion has nothing to be checked
  # against at all, so passing it over would leave the pin unchecked by anything.
  while read -r name version; do
    resolved_version="$(printf '%s\n' "$resolved" | awk -v n="$name" '$1 == n { print $2 }')"
    if [ -z "$resolved_version" ]; then
      echo "error: $name is pinned in Companion/project.yml but absent from Package.resolved" >&2
      errors=1
    elif [ "$resolved_version" != "$version" ]; then
      echo "error: $name is pinned to $version in Companion/project.yml but Package.resolved records $resolved_version" >&2
      errors=1
    fi
  done < <(printf '%s\n' "$companion")

  [ "$errors" -eq 0 ] || exit 1
}

# <product>. Both plugins share one SwiftPM graph and incremental build cache.
function plugin_binary() {
  echo "$BUILD_DIRECTORY/Codegen/.build/release/$1"
}

function build_protoc_plugin() {
  local product="$1"
  local codegen="$BUILD_DIRECTORY/Codegen"
  local plugin_path
  plugin_path="$(plugin_binary "$product")"

  python3 CI/dependency_lock.py prepare-codegen Package.resolved "$codegen" || return
  swift build --package-path "$codegen" -c release --product "$product" \
    --only-use-versions-from-resolved-file || return
  python3 CI/dependency_lock.py check Package.resolved "$codegen/Package.resolved" || return

  if [ ! -x "$plugin_path" ]; then
    echo "error: Failed to build $product" >&2
    return 1
  fi
  echo "Successfully built $product"
}

# The codegen plugins must be the same version as the runtime they generate against.
# `check_package_pins` requires both to be pinned in Package.swift, and
# `dependency_lock.py prepare-codegen` reads the pinned version and revision from
# Package.resolved, so nothing here restates them.
function build_grpc_swift_plugin() {
  check_package_pins

  build_protoc_plugin protoc-gen-grpc-swift-2
}

function build_swift_protobuf_plugin() {
  check_package_pins

  build_protoc_plugin protoc-gen-swift
}

# The published repository holds the proto at `proto/idb.proto`. The monorepo
# exports a directory of its own to that path and so has none, which leaves the
# ancestor holding that directory as the only way to name the proto from here.
function proto_directory() {
  if [ -f "proto/idb.proto" ]; then
    echo "proto"
    return 0
  fi
  local ancestor="$PWD"
  while [ "$ancestor" != "/" ]; do
    ancestor="$(dirname "$ancestor")"
    if [ -f "$ancestor/xplat/idb/idb.proto" ]; then
      echo "$ancestor/xplat/idb"
      return 0
    fi
  done
  echo "error: no idb.proto in proto/, nor in the xplat/idb of any ancestor" >&2
  return 1
}

function generate_proto() {
  check_protobuf
  build_grpc_swift_plugin || return
  build_swift_protobuf_plugin || return

  local proto_dir
  proto_dir="$(proto_directory)" || return 1
  local output_dir="IDBGRPCSwift"
  local protoc=$(which protoc)
  local swift_plugin grpc_plugin
  swift_plugin="$(plugin_binary protoc-gen-swift)"
  grpc_plugin="$(plugin_binary protoc-gen-grpc-swift-2)"

  echo "Generating gRPC Swift from proto..."
  mkdir -p "$output_dir"

  $protoc \
    --proto_path="$proto_dir" \
    --swift_out=Visibility=Public:"$output_dir" \
    --grpc-swift_out=Visibility=Public,Client=true,Server=true:"$output_dir" \
    --plugin=protoc-gen-grpc-swift="$grpc_plugin" \
    --plugin=protoc-gen-swift="$swift_plugin" \
    "$proto_dir/idb.proto" || return

  echo "Generated gRPC Swift files in $output_dir"
}

function generate_companion_project() {
  # This is where Companion/project.yml is consumed, so it is where the pins it
  # declares have to agree with Package.swift. Every build and test path reaches
  # here via regenerate_projects; the codegen path checks separately, because it
  # can run without generating a project.
  check_package_pins

  echo "Generating idb_companion project..."
  generate_xcodeproj "Companion" "idb_companion"

  # xcodegen ignores `embed: false` for a tool target dependency, so strip the
  # leftover entry here.
  sed -i '' '/IDBGRPCSwift.framework in Embed Frameworks/d' \
    Companion/idb_companion.xcodeproj/project.pbxproj

  local resolved_dir="Companion/idb_companion.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  mkdir -p "$resolved_dir"
  cp Package.resolved "$resolved_dir/Package.resolved"
}

function regenerate_projects() {
  check_xcodegen

  echo "Generating FBSimulatorControl project from project.yml..."
  generate_xcodeproj "." "FBSimulatorControl"
  echo "Generating Shimulator project..."
  generate_xcodeproj "Shims/Shimulator" "Shimulator"
  echo "Generating Repl shim project..."
  generate_xcodeproj "Shims/Repl" "Repl"
  echo "Generating SimulatorFrameworkBridge project..."
  generate_xcodeproj "SimulatorFrameworkBridge" "SimulatorFrameworkBridge"
  echo "Generating ReplHost project..."
  generate_xcodeproj "REPLHost" "ReplHost"
  echo "Generating Fixtures project..."
  generate_xcodeproj "Fixtures" "Fixtures"
  generate_companion_project
}

# =============================================================================
# Build Utilities
# =============================================================================

# The minimum Xcode major version required to build, matching the prerequisite
# documented in print_usage and README.md: the codebase requires Swift 6.2 and
# a macOS 15 deployment target, both of which need Xcode 26.
XCODE_MIN_MAJOR=26

function check_xcode_version() {
  # Read the version from the selected Xcode's version.plist rather than
  # invoking xcodebuild: xcodebuild intermittently aborts when it is the
  # first Xcode process on a fresh CI host, and a version probe should not
  # be exposed to that. xcode-select and plutil only read on-disk state.
  local developer_dir
  if ! developer_dir=$(xcode-select --print-path 2>/dev/null) || [ ! -d "$developer_dir" ]; then
    echo "error: no Xcode is selected. Install Xcode ${XCODE_MIN_MAJOR}.0 or newer and select it with xcode-select."
    exit 1
  fi
  local version_plist="${developer_dir%/Contents/Developer}/Contents/version.plist"
  if [ ! -f "$version_plist" ]; then
    echo "error: a full Xcode ${XCODE_MIN_MAJOR}.0+ installation is required (selected developer directory has no version.plist: ${developer_dir})"
    exit 1
  fi
  local version major
  version=$(plutil -extract CFBundleShortVersionString raw "$version_plist" 2>/dev/null) || true
  major=$(printf '%s' "$version" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
  if [[ -z $major ]]; then
    echo "warning: could not read the Xcode version from ${version_plist}; continuing without the version check"
    return 0
  fi
  if (( major < XCODE_MIN_MAJOR )); then
    echo "error: Xcode ${XCODE_MIN_MAJOR}.0 or newer is required to build idb, found: Xcode ${version}"
    exit 1
  fi
}


# xcbeautify is preferred: it recognises the diagnostics xcpretty drops (a
# compile error with no file path, duplicate symbols) and passes through the
# lines it does not recognise. xcpretty remains a fallback, and with neither the
# output is shown as xcodebuild wrote it.
function detect_xcode_formatter() {
  if command -v xcbeautify > /dev/null 2>&1; then
    XCODE_FORMATTER=xcbeautify
  elif command -v xcpretty > /dev/null 2>&1; then
    XCODE_FORMATTER=xcpretty
  else
    XCODE_FORMATTER=""
  fi
}

function format_xcodebuild_output() {
  case "$XCODE_FORMATTER" in
    xcbeautify)
      xcbeautify --disable-logging;;
    xcpretty)
      xcpretty -c;;
    *)
      cat;;
  esac
}

# <xcodebuild arguments>. One file per invocation under the build directory,
# numbered in invocation order and named after the scheme, so a multi-step
# build leaves a readable sequence behind.
function xcodebuild_log_path() {
  local dir="$BUILD_DIRECTORY/Logs/xcodebuild"
  mkdir -p "$dir"
  local scheme="xcodebuild" argument previous=""
  for argument in "$@"; do
    if [ "$previous" = "-scheme" ]; then
      scheme="$argument"
      break
    fi
    previous="$argument"
  done
  local count
  count="$(find "$dir" -name '*.log' | wc -l | tr -d ' ')"
  printf '%s/%02d-%s.log\n' "$dir" "$((count + 1))" "$scheme"
}

# <raw log>. The diagnostics from a failed xcodebuild, read back from the raw
# log rather than from whatever the formatter chose to show: every compiler,
# linker and xcodebuild error line, then the failing-commands summary.
function report_xcodebuild_failure() {
  local log="$1"
  echo "error: xcodebuild failed; the complete output is in $log" >&2
  # In emission order, duplicates dropped; a failure with no recognisable
  # diagnostic (grep exits 1) is still a failure to report, not to abort on.
  {
    grep -E \
      -e ': (fatal )?error: ' \
      -e '^(xcodebuild|ld|clang|swift-frontend|error): ' \
      -e 'duplicate symbol' \
      -e 'Undefined symbols' \
      "$log" || true
  } | awk '!seen[$0]++' | head -40 >&2
  sed -n '/^The following build commands failed:/,$p' "$log" | head -20 >&2 || true
}

function invoke_xcodebuild() {
  # IDB_XCODEBUILD_ROOT keeps a project's products apart from the source build's.
  local root="${IDB_XCODEBUILD_ROOT:-$BUILD_DIRECTORY}"
  local symroot="$root/Products"
  local objroot="$root/Intermediates"
  # Use arrays so each setting/argument stays a single word regardless of spaces.
  # Add CLANG_ENABLE_EXPLICIT_MODULES=NO to mirror Configuration/Shared.xcconfig
  # Add ARCHS=arm64 to build arm64 only (no Intel/x86_64 slices).
  local common_settings=(
    -onlyUsePackageVersionsFromResolvedFile
    -disableAutomaticPackageResolution
    ENABLE_USER_SCRIPT_SANDBOXING=YES
    CLANG_ENABLE_EXPLICIT_MODULES=NO
    ARCHS=arm64
  )
  # Every invocation keeps its complete, unformatted output. A formatter only
  # shows what it recognises, so the raw log is the record, and on failure its
  # diagnostics are printed regardless of what the formatter kept. stderr goes
  # into the same pipe: xcodebuild's own errors (a missing scheme, a broken
  # project) arrive there.
  local log
  log="$(xcodebuild_log_path "$@")"
  # xcodebuild's own status, not the pipeline's: under pipefail a formatter
  # that exits non-zero on a failed build would replace the code, and errexit
  # would end the script before it could be read.
  local errexit=""
  [[ $- == *e* ]] && errexit=1
  set +e
  NSUnbufferedIO=YES xcodebuild "${common_settings[@]}" SYMROOT="$symroot" OBJROOT="$objroot" "$@" 2>&1 | tee "$log" | format_xcodebuild_output
  local status="${PIPESTATUS[0]}"
  [ -n "$errexit" ] && set -e
  if [ "$status" -ne 0 ]; then
    report_xcodebuild_failure "$log"
    return "$status"
  fi
  local argument
  for argument in "$@"; do
    if [ "$argument" = "Companion/idb_companion.xcodeproj" ]; then
      python3 CI/dependency_lock.py check Package.resolved \
        Companion/idb_companion.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved || return
      break
    fi
  done
}

function build_idb_deps() {
  if [ -n "$CUSTOM_idb_DEPS_SCRIPT" ]; then
    "$CUSTOM_idb_DEPS_SCRIPT"
  fi
}

# Only the two remaining .framework products (FBControlCore, FBXCTestCore)
# can nest: FBXCTestCore re-embeds FBControlCore, and the duplicate is
# deleted here. Pure-Swift targets build as static libraries, which never
# nest. This last entry goes away with the last ObjC file (which lets those
# targets become static libraries too).
function strip_embedded_frameworks() {
  local FRAMEWORK_PATH="$BUILD_DIRECTORY/Products/Release/FBXCTestCore.framework/Versions/Current/Frameworks/FBControlCore.framework"
  if [ -d "$FRAMEWORK_PATH" ]; then
    echo "Stripping Framework $FRAMEWORK_PATH"
    rm -r "$FRAMEWORK_PATH"
  fi
}

# =============================================================================
# Build Functions
# =============================================================================

# Any arguments after the configuration are build settings for the scheme.
function build_target() {
  local name=$1
  local configuration=${2:-Debug}
  local settings=("${@:3}")

  invoke_xcodebuild \
    ONLY_ACTIVE_ARCH=NO \
    ${settings[@]+"${settings[@]}"} \
    -project FBSimulatorControl.xcodeproj \
    -scheme "$name" \
    -sdk macosx \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -configuration "$configuration" \
    build
}

# Release, the configuration that ships: the test schemes already build every
# library in Debug, so a Debug build here would only repeat them. The generated
# project's Libraries scheme holds every library, and the guests and shims are
# the resources they need at runtime, so a local build has what is published.
function build_all_libraries() {
  build_target Libraries Release
  build_fbsimulatorcontrol_resources
}

function build_shim() {
  local name=$1
  local sdk=$2
  # libReplIDB lives in its own project (Shims/Repl); default to the Shimulator
  # project, which builds the shim itself.
  local project=${3:-Shims/Shimulator/Shimulator.xcodeproj}

  invoke_xcodebuild \
    ONLY_ACTIVE_ARCH=NO \
    -project "$project" \
    -scheme "$name" \
    -sdk "$sdk" \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -configuration Release \
    build
}

function build_shims() {
  build_shim Shimulator-iOS iphonesimulator
  build_shim Shimulator-macOS macosx
  build_shim ReplIDB-iOS iphonesimulator Shims/Repl/Repl.xcodeproj
  build_shim ReplIDB-macOS macosx Shims/Repl/Repl.xcodeproj
}

# The test fixtures, built from source: FBXCTestCore's test bundle copies the
# macOS ones into its resources, and the docs walk through installing the iOS one.
function build_fixture() {
  local name=$1
  local sdk=$2

  invoke_xcodebuild \
    ONLY_ACTIVE_ARCH=NO \
    -project Fixtures/Fixtures.xcodeproj \
    -scheme "$name" \
    -sdk "$sdk" \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -configuration Release \
    build
}

function build_fixtures() {
  build_fixture MacUnitTestFixture macosx
  build_fixture MacCommonApp macosx
  build_fixture iOSUnitTestFixture iphonesimulator
  build_fixture CodeInjectionPayload-iOS iphonesimulator
}

function build_fbsimulatorcontrol_resources() {
  build_shims
  build_simulator_framework_bridge iOS iphonesimulator
  build_simulator_framework_bridge tvOS appletvsimulator
  build_simulator_framework_bridge watchOS watchsimulator
}

function build_simulator_framework_bridge() {
  # A command-line executable spawned by idb_companion inside the simulator to drive
  # privacy/services state and the REPL socket. One per simulator platform, because a
  # simulator's dyld refuses a guest built for another.
  local platform="$1"
  local sdk="$2"
  invoke_xcodebuild \
    ONLY_ACTIVE_ARCH=NO \
    -project SimulatorFrameworkBridge/SimulatorFrameworkBridge.xcodeproj \
    -scheme "SimulatorFrameworkBridge-$platform" \
    -sdk "$sdk" \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -configuration Release \
    build
}

function build_repl_host() {
  # An empty SwiftUI app bundled into the distribution's Resources/ as
  # ReplHost.app: the default host app for `idb-repl app` without --bundle-id,
  # installed on demand by idb_companion (see
  # FBIDBCommandExecutor.ensureReplHostAppInstalled).
  invoke_xcodebuild \
    ONLY_ACTIVE_ARCH=NO \
    -project REPLHost/ReplHost.xcodeproj \
    -scheme ReplHost \
    -sdk iphonesimulator \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -configuration Release \
    build
}

# The companion project links the generated project's products as prebuilt
# Release archives, listed by the generated Companion/project-deps.yml. Build
# each one from that list so the two cannot disagree.
function build_companion_archives() {
  local tool=$1
  shift
  local product name
  while IFS= read -r product; do
    name="${product%.framework}"
    name="${name#lib}"
    name="${name%.a}"
    build_target "$name" Release "$@"
  done < <(awk -v target="$tool" '
    /^  [^ ]/ { selected = ($0 == "  " target ":") }
    selected && $1 == "-" && $2 == "framework:" {
      sub(/^.*\//, "", $3)
      print $3
    }
  ' Companion/project-deps.yml | sort -u)
}

# The companion's test bundles link the same archives as the companion itself,
# from the companion's own project. Those are built with testability here, so a
# test can reach a library's internals with `@testable import`, as it can from
# the generated project's test schemes, which build the libraries in Debug.
function build_companion_tests() {
  check_protobuf
  build_idb_deps
  generate_proto
  generate_companion_project
  build_companion_archives idb_companion ENABLE_TESTABILITY=YES
}

function build_idb_companion() {
  check_protobuf
  build_idb_deps
  generate_proto
  # XcodeGen expands source globs, so generate the project after the sources.
  generate_companion_project
  build_companion_archives idb_companion
  # Build idb_companion from its own project
  invoke_xcodebuild \
    ONLY_ACTIVE_ARCH=NO \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    -project Companion/idb_companion.xcodeproj \
    -scheme idb_companion \
    -sdk macosx \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -configuration Release \
    build
  strip_embedded_frameworks
}

function build_idb_repl() {
  check_protobuf
  generate_proto
  generate_companion_project
  # Build the idb-repl CLI from the idb_companion project (shares IDBGRPCSwift).
  invoke_xcodebuild \
    ONLY_ACTIVE_ARCH=NO \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    -project Companion/idb_companion.xcodeproj \
    -scheme idb-repl \
    -sdk macosx \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -configuration Release \
    build
}

function build_sim_video() {
  build_companion_archives sim-video
  invoke_xcodebuild \
    ONLY_ACTIVE_ARCH=NO \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    -project Companion/idb_companion.xcodeproj \
    -scheme sim-video \
    -sdk macosx \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -configuration Release \
    build
}

# The archive staging benchmark (Benchmarks/README.md); not part of the distribution.
function build_staging_bench() {
  build_companion_archives staging-bench
  invoke_xcodebuild \
    ONLY_ACTIVE_ARCH=NO \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    -project Companion/idb_companion.xcodeproj \
    -scheme staging-bench \
    -sdk macosx \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -configuration Release \
    build
}

# Assemble the runtime layout idb_companion expects:
#
#   <dist>/
#     idb_companion             the executable
#     idb-repl                  the REPL CLI
#     sim-video                 the local video recorder
#     *.bundle                  SwiftPM resource bundles (Bundle.module -> Bundle.main)
#     Resources/
#       Swift/                    Swift back-deployment libraries
#       libShimulator-iOS.dylib
#       libShimulator-macOS.dylib
#       libReplIDB-iOS.dylib
#       libReplIDB-macOS.dylib
#       SimulatorFrameworkBridge-iOS
#       SimulatorFrameworkBridge-tvOS
#       SimulatorFrameworkBridge-watchOS
#       ReplHost.app
#       IDBAPI.swiftinterface
#
function build_distribution() {
  local release="$BUILD_DIRECTORY/Products/Release"
  local sim="$BUILD_DIRECTORY/Products/Release-iphonesimulator"
  local tvsim="$BUILD_DIRECTORY/Products/Release-appletvsimulator"
  local watchsim="$BUILD_DIRECTORY/Products/Release-watchsimulator"
  local dist="$BUILD_DIRECTORY/Distribution"

  echo "Assembling distribution into $dist"

  # Fail early with a clear message if a prerequisite product is missing.
  local required=(
    "$release/idb_companion"
    "$release/idb-repl"
    "$release/sim-video"
    "$sim/libShimulator-iOS.dylib"
    "$release/libShimulator-macOS.dylib"
    "$sim/libReplIDB-iOS.dylib"
    "$release/libReplIDB-macOS.dylib"
    "$sim/SimulatorFrameworkBridge-iOS"
    "$tvsim/SimulatorFrameworkBridge-tvOS"
    "$watchsim/SimulatorFrameworkBridge-watchOS"
    "$sim/ReplHost.app"
  )
  local path
  for path in "${required[@]}"; do
    if [ ! -e "$path" ]; then
      echo "error: expected build product not found: $path"
      echo "Run './build.sh build' first."
      exit 1
    fi
  done

  rm -rf "$dist"
  mkdir -p "$dist/Resources"

  # Companion executable and the REPL CLI.
  cp "$release/idb_companion" "$dist/"
  cp "$release/idb-repl" "$dist/"
  cp "$release/sim-video" "$dist/"

  # SwiftPM resource bundles (Bundle.module resolves relative to Bundle.main).
  local bundle
  for bundle in "$release"/*.bundle; do
    [ -e "$bundle" ] || continue
    ditto "$bundle" "$dist/$(basename "$bundle")"
  done

  # Shims + the guest binaries live under Resources/ next to idb_companion.
  cp "$sim/libShimulator-iOS.dylib" "$dist/Resources/"
  cp "$release/libShimulator-macOS.dylib" "$dist/Resources/"
  cp "$sim/libReplIDB-iOS.dylib" "$dist/Resources/"
  cp "$release/libReplIDB-macOS.dylib" "$dist/Resources/"
  cp "$sim/SimulatorFrameworkBridge-iOS" "$dist/Resources/"
  cp "$tvsim/SimulatorFrameworkBridge-tvOS" "$dist/Resources/"
  cp "$watchsim/SimulatorFrameworkBridge-watchOS" "$dist/Resources/"

  # ReplHost.app: the default host app for `idb-repl app`, installed on demand
  # by the companion. Already ad-hoc signed at build time (CODE_SIGN_IDENTITY in
  # REPLHost/project.yml), like the guest binaries and the shim dylibs.
  ditto "$sim/ReplHost.app" "$dist/Resources/ReplHost.app"

  # The checked-in IDBAPI module interface, reported to the REPL driver so
  # injected code can auto-import the `IDB` namespace that libReplIDB implements.
  cp "REPL/IDB/IDBAPI.swiftinterface" "$dist/Resources/"

  mkdir -p "$dist/Resources/Swift"
  xcrun swift-stdlib-tool --copy --platform macosx \
    --scan-executable "$dist/idb_companion" \
    --scan-executable "$dist/idb-repl" \
    --scan-executable "$dist/sim-video" \
    --destination "$dist/Resources/Swift"

  echo "Distribution ready at $dist"
}

# The libraries as consumers take them, from the products `build libraries`
# leaves: one static XCFramework per library, the private frameworks' module maps
# and stubs, the resources, and the manifest of what each library links and needs.
function build_library_package() {
  python3 -m CI.library_package "$BUILD_DIRECTORY" "$BUILD_DIRECTORY/LibraryPackage"
}

# SimScope builds against the libraries package, as any consumer of the libraries does, and
# bundles the companion distribution. IDB_LIBRARY_PACKAGE and IDB_DISTRIBUTION name prebuilt
# ones (CI passes its artifacts); whichever is not given is built from source first.
function build_simscope() {
  local package="${IDB_LIBRARY_PACKAGE:-}"
  local dist="${IDB_DISTRIBUTION:-}"
  if [ -z "$dist" ]; then
    build_all
    dist="$BUILD_DIRECTORY/Distribution"
  fi
  if [ -z "$package" ]; then
    build_all_libraries
    build_library_package
    package="$BUILD_DIRECTORY/LibraryPackage"
  fi
  package="$(cd "$package" && pwd)"
  dist="$(cd "$dist" && pwd)"

  check_xcodegen
  echo "Generating SimScope project against $package..."
  IDB_LIBRARY_PACKAGE="$package" generate_xcodeproj "Tools/SimScope" "SimScope"
  local resolved_dir="Tools/SimScope/SimScope.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  mkdir -p "$resolved_dir"
  cp Package.resolved "$resolved_dir/Package.resolved"

  local root="$BUILD_DIRECTORY/SimScope"
  for scheme in SimScope simscope-remote; do
    IDB_XCODEBUILD_ROOT="$root" invoke_xcodebuild \
      ONLY_ACTIVE_ARCH=NO \
      -project Tools/SimScope/SimScope.xcodeproj \
      -scheme "$scheme" \
      -sdk macosx \
      -derivedDataPath "$root" \
      -configuration Release \
      build
  done
  local release="$root/Products/Release"
  local app="$BUILD_DIRECTORY/Applications/SimScope.app"
  rm -rf "$app"
  /bin/bash Tools/SimScope/package.sh "$release/SimScope.app" \
    "$dist" "$dist/idb-repl" "$release/simscope-remote" "$app"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$BUILD_DIRECTORY/SimScope-macos-arm64.zip"
}

function build_all() {
  # build_idb_companion already builds frameworks first
  build_fbsimulatorcontrol_resources
  build_repl_host
  build_idb_companion
  build_idb_repl
  build_sim_video
  build_distribution
}

function build() {
  local target=$1

  if [[ -z $target ]]; then
    echo "Building all targets..."
    build_all
  else
    case $target in
      all)
        build_all;;
      simscope)
        build_simscope;;
      # `frameworks` is the old name, kept so existing scripts keep working.
      libraries|frameworks)
        build_all_libraries;;
      shims)
        build_shims;;
      fixtures)
        build_fixtures;;
      Shimulator-iOS)
        build_shim Shimulator-iOS iphonesimulator;;
      Shimulator-macOS)
        build_shim Shimulator-macOS macosx;;
      ReplIDB-iOS)
        build_shim ReplIDB-iOS iphonesimulator Shims/Repl/Repl.xcodeproj;;
      ReplIDB-macOS)
        build_shim ReplIDB-macOS macosx Shims/Repl/Repl.xcodeproj;;
      SimulatorFrameworkBridge-iOS)
        build_simulator_framework_bridge iOS iphonesimulator;;
      SimulatorFrameworkBridge-tvOS)
        build_simulator_framework_bridge tvOS appletvsimulator;;
      SimulatorFrameworkBridge-watchOS)
        build_simulator_framework_bridge watchOS watchsimulator;;
      ReplHost)
        build_repl_host;;
      idb_companion)
        build_idb_companion;;
      idb-repl)
        build_idb_repl;;
      sim-video)
        build_sim_video;;
      staging-bench)
        build_staging_bench;;
      distribution)
        build_distribution;;
      library-package)
        build_library_package;;
      FBControlCore|FBXCTestCore|FBSimulatorControl|FBSimulatorXCTest|FBDeviceControl)
        build_target "$target";;
      *)
        echo "Unknown target: $target"
        echo "Valid targets: all, simscope, libraries, shims, fixtures, idb_companion, idb-repl, sim-video, FBControlCore, FBXCTestCore, FBSimulatorControl, FBSimulatorXCTest, FBDeviceControl, Shimulator-iOS, Shimulator-macOS, ReplHost, SimulatorFrameworkBridge-iOS, SimulatorFrameworkBridge-tvOS, SimulatorFrameworkBridge-watchOS, distribution"
        exit 1;;
    esac
  fi
}

# =============================================================================
# Test Functions
# =============================================================================

# The schemes `test` accepts, and the steps each needs run first, come from
# TestPlan.json, which the project generator writes beside project.yml.
function test_plan() {
  python3 CI/test_plan.py "$@"
}

# The UDID of an available iPhone simulator, preferring a booted one, for a bundle
# that runs in the simulator rather than on the Mac.
function available_iphone_simulator() {
  local udid
  udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime if d["name"].startswith("iPhone")]
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"] if devices else "")
')"
  if [[ -z $udid ]]; then
    echo "error: no iPhone simulator is available to run the tests in" >&2
    exit 1
  fi
  echo "$udid"
}

function test_target() {
  local name=$1
  # Bundles copy products other projects build -- the shims and guest binaries,
  # the test fixtures -- so the steps that build them run first, whether the
  # whole framework scheme is under test or one suite of it.
  local step
  for step in $(test_plan prerequisites "$name"); do
    "build_$step"
  done
  local project platform settings=() destination=()
  project="$(test_plan project "$name")"
  platform="$(test_plan platform "$name")"
  # A bundle built for the simulator runs in one, which needs no host app and no
  # simulator booted first: xcodebuild boots the one it is given.
  if [[ $platform == "iOS Simulator" ]]; then
    destination=(-destination "platform=iOS Simulator,id=$(available_iphone_simulator)")
  else
    destination=(-sdk macosx)
  fi
  # As for every other build from the companion's project: the libFBDeviceControl
  # it links carries a bridging header that explicit module scanning cannot
  # resolve from there.
  if [[ $project == Companion/idb_companion.xcodeproj ]]; then
    settings+=(SWIFT_ENABLE_EXPLICIT_MODULES=NO)
  fi
  # Per-test time allowances turn a hung test into a named failure in about a
  # minute; without them a single hang stalls the suite until the CI job's
  # 60-minute timeout cancels it with no indication of which test hung. Most
  # tests run in seconds; the boot-lifecycle tests create and boot a simulator
  # and the smoke tests drive a real guest, either of which can take minutes on
  # a hosted runner, so those raise their own allowance (up to the maximum here)
  # via `executionTimeAllowance`.
  invoke_xcodebuild \
    ${settings[@]+"${settings[@]}"} \
    -project "$project" \
    -scheme "$name" \
    "${destination[@]}" \
    -derivedDataPath "$BUILD_DIRECTORY" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 600 \
    test
}

function test_all() {
  local target
  for target in $(test_plan test-targets); do
    test_target "$target"
  done
}

function run_tests() {
  local target=$1

  if [[ -z $target ]]; then
    echo "Running all tests..."
    test_all
  else
    if [[ $target == all ]]; then
      test_all
    elif test_plan schemes | grep -qx "$target"; then
      test_target "$target"
    else
      echo "Unknown test target: $target"
      echo "Valid targets: all, or one of these schemes:"
      test_plan schemes | sed 's/^/  /'
      exit 1
    fi
  fi
}

# =============================================================================
# Usage
# =============================================================================

function print_usage() {
cat <<EOF
./build.sh - Build script for idb

Usage:
  ./build.sh <command> [<target>]

Commands:
  help
    Print this usage information.

  generate
    Regenerate Xcode projects from project.yml using XcodeGen.

  generate-proto
    Regenerate gRPC Swift files from proto/idb.proto.
    This builds protoc-gen-grpc-swift-2 from grpc-swift-protobuf source if needed.

  build [<target>]
    Build targets. If no target specified, builds everything.
    Targets:
      (none)          Build all targets
      all             Build all targets
      simscope        Build SimScope.app against the libraries package, with its bundled tools
      distribution    Assemble the distribution
      libraries       Build every library, and the guests and shims they need, in Release (also: frameworks)
      library-package Package the built libraries for consumers (after 'build libraries')
      idb_companion   Build idb_companion only
      idb-repl        Build idb-repl only
      sim-video       Build the local video recorder
      staging-bench   Build the archive staging benchmark
      shims           Build all shim dylibs (Shimulator + Repl, iOS + macOS)
      fixtures        Build the test fixtures (MacUnitTestFixture, MacCommonApp, iOSUnitTestFixture)
      FBControlCore   Build FBControlCore framework
      FBDeviceControl Build FBDeviceControl framework
      FBSimulatorControl Build FBSimulatorControl framework
      FBSimulatorXCTest Build the FBSimulatorXCTest static library
      ReplHost        Build the ReplHost.app host app (iOS simulator)
      Shimulator-iOS  Build Shimulator-iOS dylib (iOS simulator), the REPL included
      Shimulator-macOS Build Shimulator-macOS dylib (macOS)
      SimulatorFrameworkBridge-iOS Build the iOS-simulator guest executable
      SimulatorFrameworkBridge-tvOS Build the tvOS-simulator guest executable
      SimulatorFrameworkBridge-watchOS Build the watchOS-simulator guest executable
      FBXCTestCore Build FBXCTestCore framework

  test [<target>]
    Run tests. If no target specified, runs all tests.
    Targets:
      (none)          Run every test target
      all             Run every test target
      <scheme>        Run one scheme from TestPlan.json: a test target on its
                      own, or a library with every test target that covers it.
                      For example FBControlCore, FBSimulatorControlUnitTests
                      (needs no simulator), FBSimulatorControlBootTests (creates
                      and boots one) or FBSimulatorControlSmokeTests (takes a
                      booted one from the environment)

Examples:
  ./build.sh generate                 # Regenerate Xcode projects
  ./build.sh generate-proto           # Regenerate gRPC Swift from proto
  ./build.sh build                    # Build everything
  ./build.sh build libraries          # Build all libraries
  ./build.sh build shims              # Build Shimulator-iOS and Shimulator-macOS
  ./build.sh build idb_companion      # Build idb_companion
  ./build.sh build FBControlCore      # Build one library
  ./build.sh test                     # Run all tests
  ./build.sh test FBSimulatorControl  # Test specific framework
  ./build.sh test FBSimulatorControlSmokeTests  # Test one suite of it

Prerequisites:
  - Xcode 26.0+
  - XcodeGen: brew install xcodegen
  - For idb_companion: brew install protobuf
EOF
}

# =============================================================================
# Main
# =============================================================================

function main() {
  set -e
  set -o pipefail

  setup_build_directory

  COMMAND=${COMMAND:-${1:-}}
  TARGET_ARG=${2:-}

  if [[ -z $COMMAND ]]; then
    echo "No command provided"
    print_usage
    exit 1
  fi

  echo "Command: $COMMAND"
  if [[ -n $TARGET_ARG ]]; then
    echo "Target: $TARGET_ARG"
  fi

  case $COMMAND in
    help|-h|--help)
      print_usage;;
    generate)
      regenerate_projects;;
    generate-proto)
      generate_proto;;
    build)
      check_xcode_version
      regenerate_projects
      build "$TARGET_ARG";;
    test)
      check_xcode_version
      regenerate_projects
      run_tests "$TARGET_ARG";;
    *)
      echo "Unknown command: $COMMAND"
      print_usage
      exit 1;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

# vim: set tabstop=2 shiftwidth=2 filetype=sh:
