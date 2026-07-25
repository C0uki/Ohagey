#!/usr/bin/env bash
# Regenerates the Swift Protobuf types from ohagey.proto (decision 0007).
#
# Generated code is committed so that a plain `swift build` works without
# protoc installed. Run this script whenever ohagey.proto changes and commit
# the result alongside it.
#
# Requires:
#   - protoc            (e.g. `winget install protobuf`, `apt install protobuf-compiler`)
#   - protoc-gen-swift  from https://github.com/apple/swift-protobuf:
#       git clone https://github.com/apple/swift-protobuf.git
#       cd swift-protobuf && swift build -c release
#       # then put .build/release/protoc-gen-swift on PATH

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
proto_dir="${script_dir}/../Sources/OhageyEngineProto"

command -v protoc >/dev/null || { echo "error: protoc not found on PATH" >&2; exit 1; }
command -v protoc-gen-swift >/dev/null || {
  echo "error: protoc-gen-swift not found on PATH (see header of this script)" >&2
  exit 1
}

protoc \
  --proto_path="${proto_dir}" \
  --swift_out="${proto_dir}" \
  --swift_opt=Visibility=Public \
  "${proto_dir}/ohagey.proto"

echo "generated: ${proto_dir}/ohagey.pb.swift"
