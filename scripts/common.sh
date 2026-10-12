# shellcheck shell=bash
# Shared helpers for scripts/*.sh. Source, don't execute.

# rpi-image-gen release we build with. Bump both together.
RPI_IMAGE_GEN_REPO=https://github.com/raspberrypi/rpi-image-gen.git
RPI_IMAGE_GEN_TAG=v2.8.0
RPI_IMAGE_GEN_COMMIT=262d4df5a9f9d4133370465399a7958a7c22cdc7

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RPI_IMAGE_GEN_DIR=${RPI_IMAGE_GEN_DIR:-$REPO_ROOT/.cache/rpi-image-gen}

# Clone rpi-image-gen at the pinned tag into $RPI_IMAGE_GEN_DIR and check
# that the tag still points at the pinned commit.
fetch_rpi_image_gen() {
   if [ ! -d "$RPI_IMAGE_GEN_DIR/.git" ]; then
      git clone --quiet --depth 1 --branch "$RPI_IMAGE_GEN_TAG" \
         "$RPI_IMAGE_GEN_REPO" "$RPI_IMAGE_GEN_DIR"
   fi
   local head
   head=$(git -C "$RPI_IMAGE_GEN_DIR" rev-parse HEAD)
   if [ "$head" != "$RPI_IMAGE_GEN_COMMIT" ]; then
      echo "error: $RPI_IMAGE_GEN_DIR is at $head, expected $RPI_IMAGE_GEN_TAG ($RPI_IMAGE_GEN_COMMIT)" >&2
      echo "       delete it and run again" >&2
      return 1
   fi
}
