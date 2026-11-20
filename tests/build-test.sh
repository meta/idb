#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# Covers manifest agreement, locked codegen, and Xcode resolution enforcement.
# Swift and Xcode are stubbed; the real lockfile helper checks their inputs and
# rejects simulated resolver drift without a network or Apple toolchain.
#
# build.sh is a macOS script, so this has to run on a developer's Mac as well as
# on the Linux CI host: no `sed -i` without an argument, no negative array
# subscripts, nothing else past bash 3.2.
#
# $1 is the idb Source directory. Nothing under it is written to: the mutation
# cases run against synthetic manifests, so a real pin bump cannot break them.

set -u

SRC="$1"
if [ ! -f "$SRC/build.sh" ]; then
    echo "error: no build.sh at $SRC" >&2
    exit 1
fi

FAILURES=0

# <description> <expected> <actual>
function assert_equal() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        echo "     expected: $2"
        echo "     actual:   $3"
        FAILURES=$((FAILURES + 1))
    fi
}

# <description> <haystack> <needle>
function assert_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        echo "     expected to find: $3"
        echo "     in:               $2"
        FAILURES=$((FAILURES + 1))
    fi
}

# Binary Swift modules retain internal imports that C header paths cannot resolve.
companion_swift_paths=$(awk '/^    SWIFT_INCLUDE_PATHS:/ {$1=""; print; exit}' "$SRC/Companion/project.yml")
assert_contains "companion importers find private Swift declaration modules" \
    " $companion_swift_paths " " \$(SRCROOT)/../PrivateHeaders "

# Checked before the trap is installed: an unset WORK would send every mkdir
# below to an absolute path outside the sandbox and make the cleanup `rm -rf ""`.
WORK=$(mktemp -d)
if [ -z "${WORK:-}" ] || [ ! -d "$WORK" ]; then
    echo "error: could not create a working directory" >&2
    exit 1
fi
trap 'rm -rf "$WORK"' EXIT

# <sed expression> <file>. GNU and BSD sed disagree about what -i takes, so the
# cases edit through a temporary rather than in place.
function sed_inplace() {
    sed "$1" "$2" > "$2.edited" && mv "$2.edited" "$2"
}

# <file> <line to match on> <text to insert above it>. `sed i\` is spelled
# differently by GNU and BSD sed, so insertion goes through awk instead.
# BSD awk rejects embedded newlines in -v values; the environment preserves them.
function insert_before() {
    IDB_TEST_INSERT_TEXT="$3" awk -v needle="$2" \
        'index($0, needle) { print ENVIRON["IDB_TEST_INSERT_TEXT"] } { print }' "$1" \
        > "$1.edited" && mv "$1.edited" "$1"
}

mkdir -p "$WORK/stubs"

# Succeeding means build.sh keeps its build directory inside the package, which
# is what confines this test to $WORK.
cat > "$WORK/stubs/xattr" <<'STUB'
#!/bin/bash
exit 0
STUB

cat > "$WORK/stubs/swift" <<'STUB'
#!/bin/bash
product=""
package=""
args=("$@")
for i in "${!args[@]}"; do
    [ "${args[$i]}" = "--product" ] && product="${args[$((i + 1))]}"
    [ "${args[$i]}" = "--package-path" ] && package="${args[$((i + 1))]}"
done
printf '%s\n' "$*" >> "$SWIFT_STUB_LOG"
cat "$package/Package.resolved" >> "$SWIFT_STUB_LOG"
[ "${SWIFT_STUB_FAIL:-0}" = 1 ] && exit 7
if [ "${SWIFT_STUB_DRIFT:-0}" = 1 ]; then
    sed 's/1111111111111111111111111111111111111111/9999999999999999999999999999999999999999/' \
        "$package/Package.resolved" > "$package/changed"
    mv "$package/changed" "$package/Package.resolved"
fi
mkdir -p "$package/.build/release"
printf '#!/bin/sh\n' > "$package/.build/release/$product"
chmod +x "$package/.build/release/$product"
STUB

cat > "$WORK/stubs/xcodebuild" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "$XCODE_STUB_LOG"
[ -n "${XCODE_STUB_OUTPUT:-}" ] && printf '%s\n' "$XCODE_STUB_OUTPUT"
[ "${XCODE_STUB_FAIL:-0}" = 1 ] && exit 8
if [ "${XCODE_STUB_DRIFT:-0}" = 1 ]; then
    lock=Companion/idb_companion.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    sed 's/1111111111111111111111111111111111111111/9999999999999999999999999999999999999999/' \
        "$lock" > "$lock.changed"
    mv "$lock.changed" "$lock"
fi
exit 0
STUB

