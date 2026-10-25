#!/bin/sh
set -eu
cd "$(dirname "$0")"
validation_dir=$(mktemp -d)
trap 'rm -rf "$validation_dir"' EXIT
swiftc RawGateway/Core/ChunkStore.swift Validation/main.swift -o "$validation_dir/validate"
"$validation_dir/validate"
