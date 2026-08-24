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
# Stage overlays OUTSIDE the checkout: build-package tars the whole source
# dir into the source layer, so lib/ staged in the repo would be swept into
# the published source tarball. /tmp is docker-shareable.
OVERLAY_ROOT="$(mktemp -d /tmp/grpc-overlays.XXXXXX)"

cleanup() {
  echo "==> Cleanup"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  rm -rf "$TMPDIR_PULL" "$OVERLAY_ROOT"
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
mkdir -p "${OVERLAY_ROOT}/lib/darwin-arm64"
"${PROJECT_DIR}/scripts/bundle-grpc-native-deps.sh" \
  "${PROJECT_DIR}/grpc.dylib" "${OVERLAY_ROOT}/lib/darwin-arm64" > /tmp/grpc-bundle.log 2>&1 \
  || { tail -20 /tmp/grpc-bundle.log; exit 1; }

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
# The builder image installs gRPC into /usr/local (not brew), so there is
# nothing to bundle here -- a bare grpc.so is fine for the local pipeline
# test. CI builds against linuxbrew and bundles the runtime libs.
docker run --rm \
  -v "${PROJECT_DIR}:/src" \
  -w /src \
  "$BUILD_IMAGE" \
  bash -c 'make clean && make -j$(nproc)'
mkdir -p "${OVERLAY_ROOT}/lib/linux-amd64"
cp "${PROJECT_DIR}/grpc.so" "${OVERLAY_ROOT}/lib/linux-amd64/"
# Build artifacts must not leak into the source layer at publish time.
make -C "$PROJECT_DIR" clean

echo "==> Built artifacts:"
find "${OVERLAY_ROOT}/lib" -type f

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

# ── Pull cl-protobufs from local registry ─────────────────────────────
CL_PB_VERSION="${CL_PROTOBUFS_VERSION:-2.0}"
echo "==> Pulling cl-protobufs:${CL_PB_VERSION} from local registry"
CL_PB_DIR="${CL_SYSTEMS_DIR}/cl-protobufs"
rm -rf "$CL_PB_DIR"
mkdir -p "$CL_PB_DIR"
oras pull --insecure "${REGISTRY}/${NAMESPACE}/cl-protobufs:${CL_PB_VERSION}" -o "${TMPDIR_PULL}/cl-protobufs/"
for f in "${TMPDIR_PULL}/cl-protobufs/"*.tar.gz; do
  [ -f "$f" ] && tar -xzf "$f" -C "$CL_PB_DIR/"
done
echo "    cl-protobufs installed to ${CL_PB_DIR}:"
ls "$CL_PB_DIR/"

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
       (overlay-root (uiop:ensure-directory-pathname (uiop:getenv "OVERLAY_ROOT")))
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
               :overlays
               (flet ((make-overlay (os arch)
                        (let* ((lib-dir (merge-pathnames
                                         (format nil "lib/~a-~a/" os arch) overlay-root))
                               ;; grpc.so/.dylib + any bundled runtime libs.
                               ;; NOTE: (directory #p"*") skips files with extensions
                               ;; on SBCL; uiop:directory-files gets all of them.
                               (native-files
                                 (loop for p in (uiop:directory-files lib-dir)
                                       collect (cons (namestring p) (file-namestring p)))))
                          (unless native-files
                            (error "No native files found under ~a" lib-dir))
                          (make-instance 'cl-repository-packager/build-matrix:overlay-spec
                            :os os :arch arch
                            :layers (list (list :role "native-library"
                                                :files native-files))))))
                 (list (make-overlay "linux" "amd64")
                       (make-overlay "darwin" "arm64")))))
       (result (cl-repository-packager/build-matrix:build-package spec)))
  (cl-repository-packager/publisher:publish-package
    reg namespace version result spec)
  (format t "~%Published grpc:~a to ~a/~a~%" version registry-url namespace))
LISP

PKG_VERSION="$VERSION" \
OCI_REGISTRY="http://${REGISTRY}" \
OCI_NAMESPACE="$NAMESPACE" \
SOURCE_DIR="${PROJECT_DIR}/" \
OVERLAY_ROOT="${OVERLAY_ROOT}/" \
sbcl --noinform --non-interactive --load "${TMPDIR_PULL}/publish.lisp"

# ── Verify ────────────────────────────────────────────────────────────
echo "==> Verifying published artifact"
oras manifest fetch "${REGISTRY}/${NAMESPACE}/grpc:${VERSION}" --insecure

echo ""
echo "==> Success! Published grpc:${VERSION} to ${REGISTRY}/${NAMESPACE}"
echo "    Pull with: oras pull --insecure ${REGISTRY}/${NAMESPACE}/grpc:${VERSION}"
