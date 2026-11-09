#!/bin/bash
set -eo pipefail

readonly TAG_PATTERN='^0\.[0-9]+\.[0-9]+$'
readonly SHA_PATTERN='^[0-9a-f]{7,40}$'
SBOT="${SBOT:-./bin/sbot}"
DRY_RUN="false"
PICKED=()

function main() {
  local mode=""
  local commit=""
  local base_tag=""
  local shas=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
    --mode)
      mode="${2}"
      shift 2
      ;;
    --commit)
      commit="${2}"
      shift 2
      ;;
    --base-tag)
      base_tag="${2}"
      shift 2
      ;;
    --shas)
      shas="${2}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    *)
      usage
      exit 1
      ;;
    esac
  done

  git fetch --force --tags origin "+refs/heads/main:refs/remotes/origin/main"

  case "${mode}" in
  release)
    release "${commit}"
    ;;
  hotfix)
    hotfix "${base_tag}" "${shas}"
    ;;
  *)
    usage
    exit 1
    ;;
  esac
}

function usage() {
  cat <<EOF
Usage:
  ${0} --mode release [--commit <sha>] [--dry-run]
  ${0} --mode hotfix --base-tag <0.N.P> [--shas "<sha> ..."] [--dry-run]

release tags a main commit (main HEAD by default) with the 0.N.0 that sbot predicts.
hotfix cherry-picks main commits onto release/0.N and tags it with the next 0.N patch.
--dry-run skips the push and deletes the local tag.
EOF
}

function release() {
  local commit="${1:-origin/main}"
  local sha
  local tags
  local last
  local version

  if [[ "${commit}" != "origin/main" && ! "${commit}" =~ ${SHA_PATTERN} ]]; then
    fail "${commit} is not a commit SHA."
  fi
  sha=$(git rev-parse -q --verify "${commit}^{commit}") || fail "Commit ${commit} does not exist."
  if ! git merge-base --is-ancestor "${sha}" origin/main; then
    fail "Commit ${sha} is not on main."
  fi
  tags=$(release_tags_at "${sha}")
  if [[ -n "${tags}" ]]; then
    fail "Commit ${sha} is already tagged ${tags}."
  fi
  require_version_scheme "${sha}"
  last=$(git describe --tags --abbrev=0 --match "0.*" --exclude "*-*" origin/main)
  if ! git merge-base --is-ancestor "${last}" "${sha}"; then
    fail "Commit ${sha} is older than release ${last}."
  fi

  version=$("${SBOT}" predict version)
  if [[ ! "${version}" =~ ^0\.[0-9]+\.0$ ]]; then
    fail "sbot predicted ${version}, expected a 0.N.0 release; check mode = \"minor\" in .semverbot.toml."
  fi

  git tag -a "${version}" -m "${version}" "${sha}"
  push origin "refs/tags/${version}"
  summary "${version}" "${sha}"
}

function fail() {
  echo "::error::${1}" >&2
  exit 1
}

# Commits older than the 0.N.P scheme can predate the version guard and the per-cluster deploy lock.
function require_version_scheme() {
  if ! git show "${1}:.semverbot.toml" 2>/dev/null | grep -qx 'mode = "minor"'; then
    fail "${1} is older than the 0.N.P version scheme; release a newer main commit instead."
  fi
}

function release_tags_at() {
  git tag --points-at "${1}" --list "${2:-0.*}" | xargs
}

function push() {
  local ref

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "Dry run, skipping: git push ${*}"
    for ref in "${@}"; do
      if [[ "${ref}" == refs/tags/* ]]; then
        git tag -d "${ref#refs/tags/}" >/dev/null
      fi
    done
    return
  fi
  git push "${@}"
}

function summary() {
  {
    echo "### Cut ${1}"
    echo
    echo "- Commit: ${2}"
    echo "- Cherry-picked: ${PICKED[*]:-none}"
  } >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
}

function hotfix() {
  local base_tag="${1}"
  local shas="${2}"
  local minor
  local branch
  local latest
  local remote_head
  local sha_list=()
  local sha
  local tags
  local version

  if [[ ! "${base_tag}" =~ ${TAG_PATTERN} ]]; then
    fail "Base tag '${base_tag}' does not match 0.N.P."
  fi
  if ! git rev-parse -q --verify "refs/tags/${base_tag}" >/dev/null; then
    fail "Tag ${base_tag} does not exist."
  fi
  require_version_scheme "${base_tag}"
  minor=$(cut -d. -f2 <<<"${base_tag}")
  branch="release/0.${minor}"

  remote_head=$(git ls-remote --heads origin "refs/heads/${branch}")
  if [[ -n "${remote_head}" ]]; then
    git fetch origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"
    if ! git merge-base --is-ancestor "${base_tag}" "origin/${branch}"; then
      fail "Tag ${base_tag} is not on ${branch}."
    fi
    git checkout -B "${branch}" "origin/${branch}"
  else
    git checkout -B "${branch}" "${base_tag}"
  fi

  latest="0.${minor}.$(latest_patch "${minor}")"
  if ! git merge-base --is-ancestor "${latest}" HEAD; then
    fail "Tag ${latest} is not on ${branch}; hotfix ${latest} instead of ${base_tag}."
  fi

  read -ra sha_list <<<"${shas}"
  for sha in "${sha_list[@]}"; do
    pick "${sha}" "${branch}"
  done

  tags=$(release_tags_at HEAD "0.${minor}.*")
  if [[ -n "${tags}" ]]; then
    fail "Nothing to release: ${branch} HEAD is already tagged ${tags}."
  fi

  version="0.${minor}.$(($(latest_patch "${minor}") + 1))"
  git tag -a "${version}" -m "${version}"
  push --atomic origin "refs/heads/${branch}" "refs/tags/${version}"
  summary "${version}" "$(git rev-parse HEAD)"
}

function latest_patch() {
  git tag --list "0.${1}.*" | grep -E "^0\.${1}\.[0-9]+$" | cut -d. -f3 | sort -n | tail -1
}

function pick() {
  local sha="${1}"
  local branch="${2}"
  local full

  if [[ ! "${sha}" =~ ${SHA_PATTERN} ]]; then
    fail "${sha} is not a commit SHA."
  fi
  full=$(git rev-parse -q --verify "${sha}^{commit}") || fail "Commit ${sha} does not exist."
  if ! git merge-base --is-ancestor "${full}" origin/main; then
    fail "Commit ${full} is not on main."
  fi
  if git merge-base --is-ancestor "${full}" HEAD ||
    [[ -n "$(git log -F --grep "(cherry picked from commit ${full})" --format=%H origin/main..HEAD)" ]]; then
    echo "Skipping ${full}, already on ${branch}."
    return
  fi

  if ! git cherry-pick -x "${full}"; then
    # An empty pick means a resolution PR already brought the change in.
    if [[ -z "$(git ls-files -u)" ]] && git diff --cached --quiet && git cherry-pick --skip 2>/dev/null; then
      echo "Skipping ${full}, its change is already on ${branch}."
      return
    fi
    git cherry-pick --abort 2>/dev/null || true
    # The resolution PR needs the branch to target.
    push origin "refs/heads/${branch}"
    fail "Cherry-picking ${full} onto ${branch} conflicts. Open a PR into ${branch} that resolves it, merge it, then re-run with the SHAs after ${full}, or none."
  fi
  PICKED+=("${full}")
}

main "${@}"
