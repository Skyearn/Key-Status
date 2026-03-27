#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_FILE="${PROJECT_ROOT}/Key Status.xcodeproj"
SCHEME="Key Status"
BUILD_ROOT="${PROJECT_ROOT}/build"
DERIVED_DATA_PATH="${BUILD_ROOT}/DerivedData"

CONFIGURATION="Debug"
CLEAN_BUILD=true
OPEN_AFTER_BUILD=false

usage() {
  cat <<'EOF'
Usage: ./tools/build.sh [options]

Options:
  --debug         Build with Debug configuration (default)
  --release       Build with Release configuration
  --no-clean      Skip clean step
  --open          Open app after build
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIGURATION="Debug"
      ;;
    --release)
      CONFIGURATION="Release"
      ;;
    --no-clean)
      CLEAN_BUILD=false
      ;;
    --open)
      OPEN_AFTER_BUILD=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ ! -d "${PROJECT_FILE}" ]]; then
  echo "Project not found: ${PROJECT_FILE}" >&2
  exit 1
fi

mkdir -p "${BUILD_ROOT}"

XCODEBUILD_ARGS=(
  -project "${PROJECT_FILE}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
)

if [[ "${CLEAN_BUILD}" == true ]]; then
  xcodebuild "${XCODEBUILD_ARGS[@]}" clean build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
else
  xcodebuild "${XCODEBUILD_ARGS[@]}" build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
fi

PRODUCT_APP="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/Key Status.app"
OUTPUT_APP="${BUILD_ROOT}/Key Status.app"

if [[ ! -d "${PRODUCT_APP}" ]]; then
  echo "Build succeeded but app not found: ${PRODUCT_APP}" >&2
  exit 1
fi

if [[ -d "${OUTPUT_APP}" ]]; then
  rm -rf "${OUTPUT_APP}"
fi

xattr -cr "${PRODUCT_APP}" || true
ditto "${PRODUCT_APP}" "${OUTPUT_APP}"
xattr -cr "${OUTPUT_APP}" || true
codesign --force --sign - --deep --timestamp=none "${OUTPUT_APP}"
codesign --verify --deep --strict "${OUTPUT_APP}"

echo "Build complete."
echo "Output app: ${OUTPUT_APP}"
echo "Derived data: ${DERIVED_DATA_PATH}"

if [[ "${OPEN_AFTER_BUILD}" == true ]]; then
  open -n "${OUTPUT_APP}"
fi
