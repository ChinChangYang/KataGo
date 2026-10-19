#!/bin/bash
# PROTOTYPE (wayfinder #37), throwaway: expose Core AI's debug-info SPI to the harness.
#
#   make_spi.sh <outDir> <macosx|iphoneos>
#
# ANE residency comes from Core AI's per-kernel debug records. coreai-core's Python runtime reads them through Swift
# SPI that the OS frameworks export (SpecializationOptions.debugConfiguration, Compiler.DebugConfiguration,
# AIModel.debugInfos) but that no public .swiftinterface declares. This copies the SDK's interfaces for the three
# modules and appends those declarations, so `swiftc -I <outDir>/<sdk>` sees them on the Mac and on the iPad alike.
# The symbols resolve through CoreAI.framework's re-exports; autolinking of the subframeworks is turned off at link.
set -euo pipefail
OUT="$1/$2"; SDK="$(xcrun --sdk "$2" --show-sdk-path)"
for m in CoreAICompiler CoreAIDelegates CoreAIRuntime; do
  src="$SDK/System/Library/SubFrameworks/$m.framework/Modules/$m.swiftmodule"
  mkdir -p "$OUT/$m.swiftmodule"
  for f in "$src"/*.swiftinterface; do
    dst="$OUT/$m.swiftmodule/$(basename "$f")"
    cp "$f" "$dst"; chmod u+w "$dst"
    case $m in
      CoreAICompiler) cat >> "$dst" <<'DECL'
@available(macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)
public class Compiler {
  public struct DebugConfiguration {
    public init()
    public var enableDebugInfo: Swift::Bool { get set }
    public var writeDebugInfo: Swift::Bool { get set }
  }
}
DECL
      ;;
      CoreAIDelegates) cat >> "$dst" <<'DECL'
@available(macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)
extension CoreAIDelegates::SpecializationOptions {
  public var debugConfiguration: CoreAICompiler::Compiler.DebugConfiguration? { get set }
}
DECL
      ;;
      CoreAIRuntime) cat >> "$dst" <<'DECL'
@available(macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)
extension CoreAIRuntime::AIModel {
  public struct DebugInfoRecord : Swift::Encodable {
    public func encode(to encoder: any Swift::Encoder) throws
  }
  public var debugInfos: [CoreAIRuntime::AIModel.DebugInfoRecord] { get }
}
DECL
      ;;
    esac
    # The SDK ships arm64e interfaces only; an arm64 app finds them under its own triple too.
    case "$(basename "$f")" in
      arm64e-apple-ios.swiftinterface) cp "$dst" "$OUT/$m.swiftmodule/arm64-apple-ios.swiftinterface" ;;
      arm64e-apple-macos.swiftinterface) cp "$dst" "$OUT/$m.swiftmodule/arm64-apple-macos.swiftinterface" ;;
    esac
  done
done
echo "$OUT"
