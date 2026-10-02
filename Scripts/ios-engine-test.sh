#!/bin/zsh
# Runs the engine test target on an iOS simulator. The scheme lives under the
# gitignored .swiftpm folder, so this script recreates it first.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-iPhone 18 Pro}"
mkdir -p .swiftpm/xcode/xcshareddata/xcschemes
cat > .swiftpm/xcode/xcshareddata/xcschemes/EngineTests.xcscheme <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES"></BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "PhotoEngineAppleTests" BuildableName = "PhotoEngineAppleTests" BlueprintName = "PhotoEngineAppleTests" ReferencedContainer = "container:">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
</Scheme>
XML
xcodebuild test -scheme EngineTests -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath .build/ios-dd 2>&1 \
  | grep -E "error:|✔|✘|TEST SUCCEEDED|TEST FAILED"