# xcpretty's COMPILE_ERROR_MATCHER is anchored on a leading `/`, and a line it
# does not recognise is dropped rather than passed through. This stub keeps
# exactly that contract so the cases below exercise the pipeline, not xcpretty.
cat > "$WORK/stubs/xcpretty" <<'STUB'
#!/bin/bash
grep -E '^/.*: (fatal )?error: |^\*\* BUILD'
exit 0
STUB

# xcodegen writes where -p says and, like the real one, spells every file
# reference relative to that directory -- which is the whole problem when that
# directory is a temporary one. The references cover the three depths the
# projects use: a file in the project directory, one in its parent, and one two
# levels up (Shims/Repl reaches ../../REPL/Executor).
cat > "$WORK/stubs/xcodegen" <<'STUB'
#!/bin/bash
out=""
args=("$@")
for i in "${!args[@]}"; do
    [ "${args[$i]}" = "-p" ] && out="${args[$((i + 1))]}"
done
[ -n "$out" ] || out="$PWD"
mkdir -p "$out/$XCODEGEN_STUB_NAME.xcodeproj"
# xcodegen's temporary directory and a checkout share no prefix but `/`, so a
# reference is `../` once per component of the temporary directory, then the
# absolute path -- the form the paths take in a real run, spelled out here so
# the case does not depend on where this test's own temporary directory is.
relative() {
    local absolute depth
    absolute="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    depth="$(printf '%s' "$out" | tr -cd '/' | wc -c | tr -d ' ')"
    printf '%s%s' "$(printf '../%.0s' $(seq 1 "$depth"))" "${absolute#/}"
}
{
    echo "// PBXProject"
    echo "path = \"$(relative "$PWD/main.m")\";"
    echo "path = \"$(relative "$PWD/../Shared.h")\";"
    echo "path = \"$(relative "$PWD/../../REPL/Executor/ReplSocketServer.h")\";"
    echo "path = \"$(relative "$PWD/../../.")\";"
} > "$out/$XCODEGEN_STUB_NAME.xcodeproj/project.pbxproj"
STUB

# The workaround copies with ditto to shed xattrs; the copy is all that matters here.
cat > "$WORK/stubs/ditto" <<'STUB'
#!/bin/bash
[ "$1" = "--noextattr" ] && shift
cp -R "$1" "$2"
STUB

# The real protoc rejects a --proto_path that does not exist, and then cannot
# make the file it was given relative to one. Both are kept here: where the
# proto is found is the whole of what the codegen cases below turn on.
cat > "$WORK/stubs/protoc" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$PROTOC_STUB_LOG"
[ "${PROTOC_STUB_FAIL:-0}" = 1 ] && exit 9
path=""
file=""
for arg in "$@"; do
    case "$arg" in
        --proto_path=*) path="${arg#--proto_path=}" ;;
        --*) ;;
        *) file="$arg" ;;
    esac
done
if [ ! -d "$path" ]; then
    echo "$path: warning: directory does not exist." >&2
    echo "Could not make proto path relative: $file: No such file or directory" >&2
    exit 1
fi
exit 0
STUB

