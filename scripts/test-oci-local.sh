#!/usr/bin/env bash
# Test the full OCI publish pipeline locally.
# Builds native libs (dylib natively, .so via Docker), publishes to a
# local OCI registry, and verifies the resulting image index.
#
# Prerequisites: docker, sbcl, oras, grpc (brew), make
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="localhost:5050"
NAMESPACE="cl-systems"
VERSION="${1:-0.9}"
CONTAINER_NAME="cl-oci-test-registry"
CL_SYSTEMS_DIR="${HOME}/.local/share/cl-systems"
TMPDIR_PULL="$(mktemp -d)"

cleanup() {
  echo "==> Cleanup"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  rm -rf "$TMPDIR_PULL"
  rm -rf "${PROJECT_DIR}/lib"
}
trap cleanup EXIT

# ── Prerequisites ────────────────────────────────────────────────────
echo "==> Checking prerequisites"
for cmd in docker sbcl oras make pkg-config; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found. Install it first." >&2
    exit 1
  fi
done

# ── Build darwin/arm64 natively ──────────────────────────────────────
echo "==> Building grpc.dylib (darwin/arm64)"
make -C "$PROJECT_DIR" clean
make -C "$PROJECT_DIR" -j"$(sysctl -n hw.ncpu)"
mkdir -p "${PROJECT_DIR}/lib/darwin-arm64"
cp "${PROJECT_DIR}/grpc.dylib" "${PROJECT_DIR}/lib/darwin-arm64/"

# ── Build linux via Docker (native arch for speed) ───────────────────
# Uses native Docker platform (arm64 on Apple Silicon) for fast builds.
# CI handles the real linux/amd64 build; this tests the OCI pipeline.
BUILD_IMAGE="grpc-cl-builder:latest"
echo "==> Ensuring Docker build image (${BUILD_IMAGE})"
if ! docker image inspect "$BUILD_IMAGE" &>/dev/null; then
  echo "    Building image from Dockerfile.build (this takes a while the first time)..."
  docker build -t "$BUILD_IMAGE" -f "${PROJECT_DIR}/Dockerfile.build" "${PROJECT_DIR}"
fi

echo "==> Building grpc.so (linux) via Docker"
docker run --rm \
  -v "${PROJECT_DIR}:/src" \
  -w /src \
  "$BUILD_IMAGE" \
  bash -c 'make clean && make -j$(nproc)'
mkdir -p "${PROJECT_DIR}/lib/linux-amd64"
cp "${PROJECT_DIR}/grpc.so" "${PROJECT_DIR}/lib/linux-amd64/"

echo "==> Built artifacts:"
find "${PROJECT_DIR}/lib" -type f

# ── Start local OCI registry ─────────────────────────────────────────
echo "==> Starting local OCI registry on ${REGISTRY}"
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker run -d -p 5050:5000 --name "$CONTAINER_NAME" registry:2
sleep 1

# ── Pull cl-repository-packager ──────────────────────────────────────
CL_REPO_TAG="0.8.0"
CL_REPO_IMAGE="ghcr.io/egao1980/cl-repository/cl-repository-packager"
echo "==> Pulling cl-repository-packager:${CL_REPO_TAG} from GHCR"
rm -rf "$TMPDIR_PULL"
mkdir -p "$TMPDIR_PULL"
mkdir -p "$CL_SYSTEMS_DIR"
rm -rf "$CL_SYSTEMS_DIR"/cl-oci-*
oras pull "${CL_REPO_IMAGE}:${CL_REPO_TAG}" -o "$TMPDIR_PULL/"

for f in "$TMPDIR_PULL"/*.tar.gz; do
  [ -f "$f" ] && tar -xzf "$f" -C "$CL_SYSTEMS_DIR/"
done
echo "Extracted to ${CL_SYSTEMS_DIR}:"
ls "$CL_SYSTEMS_DIR/"

# ── Publish OCI package ──────────────────────────────────────────────
echo "==> Publishing OCI package to ${REGISTRY}/${NAMESPACE}/grpc:${VERSION}"
cat > "${TMPDIR_PULL}/publish.lisp" <<'LISP'
(require :asdf)

(asdf:initialize-source-registry
  '(:source-registry
    (:tree (:home ".local/share/cl-systems/"))
    :inherit-configuration))

(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-setup) (load ql-setup)))

(ql:quickload :cl-repository-packager)

(let* ((version (uiop:getenv "PKG_VERSION"))
       (registry-url (uiop:getenv "OCI_REGISTRY"))
       (namespace (uiop:getenv "OCI_NAMESPACE"))
       (source-dir (uiop:getenv "SOURCE_DIR"))
       (reg (cl-oci-client/registry:make-registry registry-url))
       (spec (make-instance 'cl-repository-packager/build-matrix:package-spec
               :name "grpc"
               :version version
               :source-dir (pathname source-dir)
               :license "MIT"
               :description "Common Lisp gRPC client/server library (CFFI wrapper)"
               :depends-on '("cl-protobufs" "cffi" "bordeaux-threads")
               :provides '("grpc")
               :cffi-libraries '("grpc-client-wrapper")
               :overlays (list
                 (make-instance 'cl-repository-packager/build-matrix:overlay-spec
                   :os "linux" :arch "amd64"
                   :layers (list
                     (list :role "native-library"
                           :files '(("lib/linux-amd64/grpc.so" . "grpc.so")))))
                 (make-instance 'cl-repository-packager/build-matrix:overlay-spec
                   :os "darwin" :arch "arm64"
                   :layers (list
                     (list :role "native-library"
                           :files '(("lib/darwin-arm64/grpc.dylib" . "grpc.dylib"))))))))
       (result (cl-repository-packager/build-matrix:build-package spec)))
  (cl-repository-packager/publisher:publish-package
    reg namespace version result spec)
  (format t "~%Published grpc:~a to ~a/~a~%" version registry-url namespace))
LISP

PKG_VERSION="$VERSION" \
OCI_REGISTRY="http://${REGISTRY}" \
OCI_NAMESPACE="$NAMESPACE" \
SOURCE_DIR="${PROJECT_DIR}/" \
sbcl --noinform --non-interactive --load "${TMPDIR_PULL}/publish.lisp"

# ── Verify ────────────────────────────────────────────────────────────
echo "==> Verifying published artifact"
oras manifest fetch "${REGISTRY}/${NAMESPACE}/grpc:${VERSION}" --insecure

echo ""
echo "==> Success! Published grpc:${VERSION} to ${REGISTRY}/${NAMESPACE}"
echo "    Pull with: oras pull --insecure ${REGISTRY}/${NAMESPACE}/grpc:${VERSION}"
