#!/bin/bash
set -euo pipefail
# Usage: TMPDIR=/path/to/task/tmp/ Scripts/test-ios.sh SIMULATOR_UDID
# Requires Xcode and XcodeGen. Uses only an existing local simulator, never an Apple account.
: "${TMPDIR:?Set TMPDIR to the task temporary directory}"
: "${1:?Pass an existing iOS Simulator UDID}"
export FLOWDECK_REPO="$(cd "$(dirname "$0")/.." && pwd)"
simulator_id="$1"
shift
run_directory="$(mktemp -d "${TMPDIR%/}/flowdeck-ios.XXXXXX")"
mkdir -p "$run_directory/Project"
xcodegen generate --spec "$FLOWDECK_REPO/Tests/iOSHost/project.yml" \
  --project-root "$run_directory/Project" --project "$run_directory/Project"
xcodebuild -project "$run_directory/Project/FlowdeckHarness.xcodeproj" \
  -scheme FlowdeckHarness -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$run_directory/DerivedData" \
  -clonedSourcePackagesDirPath "$run_directory/SourcePackages" \
  -resultBundlePath "$run_directory/Tests.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test "$@"
