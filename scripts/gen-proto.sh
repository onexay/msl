#!/bin/sh
# Regenerate Sources/MSLProtocol from proto/msl/v1/msl.proto (output is checked in).
# The guest generates its Rust code itself (guest/build.rs).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
swift package resolve >/dev/null
TOOLS="$ROOT/.build/proto-tools"
swift build -c release --package-path .build/checkouts/swift-protobuf --product protoc-gen-swift --scratch-path "$TOOLS/swift-protobuf" >/dev/null
swift build -c release --package-path .build/checkouts/grpc-swift-protobuf --product protoc-gen-grpc-swift-2 --scratch-path "$TOOLS/grpc" >/dev/null
OUT=Sources/MSLProtocol/Generated
rm -rf "$OUT" && mkdir -p "$OUT"
protoc -I proto proto/msl/v1/msl.proto \
  --plugin=protoc-gen-swift="$TOOLS/swift-protobuf/release/protoc-gen-swift" \
  --plugin=protoc-gen-grpc-swift-2="$TOOLS/grpc/release/protoc-gen-grpc-swift-2" \
  --swift_out="$OUT" --swift_opt=Visibility=Public,FileNaming=DropPath \
  --grpc-swift-2_out="$OUT" --grpc-swift-2_opt=Visibility=Public,Server=false,FileNaming=DropPath
ls -la "$OUT"