chmod +x "$WORK/stubs"/*

# <dir> <grpc-swift-2 version> <swift-protobuf version>. A package the pin guard
# accepts: every dependency exact, and the three manifests in agreement.
function write_package() {
    local dir="$1" grpc="$2" protobuf="$3"
    mkdir -p "$dir/Companion"
    cat > "$dir/Package.swift" <<EOF
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "idb",
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "$grpc"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "$grpc"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "$protobuf"),
    ]
)
EOF
    cat > "$dir/Companion/project.yml" <<EOF
name: idb_companion
packages:
  grpc-swift-2:
    url: https://github.com/grpc/grpc-swift-2.git
    exactVersion: $grpc
  grpc-swift-protobuf:
    url: https://github.com/grpc/grpc-swift-protobuf.git
    exactVersion: $grpc
  swift-protobuf:
    url: https://github.com/apple/swift-protobuf.git
    exactVersion: $protobuf
targets:
  idb_companion:
    type: tool
EOF
    cat > "$dir/Package.resolved" <<EOF
{
  "originHash" : "0000000000000000000000000000000000000000000000000000000000000000",
  "pins" : [
    {
      "identity" : "grpc-swift-2",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/grpc/grpc-swift-2.git",
      "state" : {
        "revision" : "1111111111111111111111111111111111111111",
        "version" : "$grpc"
      }
    },
    {
      "identity" : "grpc-swift-protobuf",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/grpc/grpc-swift-protobuf.git",
      "state" : {
        "revision" : "3333333333333333333333333333333333333333",
        "version" : "$grpc"
      }
    },
    {
      "identity" : "swift-protobuf",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-protobuf.git",
      "state" : {
        "revision" : "2222222222222222222222222222222222222222",
        "version" : "$protobuf"
      }
    }
  ],
  "version" : 3
}
EOF
}

# <case name> <grpc-swift-2 version> <swift-protobuf version>. A package under
# $WORK to mutate, with build.sh alongside it. Echoes the directory.
function stage_package() {
    write_package "$WORK/$1" "$2" "$3"
    cp "$SRC/build.sh" "$WORK/$1/"
    mkdir -p "$WORK/$1/CI"
    cp "$SRC/CI/dependency_lock.py" "$SRC/CI/xcodegen_headers.py" "$WORK/$1/CI/"
    echo "$WORK/$1"
}

# <dir> <shell to run with build.sh sourced>. Runs in the package directory with
# only the stubs on PATH, so anything not stubbed is a hard failure rather than
# a silent call out to the host.
function in_package() {
    local dir="$1" script="$2"
    (
        cd "$dir" || exit 1
        PATH="$WORK/stubs:/usr/bin:/bin"
        # shellcheck disable=SC1090,SC1091
        source ./build.sh
        export XCODE_FORMATTER=""
        set -o pipefail
        setup_build_directory > /dev/null
        eval "$script"
    ) 2>&1
}

# <description> <package dir>. A guard case is two assertions in both
# directions: what the guard decided, and what it said. A message with a zero
# status is not a refusal, and a status with no message leaves the developer
# nothing to act on.
function assert_accepted() {
    local output status
    output="$(in_package "$2" 'check_package_pins && echo "pins agree"')"
    status=$?
    assert_equal "$1: the build continues" 0 "$status"
    assert_contains "$1: nothing is reported" "$output" "pins agree"
}

# <description> <package dir> <expected error>
function assert_rejected() {
    local output status
    output="$(in_package "$2" 'check_package_pins')"
    status=$?
    assert_equal "$1: the build stops" 1 "$status"
    assert_contains "$1: the error says what to fix" "$output" "$3"
}

# ---------------------------------------------------------------------------
# Sourcing build.sh has no side effects of its own
# ---------------------------------------------------------------------------

mkdir -p "$WORK/bare"
cp "$SRC/build.sh" "$WORK/bare/build.sh"
output="$(cd "$WORK/bare" && bash -c 'source ./build.sh; echo "sourced"' 2>&1)"
assert_equal "build.sh sources cleanly with no manifests present" "sourced" "$output"
assert_equal "sourcing creates nothing" "build.sh" "$(ls "$WORK/bare")"

# ---------------------------------------------------------------------------
# The pin guard, against the manifests actually checked in
# ---------------------------------------------------------------------------

mkdir -p "$WORK/real/Companion"
cp "$SRC/build.sh" "$SRC/Package.swift" "$SRC/Package.resolved" "$WORK/real/"
cp "$SRC/Companion/project.yml" "$WORK/real/Companion/"

assert_accepted "the checked-in manifests" "$WORK/real"

# ---------------------------------------------------------------------------
# The pin guard, against manifests made to disagree
# ---------------------------------------------------------------------------

assert_accepted "synthetic manifests in agreement" "$(stage_package synthetic 2.4.3 1.38.1)"

dir="$(stage_package disagree 2.4.3 1.38.1)"
sed_inplace 's/exactVersion: 1.38.1/exactVersion: 1.31.0/' "$dir/Companion/project.yml"
assert_rejected "a companion pinned to a different version" "$dir" \
    "swift-protobuf is pinned to 1.38.1 in Package.swift but to 1.31.0 in Companion/project.yml"

dir="$(stage_package floating 2.4.3 1.38.1)"
sed_inplace 's/exact: "1.38.1"/from: "1.38.1"/' "$dir/Package.swift"
assert_rejected "a floating requirement in Package.swift" "$dir" \
    "Package.swift does not pin these to an exact version: swift-protobuf"

# The companion's own exactness arm: XcodeGen would resolve this to whatever the
# package's default branch points at, which is not a pin at all.
dir="$(stage_package unpinned-companion 2.4.3 1.38.1)"
sed_inplace '/exactVersion: 1.38.1/d' "$dir/Companion/project.yml"
assert_rejected "a companion entry with no version" "$dir" \
    "Companion/project.yml does not pin these to an exact version: swift-protobuf"

# Package.resolved is the arm that covers the transitive graph: the two hand-
# written manifests can agree with each other and still both disagree with what
# SwiftPM last resolved.
dir="$(stage_package resolved-drift 2.4.3 1.38.1)"
sed_inplace 's/"version" : "1.38.1"/"version" : "1.31.0"/' "$dir/Package.resolved"
assert_rejected "a Package.resolved recording a different version" "$dir" \
    "swift-protobuf is pinned to 1.38.1 in Package.swift but Package.resolved records 1.31.0"

dir="$(stage_package resolved-absent 2.4.3 1.38.1)"
cat > "$dir/Package.resolved" <<'EOF'
{
  "originHash" : "0000000000000000000000000000000000000000000000000000000000000000",
  "pins" : [
    {
      "identity" : "grpc-swift-2",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/grpc/grpc-swift-2.git",
      "state" : {
        "revision" : "1111111111111111111111111111111111111111",
        "version" : "2.4.3"
      }
    },
    {
      "identity" : "grpc-swift-protobuf",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/grpc/grpc-swift-protobuf.git",
      "state" : {
        "revision" : "3333333333333333333333333333333333333333",
        "version" : "2.4.3"
      }
    }
  ],
  "version" : 3
}
EOF
assert_rejected "a pinned package missing from Package.resolved" "$dir" \
    "swift-protobuf is pinned in Package.swift but absent from Package.resolved"

# Absence is an error on the companion side too. The companion declares packages
# Package.swift only picks up transitively, so the resolved graph is the only
# thing left that can check them -- letting one that is not in it through would
# leave that pin asserted against nothing at all.
dir="$(stage_package resolved-absent-companion 2.4.3 1.38.1)"
insert_before "$dir/Companion/project.yml" "targets:" "  swift-log:
    url: https://github.com/apple/swift-log.git
    exactVersion: 1.14.0"
assert_rejected "a companion-only package missing from Package.resolved" "$dir" \
    "swift-log is pinned in Companion/project.yml but absent from Package.resolved"

# A commented-out dependency declares nothing. Counting one is worse than a
# nuisance: the guard names a package the developer cannot find a requirement
# for, because there is not one.
dir="$(stage_package commented-out 2.4.3 1.38.1)"
insert_before "$dir/Package.swift" ".package(url: \"https://github.com/grpc/grpc-swift-2.git\"" \
    "        // .package(url: \"https://github.com/apple/swift-nio.git\", from: \"2.50.0\"),"
assert_accepted "a commented-out dependency in Package.swift" "$dir"

# XcodeGen accepts `version:` as a synonym for `exactVersion:`, so a companion
# spelled that way is pinned and must read as pinned.
dir="$(stage_package version-spelling 2.4.3 1.38.1)"
sed_inplace 's/    exactVersion: 1.38.1/    version: 1.38.1/' "$dir/Companion/project.yml"
assert_accepted "a companion pinned with version rather than exactVersion" "$dir"

# An entry in flow form is one the parser genuinely cannot read. It matches no
# entry header, so it falls out of the pinned and the unpinned listing alike --
# and a package in neither listing is a package nothing above checks.
dir="$(stage_package flow-form 2.4.3 1.38.1)"
insert_before "$dir/Companion/project.yml" "targets:" \
    "  swift-log: {url: https://github.com/apple/swift-log.git, exactVersion: 1.14.0}"
assert_rejected "a companion entry written in flow form" "$dir" \
    "Companion/project.yml declares these in a form this check cannot read: swift-log"

# The same hole on the Package.swift side. SwiftPM accepts a .package(...) split
# over several lines, and a split one matches neither extractor -- so it too
# falls out of both listings. Nothing on the line names the package, so the
# refusal is keyed on where it is rather than on what it is called.
dir="$(stage_package split-declaration 2.4.3 1.38.1)"
insert_before "$dir/Package.swift" "    ]" "        .package(
            url: \"https://github.com/apple/swift-nio.git\",
            from: \"2.50.0\"
        ),"
assert_rejected "a Package.swift dependency split over several lines" "$dir" \
    "Package.swift declares dependencies this check cannot read, on lines: 10"

dir="$(stage_package renamed 2.4.3 1.38.1)"
# The YAML key is a nickname -- XcodeGen resolves the package from the `url`
# beneath it -- so renaming the key changes nothing about what the companion
# links, and the version beneath it still has to agree with Package.swift.
sed_inplace 's/^  swift-protobuf:/  swiftprotobuf:/' "$dir/Companion/project.yml"
sed_inplace 's/exactVersion: 1.38.1/exactVersion: 1.31.0/' "$dir/Companion/project.yml"

assert_rejected "a renamed companion key does not hide the version underneath it" "$dir" \
    "swift-protobuf is pinned to 1.38.1 in Package.swift but to 1.31.0 in Companion/project.yml"

# Every key is left alone and every url: is repointed, so a guard keyed on the
# key still finds both packages in common and a guard keyed on the url finds
# neither -- which is the whole difference between the two.
dir="$(stage_package no-overlap 2.4.3 1.38.1)"
sed_inplace 's|url: https://github.com/grpc/grpc-swift-2.git|url: https://github.com/apple/swift-nio.git|' \
    "$dir/Companion/project.yml"
sed_inplace 's|url: https://github.com/grpc/grpc-swift-protobuf.git|url: https://github.com/apple/swift-nio-ssl.git|' \
    "$dir/Companion/project.yml"
sed_inplace 's|url: https://github.com/apple/swift-protobuf.git|url: https://github.com/apple/swift-log.git|' \
    "$dir/Companion/project.yml"

assert_rejected "manifests that declare no package in common" "$dir" \
    "Package.swift and Companion/project.yml declare no package in common"

# A quoted url: is as valid as a bare one and XcodeGen resolves both to the same
# package, so whatever identity the guard derives has to survive the quotes.
dir="$(stage_package quoted-url 2.4.3 1.38.1)"
sed_inplace 's|url: \(.*\)$|url: "\1"|' "$dir/Companion/project.yml"
assert_accepted "a companion whose urls are quoted" "$dir"

# A trailing slash names the same repository as no trailing slash, so it cannot
# be allowed to reduce the identity to nothing.
dir="$(stage_package trailing-slash 2.4.3 1.38.1)"
sed_inplace 's|\(url: .*\)$|\1/|' "$dir/Companion/project.yml"
assert_accepted "a companion whose urls end in a slash" "$dir"

# SwiftPM takes a url with or without the .git suffix, and neither spelling may
# change what the exactness check above sees: it is the same requirement, and the
# case above refuses the other spelling of it.
dir="$(stage_package unsuffixed-url 2.4.3 1.38.1)"
sed_inplace 's|url: "https://github.com/apple/swift-protobuf.git", exact:|url: "https://github.com/apple/swift-protobuf", from:|' \
    "$dir/Package.swift"

assert_rejected "a floating requirement on a url with no .git suffix" "$dir" \
    "Package.swift does not pin these to an exact version: swift-protobuf"

# ---------------------------------------------------------------------------
# Codegen uses the lock, including on a warm cache and after a pin bump.
# ---------------------------------------------------------------------------

dir="$(stage_package plugin 2.4.3 1.38.1)"
export SWIFT_STUB_LOG="$WORK/plugin.swiftlog"
: > "$SWIFT_STUB_LOG"

output="$(in_package "$dir" 'build_grpc_swift_plugin')"
status=$?
assert_equal "cold codegen succeeds" 0 "$status"
assert_contains "codegen reports success" "$output" "Successfully built protoc-gen-grpc-swift-2"
assert_contains "codegen forbids resolution" "$(cat "$SWIFT_STUB_LOG")" "--only-use-versions-from-resolved-file"
assert_contains "codegen receives the pinned revision" "$(cat "$SWIFT_STUB_LOG")" "1111111111111111111111111111111111111111"
assert_contains "the generated manifest pins grpc" "$(cat "$dir/Build/Codegen/Package.swift")" 'exact: "2.4.3"'

: > "$SWIFT_STUB_LOG"
in_package "$dir" 'build_grpc_swift_plugin' > /dev/null
assert_equal "warm codegen succeeds" 0 "$?"
assert_contains "warm codegen still validates with SwiftPM" "$(cat "$SWIFT_STUB_LOG")" "--only-use-versions-from-resolved-file"

write_package "$dir" 1.28.0 1.38.1
in_package "$dir" 'build_grpc_swift_plugin' > /dev/null
assert_equal "codegen after a pin bump succeeds" 0 "$?"
assert_contains "a pin bump updates the generated manifest" "$(cat "$dir/Build/Codegen/Package.swift")" 'exact: "1.28.0"'

in_package "$dir" 'build_swift_protobuf_plugin' > /dev/null
assert_equal "protobuf codegen succeeds" 0 "$?"
assert_contains "protobuf uses the same locked graph" "$(cat "$SWIFT_STUB_LOG")" "--product protoc-gen-swift --only-use-versions-from-resolved-file"

export SWIFT_STUB_FAIL=1
output="$(in_package "$dir" 'build_grpc_swift_plugin')"
assert_equal "an existing binary cannot hide a failed SwiftPM build" 7 "$?"
unset SWIFT_STUB_FAIL

export SWIFT_STUB_DRIFT=1
output="$(in_package "$dir" 'build_grpc_swift_plugin')"
assert_equal "resolver revision drift fails codegen" 1 "$?"
assert_contains "codegen identifies resolver drift" "$output" "grpc-swift-2: expected"
unset SWIFT_STUB_DRIFT

# ---------------------------------------------------------------------------
# Codegen finds the proto in whichever repository it is run from.
#
# The published repository has it at `proto/idb.proto`. The monorepo exports
# `xplat/idb` to that path, so it has no `proto/` of its own and the package
# sits several directories below the one holding `xplat`.
# ---------------------------------------------------------------------------

export PROTOC_STUB_LOG="$WORK/protoc.log"

dir="$(stage_package published 2.4.3 1.38.1)"
mkdir -p "$dir/proto"
touch "$dir/proto/idb.proto"
: > "$PROTOC_STUB_LOG"

output="$(in_package "$dir" 'generate_proto')"
assert_equal "codegen in the published repository succeeds" 0 "$?"
assert_contains "protoc reads the published proto directory" \
    "$(cat "$PROTOC_STUB_LOG")" "--proto_path=proto"

monorepo="$WORK/monorepo"
dir="$(stage_package monorepo/fbobjc/Tools/idb/Source 2.4.3 1.38.1)"
mkdir -p "$monorepo/xplat/idb"
touch "$monorepo/xplat/idb/idb.proto"
: > "$PROTOC_STUB_LOG"

output="$(in_package "$dir" 'generate_proto')"
assert_equal "codegen in the monorepo succeeds" 0 "$?"
assert_contains "protoc reads the directory the published proto is exported from" \
    "$(cat "$PROTOC_STUB_LOG")" "--proto_path=$monorepo/xplat/idb"

export PROTOC_STUB_FAIL=1
output="$(in_package "$dir" 'generate_proto')"
assert_equal "a failed protoc fails codegen" 9 "$?"
assert_equal "the build is not told generation finished" 0 \
    "$(grep -c "Generated gRPC Swift files" <<< "$output")"
unset PROTOC_STUB_FAIL

# ---------------------------------------------------------------------------
# Xcode gets the same lock and must preserve it.
# ---------------------------------------------------------------------------

dir="$(stage_package xcode 2.4.3 1.38.1)"
export XCODE_STUB_LOG="$WORK/xcode.log"
: > "$XCODE_STUB_LOG"
# The functions are evaluated inside the staged package.
# shellcheck disable=SC2016
output="$(in_package "$dir" '
    generate_xcodeproj() { mkdir -p Companion/idb_companion.xcodeproj; }
    sed() { if [ "$1" != "-i" ]; then command sed "$@"; fi; }
    generate_companion_project
')"
assert_equal "companion generation stages the shared lock" 0 "$?"
lock="$dir/Companion/idb_companion.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
assert_equal "Xcode lock is identical to the shared lock" "$(cat "$dir/Package.resolved")" "$(cat "$lock")"

output="$(in_package "$dir" 'invoke_xcodebuild -project Companion/idb_companion.xcodeproj build')"
assert_equal "a locked Xcode build succeeds" 0 "$?"
assert_contains "Xcode may only use the lock" "$(cat "$XCODE_STUB_LOG")" "-onlyUsePackageVersionsFromResolvedFile"
assert_contains "Xcode automatic resolution is disabled" "$(cat "$XCODE_STUB_LOG")" "-disableAutomaticPackageResolution"
assert_contains "Xcode runs build scripts inside the sandbox" "$(cat "$XCODE_STUB_LOG")" "ENABLE_USER_SCRIPT_SANDBOXING=YES"
assert_equal "Xcode does not bypass macro validation or compiler sandboxing" 0 \
    "$(grep -Ec -- 'skipMacroValidation|disable-sandbox|ENABLE_USER_SCRIPT_SANDBOXING=NO' "$XCODE_STUB_LOG")"
assert_contains "direct Xcode builds keep script sandboxing" \
    "$(cat "$SRC/Configuration/Shared.xcconfig")" "ENABLE_USER_SCRIPT_SANDBOXING = YES"

export XCODE_STUB_FAIL=1
output="$(in_package "$dir" 'invoke_xcodebuild -project Companion/idb_companion.xcodeproj build')"
assert_equal "lock verification cannot hide an Xcode failure" 8 "$?"
unset XCODE_STUB_FAIL

export XCODE_STUB_DRIFT=1
output="$(in_package "$dir" 'invoke_xcodebuild -project Companion/idb_companion.xcodeproj build')"
assert_equal "Xcode revision drift fails the build" 1 "$?"
assert_contains "Xcode identifies resolver drift" "$output" "grpc-swift-2: expected"
unset XCODE_STUB_DRIFT

# A Swift compile that fails before it has a file to point at reports
# `<unknown>:0: error: ...`, which the formatter does not recognise.
export XCODE_STUB_FAIL=1
export XCODE_STUB_OUTPUT="<unknown>:0: error: missing required module 'CNIOAtomics'
** BUILD FAILED **"
output="$(in_package "$dir" '
    XCODE_FORMATTER=xcpretty
    invoke_xcodebuild -project Companion/idb_companion.xcodeproj -scheme idb_companion build
')"
assert_equal "a formatted Xcode failure still fails" 8 "$?"
assert_equal "the path-less error is reported" 1 "$(grep -c "missing required module" <<< "$output")"
assert_equal "a raw xcodebuild log is kept" 1 "$(find "$dir/Build" -path '*Logs/xcodebuild/*idb_companion.log' 2>/dev/null | wc -l | tr -d ' ')"

# The script runs under errexit and pipefail. A failure whose output has no
# recognisable diagnostic, and a formatter that exits non-zero on failure,
# must still report xcodebuild's own status.
export XCODE_STUB_OUTPUT="nothing the report recognises"
cat > "$WORK/stubs/xcpretty" <<'STUB'
#!/bin/bash
grep -E '^/.*: (fatal )?error: |^\*\* BUILD'
exit 1
STUB
# shellcheck disable=SC2016
output="$(in_package "$dir" '
    set -e
    XCODE_FORMATTER=xcpretty
    invoke_xcodebuild -project Companion/idb_companion.xcodeproj -scheme idb_companion build
')"
assert_equal "xcodebuild status survives errexit and a failing formatter" 8 "$?"
assert_contains "the failure is still reported" "$output" "error: xcodebuild failed; the complete output is in"
cat > "$WORK/stubs/xcpretty" <<'STUB'
#!/bin/bash
grep -E '^/.*: (fatal )?error: |^\*\* BUILD'
exit 0
STUB
unset XCODE_STUB_FAIL XCODE_STUB_OUTPUT

# The formatter is chosen by what is installed: xcbeautify first, xcpretty as
# the fallback, and none at all is not an error.
cat > "$WORK/stubs/xcbeautify" <<'STUB'
#!/bin/bash
cat
STUB
chmod +x "$WORK/stubs/xcbeautify"
# shellcheck disable=SC2016
output="$(in_package "$dir" 'detect_xcode_formatter; echo "formatter=$XCODE_FORMATTER"')"
assert_contains "xcbeautify is preferred when installed" "$output" "formatter=xcbeautify"
rm "$WORK/stubs/xcbeautify"
# shellcheck disable=SC2016
output="$(in_package "$dir" 'detect_xcode_formatter; echo "formatter=$XCODE_FORMATTER"')"
assert_contains "xcpretty is the fallback" "$output" "formatter=xcpretty"
# shellcheck disable=SC2016
output="$(in_package "$dir" 'PATH=/usr/bin:/bin detect_xcode_formatter; echo "formatter=[$XCODE_FORMATTER]"')"
assert_contains "no formatter is not an error" "$output" "formatter=[]"

# A project generated through the xattr workaround must reference its sources
# exactly as one generated in place would: the temporary directory xcodegen
# wrote to must leave no trace in the paths.
mkdir -p "$dir/Shims/Repl" "$dir/REPL/Executor"
export XCODEGEN_STUB_NAME=Repl
# shellcheck disable=SC2016
output="$(in_package "$dir" '
    # BSD sed takes `-i ""`; GNU sed reads that "" as the script. Give GNU sed
    # the BSD calling convention so the rewrite under test runs the same way
    # on both, rather than skipping it (as the companion case does).
    sed() {
        if [ "$1" = "-i" ] && [ -z "$2" ] && command sed --version > /dev/null 2>&1; then
            shift 2; command sed -i "$@"
        else
            command sed "$@"
        fi
    }
    XATTRS_SUPPORTED=false generate_xcodeproj Shims/Repl Repl
')"
assert_equal "a nested project generates through the workaround" 0 "$?"
pbxproj="$dir/Shims/Repl/Repl.xcodeproj/project.pbxproj"
assert_contains "a file in the project directory is a bare path" "$(cat "$pbxproj")" 'path = "main.m";'
assert_contains "a file in the parent directory is one level up" "$(cat "$pbxproj")" 'path = "../Shared.h";'
assert_equal "a file two levels up is rewritten" 1 "$(grep -c 'path = "../../REPL/Executor/ReplSocketServer.h";' "$pbxproj")"
assert_equal "the directory two levels up is rewritten" 1 "$(grep -c 'path = "../..";' "$pbxproj")"
# A reference that still names the package directory was never re-based.
assert_equal "references keeping the temporary directory's chain" 0 "$(grep -c '/xcode[/"]' "$pbxproj")"
unset XCODEGEN_STUB_NAME

# Existing generated files do not prove that they match today's plugin pins.
mkdir -p "$dir/IDBGRPCSwift"
touch "$dir/IDBGRPCSwift/idb.grpc.swift" "$dir/IDBGRPCSwift/idb.pb.swift"
output="$(in_package "$dir" '
    check_protobuf() { :; }
    generate_proto() { echo regenerated-proto; }
    generate_companion_project() { echo regenerated-project; }
    invoke_xcodebuild() { :; }
    build_idb_repl
')"
assert_equal "a repeat REPL build regenerates sources before project globs" 'regenerated-proto
regenerated-project' "$output"

# The companion's test bundles link the archives the companion links, by path
# from Build/Products/Release, so building for those tests builds every one of
# them, and only those.
cat > "$dir/Companion/project-deps.yml" <<'EOF'
targets:
  idb_companion:
    dependencies:
      - framework: ../Build/Products/Release/libFBSimulatorControl.a
        embed: false
      - framework: ../Build/Products/Release/FBControlCore.framework
        embed: false
  sim-video:
    dependencies:
      - framework: ../Build/Products/Release/libFBVideoCore.a
        embed: false
EOF
output="$(in_package "$dir" '
    # build.sh runs without nounset, which this file sets.
    set +u
    check_protobuf() { :; }
    build_idb_deps() { :; }
    generate_proto() { :; }
    generate_companion_project() { :; }
    build_target() { echo "built $*"; }
    build_companion_tests
')"
assert_equal "building for the companion's tests builds the companion's archives, testable" 'built FBControlCore Release ENABLE_TESTABILITY=YES
built FBSimulatorControl Release ENABLE_TESTABILITY=YES' "$output"

# The companion itself links the archives as they ship.
output="$(in_package "$dir" '
    set +u
    check_protobuf() { :; }
    build_idb_deps() { :; }
    generate_proto() { :; }
    generate_companion_project() { :; }
    build_target() { echo "built $*"; }
    invoke_xcodebuild() { :; }
    strip_embedded_frameworks() { :; }
    build_idb_companion
')"
assert_equal "building the companion builds its archives as they ship" 'built FBControlCore Release
built FBSimulatorControl Release' "$output"

# Build settings after the configuration reach xcodebuild; without any, it gets none.
# shellcheck disable=SC2016
build_target_settings='
    set +u
    invoke_xcodebuild() { printf "%s\n" "$@"; }
    build_target FBControlCore Release "$@" | grep -c "^ENABLE_TESTABILITY=YES$"
'
output="$(in_package "$dir" "set -- ENABLE_TESTABILITY=YES; $build_target_settings")"
assert_equal "a build setting given to build_target reaches xcodebuild" 1 "$output"
output="$(in_package "$dir" "set --; $build_target_settings")"
assert_equal "build_target adds no build settings of its own" 0 "$output"

# Every build from the companion's project turns Swift's explicit modules off,
# and testing the companion's schemes is a build from that project too. The
# generated project's own schemes are left at Xcode's default.
# shellcheck disable=SC2016
explicit_modules_off='
    set +u
    test_plan() {
        case "$1" in
            project) [ "$2" = CompanionLibTests ] && echo Companion/idb_companion.xcodeproj || echo FBSimulatorControl.xcodeproj ;;
        esac
    }
    invoke_xcodebuild() { printf "%s\n" "$@"; }
    test_target "$scheme" | grep -c "^SWIFT_ENABLE_EXPLICIT_MODULES=NO$"
'
output="$(in_package "$dir" "scheme=CompanionLibTests; $explicit_modules_off")"
assert_equal "the companion's tests build with explicit modules off" 1 "$output"
output="$(in_package "$dir" "scheme=FBControlCoreTests; $explicit_modules_off")"
assert_equal "the generated project's tests keep Xcode's default" 0 "$output"

# The staging benchmark links its own closure from Build/Products/Release, so
# building it builds exactly those archives first.
cat >> "$dir/Companion/project-deps.yml" <<'EOF'
  staging-bench:
    dependencies:
      - framework: ../Build/Products/Release/libFBArtifactStaging.a
        embed: false
EOF
output="$(in_package "$dir" '
    set +u
    build_target() { echo "built $1 $2"; }
    invoke_xcodebuild() { :; }
    build_staging_bench
')"
assert_equal "building the staging benchmark builds its archives" 'built FBArtifactStaging Release' "$output"

# Building the libraries builds the generated project's scheme of every library,
# then the resources they need at runtime.
output="$(in_package "$dir" '
    set +u
    build_target() { echo "built $1 $2"; }
    build_fbsimulatorcontrol_resources() { echo "built resources"; }
    build_all_libraries
')"
assert_equal "building the libraries builds every library and their resources" 'built Libraries Release
built resources' "$output"

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES assertion(s) failed"
    exit 1
fi

echo "all assertions passed"
