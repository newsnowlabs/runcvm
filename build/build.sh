#!/bin/bash

# Builds the RunCVM image, tags it, and optionally pushes it to Docker Hub and GitHub's
# container registry. Run with --help for usage.

REPO=newsnowlabs/runcvm
GHCR_REPO=ghcr.io/newsnowlabs/runcvm

usage() {
  cat <<_EOE_
Usage: $0 [--tag <tag>]... [--push[=all|dockerhub]] [-- <docker build option>...]

Builds the RunCVM image as $REPO:<tag>, for each tag given.

  --tag <tag>, --tag=<tag>
      Tag the image <tag>. May be given more than once, e.g. '--tag v1.2.3 --tag latest'
      for a release. Without --tag, the image is tagged 'latest'.

  --push[=all|dockerhub]
      After a successful build, push each tag to Docker Hub ($REPO:<tag>). With 'all',
      the default, then also copy each tag from Docker Hub to GitHub's container registry
      ($GHCR_REPO:<tag>). Requires 'docker login' to each registry.

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
build_opts=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) [ $# -ge 2 ] || die "--tag needs a tag" usage; tags+=("$2"); shift ;;
    --tag=*) tags+=("${1#--tag=}") ;;
    --push) push=all ;;
    --push=all|--push=dockerhub) push="${1#--push=}" ;;
    --push=*) die "unknown --push value '${1#--push=}': expected 'all' or 'dockerhub'" usage ;;
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

# The build context is the repository root, wherever the script is run from.
cd "$(dirname "$0")/.." || exit 1

tag_opts=()
for tag in "${tags[@]}"; do
  tag_opts+=(-t "$REPO:$tag")
done

DOCKER_BUILDKIT=1 docker build "${tag_opts[@]}" "${build_opts[@]}" . || die "build failed"

if [ -n "$push" ]; then
  for tag in "${tags[@]}"; do
    docker push "$REPO:$tag" || die "pushing $REPO:$tag failed"
  done

  # imagetools copies the image, with all its platforms, from registry to registry, so it
  # must follow the push to Docker Hub.
  if [ "$push" = "all" ]; then
    for tag in "${tags[@]}"; do
      docker buildx imagetools create --tag "$GHCR_REPO:$tag" "$REPO:$tag" ||
        die "copying $REPO:$tag to $GHCR_REPO:$tag failed"
    done
  fi
fi

cat <<_EOE_

RunCVM build successful
=======================

Built:  ${tags[*]/#/$REPO:}
_EOE_

case "$push" in
  all) echo "Pushed: ${tags[*]/#/$REPO:} ${tags[*]/#/$GHCR_REPO:}" ;;
  dockerhub) echo "Pushed: ${tags[*]/#/$REPO:}" ;;
esac

cat <<_EOE_

To install or upgrade, now run:

  sudo REPO=$REPO:${tags[0]} ./runcvm-scripts/runcvm-install-runtime.sh
_EOE_
