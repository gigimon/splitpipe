#!/usr/bin/env bash
# Sourced by package.sh. Sets APP_VERSION, BUILD_NUMBER and BUILD_COMMIT
# unless they are already set:
#   - HEAD is exactly at a vX.Y.Z tag: a release build, APP_VERSION=X.Y.Z;
#   - anything else: a development build, APP_VERSION is "X.Y.Z-N-g<hash>" (N commits after the last
#     vX.Y.Z tag), or the short commit hash when there is no tag yet; "-dirty" with uncommitted changes.
# BUILD_NUMBER is the number of commits up to HEAD, so it grows with history and matches between machines.

resolve_version_root="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

resolve_version_git() {
  git -C "$resolve_version_root" "$@" 2>/dev/null
}

BUILD_COMMIT="${BUILD_COMMIT:-$(resolve_version_git rev-parse --short HEAD || echo unknown)}"

if [[ -z "${APP_VERSION:-}" ]]; then
  release_tag="$(resolve_version_git describe --exact-match --tags --match 'v[0-9]*' HEAD || true)"
  if [[ "$release_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    APP_VERSION="${BASH_REMATCH[1]}"
  else
    last_tag="$(resolve_version_git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD || true)"
    if [[ "$last_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
      commits_since_tag="$(resolve_version_git rev-list --count "$last_tag..HEAD" || echo 0)"
      APP_VERSION="${BASH_REMATCH[1]}-$commits_since_tag-g$BUILD_COMMIT"
    else
      APP_VERSION="$BUILD_COMMIT"
    fi
    if [[ -n "$(resolve_version_git status --porcelain --untracked-files=no)" ]]; then
      APP_VERSION="$APP_VERSION-dirty"
    fi
  fi
fi

if [[ -z "${BUILD_NUMBER:-}" ]]; then
  BUILD_NUMBER="$(resolve_version_git rev-list --count HEAD || echo 1)"
fi

if [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  RELEASE_BUILD="true"
else
  RELEASE_BUILD="false"
fi

export APP_VERSION BUILD_NUMBER BUILD_COMMIT RELEASE_BUILD
