#!/bin/bash

# Builds the L1 image (see README.md in this directory), tags it, and optionally pushes it to
# GitHub's container registry. Run with --help for usage.

# The image name: RUNCVM_L1_IMAGE, if set, e.g. to publish from a fork.
IMAGE=${RUNCVM_L1_IMAGE:-ghcr.io/newsnowlabs/runcvm/images/test-l1}

usage() {
  cat <<_EOE_
Usage: $0 [--tag <tag>]... [--runcvm-image <image>] [--push] [-- <docker build option>...]

Builds the L1 image as $IMAGE:<tag>, for each tag given
(set RUNCVM_L1_IMAGE to use another image name).

  --tag <tag>, --tag=<tag>
      Tag the image <tag>. May be given more than once, e.g. '--tag v1.2.3 --tag latest',
      where v1.2.3 is the release of RunCVM preinstalled. Without --tag, the image is tagged
      'latest'.

  --runcvm-image <image>, --runcvm-image=<image>
      Preinstall the RunCVM of <image> (build argument RUNCVM_IMAGE; its default is in the
      Dockerfile).

  --push
      After a successful build, also tag the image 'sha-<commit>', for the repository's
      commit, and push each tag to $IMAGE. Requires git and a checkout of the
      repository whose working tree has no uncommitted changes or untracked files, so that
      the commit describes the image; 'docker login ghcr.io'; Docker's containerd image
      store, for the annotations; and no CLAUDE_CODE_VERSION,
      REVISION or VERSION build argument (the script sets REVISION and VERSION).

  -- <docker build option>...
      Pass the remaining arguments to 'docker build', e.g. '-- --no-cache'.

  -h, --help
      Show this help.
_EOE_
}

die() {
  echo "$0: $1" >&2
  [ -n "$2" ] && echo "Run '$0 --help' for usage." >&2
  exit 1
}

tags=()
push=
runcvm_image=
build_opts=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) [ $# -ge 2 ] || die "--tag needs a tag" usage; tags+=("$2"); shift ;;
    --tag=*) tags+=("${1#--tag=}") ;;
    --runcvm-image) [ $# -ge 2 ] || die "--runcvm-image needs an image" usage; runcvm_image="$2"; shift ;;
    --runcvm-image=*) runcvm_image="${1#--runcvm-image=}" ;;
    --push) push=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; build_opts=("$@"); break ;;
    *) die "unknown argument '$1'" usage ;;
  esac
  shift
done

[ ${#tags[@]} -gt 0 ] || tags=(latest)

# Docker's rule for a tag: up to 128 letters, digits, '_', '.' and '-', not starting with '.' or '-'.
for tag in "${tags[@]}"; do
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid tag '$tag'" usage
done

# The build context is this directory, wherever the script is run from.
cd "$(dirname "$0")" || exit 1

# The repository commit, for the image's labels: required with --push, optional otherwise.
revision=$(git rev-parse HEAD 2>/dev/null)

if [ -n "$push" ]; then
  [ -n "$revision" ] || die "--push needs git, and the script run from a checkout of the repository"
  for opt in "${build_opts[@]}"; do
    # Claude Code is not redistributed in a published image.
    [[ "$opt" == *CLAUDE_CODE_VERSION* ]] && die "--push does not publish an image with Claude Code (CLAUDE_CODE_VERSION)"
    # The script sets these, so that the published image's labels describe it.
    [[ "$opt" =~ (^|=)(REVISION|VERSION)= ]] && die "--push sets the build arguments REVISION and VERSION itself"
  done
  [ -z "$(git status --porcelain)" ] || die "--push needs a working tree with no uncommitted changes or untracked files"
  # Each tag's index carries annotations (see below), which need OCI manifests. Docker pushes those
  # with its containerd image store; with its classic store, it pushes Docker manifests, from which
  # 'docker buildx imagetools create' makes a Docker manifest list, which has no annotations.
  [[ "$(docker info --format '{{json .DriverStatus}}')" == *io.containerd.snapshotter* ]] ||
    die "--push needs Docker's containerd image store (in /etc/docker/daemon.json, \"features\": {\"containerd-snapshotter\": true}), for the annotations on ghcr.io"
  tags+=("sha-${revision:0:12}")
fi

arg_opts=(--build-arg "VERSION=${tags[0]}")
[ -n "$revision" ] && arg_opts+=(--build-arg "REVISION=$revision")
[ -n "$runcvm_image" ] && arg_opts+=(--build-arg "RUNCVM_IMAGE=$runcvm_image")

tag_opts=()
for tag in "${tags[@]}"; do
  tag_opts+=(-t "$IMAGE:$tag")
done

DOCKER_BUILDKIT=1 docker build "${tag_opts[@]}" "${arg_opts[@]}" "${build_opts[@]}" . || die "build failed"

if [ -n "$push" ]; then
  for tag in "${tags[@]}"; do
    docker push "$IMAGE:$tag" || die "pushing $IMAGE:$tag failed"
  done

  # GitHub reads a package's source repository and description from the annotations of the index
  # a tag names, where there is one: each tag's index is made again with the image's
  # org.opencontainers.image.* labels, set in the Dockerfile, as annotations.
  labels=$(docker image inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' "$IMAGE:${tags[0]}") ||
    die "reading the labels of $IMAGE:${tags[0]} failed"
  annotation_opts=()
  while IFS= read -r label; do
    annotation_opts+=(--annotation "index:$label")
  done < <(grep '^org\.opencontainers\.image\.' <<<"$labels")
  [ ${#annotation_opts[@]} -gt 0 ] || die "$IMAGE:${tags[0]} has no org.opencontainers.image.* labels"

  for tag in "${tags[@]}"; do
    docker buildx imagetools create "${annotation_opts[@]}" --tag "$IMAGE:$tag" "$IMAGE:$tag" ||
      die "annotating $IMAGE:$tag failed"
    docker buildx imagetools inspect --raw "$IMAGE:$tag" | grep -q '"org.opencontainers.image.source"' ||
      die "$IMAGE:$tag has no annotations"
  done
fi

cat <<_EOE_

L1 image build successful
=========================

Built:  ${tags[*]/#/$IMAGE:}
_EOE_

[ -n "$push" ] && echo "Pushed: ${tags[*]/#/$IMAGE:}"

cat <<_EOE_

To launch L1 (see README.md in this directory):

  docker run -d --runtime=runcvm -m 4g --cpus=4 --stop-timeout=120 --name=runcvm-l1 $IMAGE:${tags[0]}
_EOE_
