#!/usr/local/bin/av inject +APPLE_PASSWORD /bin/bash
# shellcheck shell=bash disable=SC2096
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

app_name="Vaultty"

build_dir="${repo_root}/target/publish"
target_dir="${repo_root}/target"
output_path=""
clobber_release=false
with_ghostty_vt=false

color_reset=""
color_bold=""
color_blue=""
color_green=""
color_red=""
if [[ -t 2 ]]; then
  color_reset=$'\033[0m'
  color_bold=$'\033[1m'
  color_blue=$'\033[34m'
  color_green=$'\033[32m'
  color_red=$'\033[31m'
fi

usage() {
  cat <<'EOF'
Usage: scripts/publish.sh [--output PATH] [--with-ghostty-vt] [--clobber]

Plan, build, notarize, and publish the Vaultty DMG to a GitHub release.

By default, the script asks Codex to produce:
  1. Release Notes
  2. New Semantic Version based on the changes since the last release

It then updates Cargo.toml and Cargo.lock, commits vX.Y.Z, pushes the branch,
and publishes GitHub release vX.Y.Z.

With --clobber, the script rebuilds and replaces the existing release for the
current Cargo.toml version without asking Codex for notes or a new version.

The shebang injects APPLE_PASSWORD from Automic Vault before the script starts.

Options:
  --output PATH       Write the DMG to PATH before publishing.
  --with-ghostty-vt  Build the app with bundled libghostty-vt support.
  --clobber          Replace the existing GitHub release for the current version.
  --help             Show this help.

EOF
}

info() {
  printf '%s%s%s\n' "${color_blue}" "$*" "${color_reset}" >&2
}

step() {
  printf '%s==>%s %s\n' "${color_bold}" "${color_reset}" "$*" >&2
}

done_msg() {
  printf '%s%s%s\n' "${color_green}" "$*" "${color_reset}" >&2
}

die() {
  printf '%serror:%s %s\n' "${color_red}" "${color_reset}" "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"
}

unquote_env_value() {
  local value="$1"
  case "${value}" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac
  printf '%s' "${value}"
}

normalize_codesign_identity() {
  local identity="$1"
  if [[ "${identity}" == "-" || "${identity}" == *:* ]]; then
    printf '%s' "${identity}"
  else
    printf 'Developer ID Application: %s' "${identity}"
  fi
}

configure_codesign_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(normalize_codesign_identity "$(unquote_env_value "${CODESIGN_IDENTITY}")")"
    export CODESIGN_IDENTITY
    return 0
  fi

  if [[ -z "${TEAM_COMMON_NAME:-}" || -z "${TEAM_IDENTIFIER:-}" ]]; then
    return 0
  fi

  local team_common_name team_identifier
  team_common_name="$(unquote_env_value "${TEAM_COMMON_NAME}")"
  team_identifier="$(unquote_env_value "${TEAM_IDENTIFIER}")"
  [[ -n "${team_common_name}" && -n "${team_identifier}" ]] || return 0

  CODESIGN_IDENTITY="$(normalize_codesign_identity "${team_common_name} (${team_identifier})")"
  export CODESIGN_IDENTITY
}

plist_value() {
  local key="$1"
  local plist="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "${plist}" 2>/dev/null
}

package_version() {
  local pkgid version
  pkgid="$(cargo pkgid --manifest-path "${repo_root}/Cargo.toml")"
  version="${pkgid##*#}"
  printf '%s\n' "${version##*@}"
}

version_gt() {
  local left="$1"
  local right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch

  IFS=. read -r left_major left_minor left_patch <<<"${left}"
  IFS=. read -r right_major right_minor right_patch <<<"${right}"

  if (( 10#${left_major} != 10#${right_major} )); then
    (( 10#${left_major} > 10#${right_major} ))
  elif (( 10#${left_minor} != 10#${right_minor} )); then
    (( 10#${left_minor} > 10#${right_minor} ))
  else
    (( 10#${left_patch} > 10#${right_patch} ))
  fi
}

ensure_clean_worktree() {
  git -C "${repo_root}" diff --quiet ||
    die "Working tree has unstaged changes; commit or stash them before publishing"
  git -C "${repo_root}" diff --cached --quiet ||
    die "Index has staged changes; commit or stash them before publishing"
}

build_release_app() {
  local -a build_app_args
  local build_output app_path

  build_app_args=(--release)
  if [[ "${with_ghostty_vt}" == "true" ]]; then
    build_app_args+=(--with-ghostty-vt)
  fi

  step "Building release app bundle"
  build_output="$("${repo_root}/scripts/build-app.sh" "${build_app_args[@]}")"
  printf '%s\n' "${build_output}" >&2
  app_path="$(printf '%s\n' "${build_output}" | tail -n 1)"

  [[ -d "${app_path}" ]] || die "Build script did not return an app bundle path"
  printf '%s\n' "${app_path}"
}

create_dmg() {
  local app_path="$1"
  local dmg_path="$2"
  local app_bundle_name

  app_bundle_name="$(basename "${app_path}")"

  rm -f "${dmg_path}"
  mkdir -p "$(dirname "${dmg_path}")" "${build_dir}"

  require_tool create-dmg
  step "Composing disk image"
  create-dmg \
    --volname "${app_name}" \
    --window-pos 120 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "${app_bundle_name}" 155 170 \
    --app-drop-link 445 170 \
    --format ULFO \
    --filesystem HFS+ \
    --hdiutil-quiet \
    "${dmg_path}" \
    "${app_path}" \
    >&2
}

notarize_dmg() {
  local dmg_path="$1"
  local team_id="${APPLE_TEAM_ID:-}"

  [[ -n "${APPLE_USERNAME:-}" ]] || die "APPLE_USERNAME is required for notarization"
  [[ -n "${APPLE_PASSWORD:-}" ]] || die "APPLE_PASSWORD was not injected"
  [[ -n "${CODESIGN_IDENTITY:-}" ]] || die "CODESIGN_IDENTITY is required for notarization"

  if [[ -z "${team_id}" ]]; then
    if [[ "${CODESIGN_IDENTITY}" =~ \(([A-Z0-9]+)\)[[:space:]]*$ ]]; then
      team_id="${BASH_REMATCH[1]}"
    else
      die "Unable to extract Apple team ID from CODESIGN_IDENTITY"
    fi
  fi

  require_tool xcrun
  step "Submitting DMG for notarization"
  /usr/bin/xcrun notarytool submit \
    --apple-id "${APPLE_USERNAME}" \
    --team-id "${team_id}" \
    --password "${APPLE_PASSWORD}" \
    --wait \
    "${dmg_path}" \
    >&2

  step "Stapling notarization ticket"
  /usr/bin/xcrun stapler staple "${dmg_path}" >&2
}

latest_release_tag() {
  local release_tag

  require_tool gh

  if ! release_tag="$(
    gh release list \
      --exclude-drafts \
      --limit 1 \
      --json tagName \
      --jq '.[0].tagName'
  )"; then
    die "Unable to list GitHub releases"
  fi

  [[ -n "${release_tag}" && "${release_tag}" != "null" ]] || return 1
  printf '%s\n' "${release_tag}"
}

ensure_git_tag_available() {
  local tag="$1"

  if git -C "${repo_root}" rev-parse --verify --quiet "${tag}^{commit}" >/dev/null; then
    return 0
  fi

  step "Fetching release tag ${tag}"
  git -C "${repo_root}" fetch --quiet origin "refs/tags/${tag}:refs/tags/${tag}" ||
    die "Unable to fetch release tag ${tag}"
}

generate_release_plan() {
  local current_version="$1"
  local plan_path notes_path version_path previous_tag compare_range prompt
  local target_ref

  target_ref="$(git -C "${repo_root}" rev-parse HEAD)"

  require_tool codex
  require_tool gh

  plan_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-plan.XXXXXX")"
  notes_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-notes.XXXXXX")"
  version_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-version.XXXXXX")"

  if previous_tag="$(latest_release_tag)"; then
    ensure_git_tag_available "${previous_tag}"
    compare_range="${previous_tag}..${target_ref}"
    prompt="Plan the next Vaultty release.

Repository: ${repo_root}
Previous release tag: ${previous_tag}
Current Cargo package version: ${current_version}
Compare range: ${compare_range}

Inspect the git history and diff for that range. Choose the next SemVer version based on the changes since the previous release.
Use patch for compatible fixes, minor for new user-visible behavior, and major only for intentional breaking changes.
Write concise GitHub release notes in Markdown focused on behavior, fixes, user-visible improvements, packaging, and operational changes.
Do not edit files or create commits.
Output exactly this format, with no code fence, no title, no preamble, no commit hashes, no contributor list, and no GitHub auto-generated notes references:
1. Release Notes
<release notes markdown>
2. New Semantic Version
<X.Y.Z>"
  else
    prompt="Plan the initial Vaultty release.

Repository: ${repo_root}
Current Cargo package version: ${current_version}
Target ref: ${target_ref}

Inspect the repository and recent git history. Choose the next SemVer version.
Write concise GitHub release notes in Markdown focused on behavior, fixes, user-visible improvements, packaging, and operational changes.
Do not edit files or create commits.
Output exactly this format, with no code fence, no title, no preamble, no commit hashes, no contributor list, and no GitHub auto-generated notes references:
1. Release Notes
<release notes markdown>
2. New Semantic Version
<X.Y.Z>"
  fi

  step "Generating release plan with Codex"
  codex exec \
    --cd "${repo_root}" \
    --sandbox read-only \
    --config approval_policy=\"never\" \
    --color never \
    --ephemeral \
    --output-last-message "${plan_path}" \
    "${prompt}" \
    >&2 ||
    die "Codex release planning failed"

  [[ -s "${plan_path}" ]] || die "Codex generated an empty release plan"

  awk '
    /^[[:space:]]*(1\.)?[[:space:]]*Release Notes[[:space:]]*$/ { in_notes = 1; next }
    /^[[:space:]]*(2\.)?[[:space:]]*New Semantic Version[[:space:]]*$/ { exit }
    in_notes { print }
  ' "${plan_path}" >"${notes_path}"

  awk '
    /^[[:space:]]*(2\.)?[[:space:]]*New Semantic Version[[:space:]]*$/ { in_version = 1; next }
    in_version && match($0, /[0-9]+\.[0-9]+\.[0-9]+/) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  ' "${plan_path}" >"${version_path}"

  [[ -s "${notes_path}" ]] || die "Codex release plan did not include release notes"
  [[ -s "${version_path}" ]] || die "Codex release plan did not include an X.Y.Z version"

  info "1. Release Notes"
  sed 's/^/  /' "${notes_path}" >&2
  info "2. New Semantic Version"
  sed 's/^/  /' "${version_path}" >&2

  printf '%s\n%s\n' "${notes_path}" "${version_path}"
}

bump_cargo_version() {
  local version="$1"

  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Release publishing requires an X.Y.Z version, got: ${version}"

  VERSION="${version}" perl -0pi -e '
    my $version = $ENV{VERSION};
    s/(\[package\](?:(?!^\[).)*?^version\s*=\s*")[^"]+(")/$1$version$2/ms
      or die "Unable to update package.version in Cargo.toml\n";
  ' "${repo_root}/Cargo.toml"

  cargo update \
    --manifest-path "${repo_root}/Cargo.toml" \
    -p vaultty \
    --precise "${version}" \
    >/dev/null
}

commit_release_version() {
  local version="$1"
  local tag="v${version}"

  git -C "${repo_root}" add Cargo.toml Cargo.lock

  if git -C "${repo_root}" diff --cached --quiet; then
    die "Cargo.toml and Cargo.lock were unchanged after version bump"
  fi

  step "Committing ${tag}"
  git -C "${repo_root}" commit -m "${tag}" >&2
}

push_current_branch() {
  local branch

  branch="$(git -C "${repo_root}" rev-parse --abbrev-ref HEAD)"
  [[ "${branch}" != "HEAD" ]] || die "Cannot push release commit from detached HEAD"

  step "Pushing ${branch}"
  git -C "${repo_root}" push >&2
}

clobber_github_release() {
  local tag="$1"
  local view_error

  require_tool gh
  view_error="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-view.XXXXXX")"

  if ! gh release view "${tag}" >/dev/null 2>"${view_error}"; then
    if grep -Eiq 'release not found|not found|HTTP 404' "${view_error}"; then
      rm -f "${view_error}"
      return 0
    fi

    cat "${view_error}" >&2
    rm -f "${view_error}"
    die "Unable to check existing GitHub release ${tag}"
  fi

  rm -f "${view_error}"

  step "Clobbering existing GitHub release ${tag}"
  gh release delete "${tag}" --yes --cleanup-tag >&2 ||
    die "Unable to clobber existing GitHub release ${tag}"
}

existing_release_notes_path() {
  local tag="$1"
  local notes_path view_error

  require_tool gh
  notes_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-existing-release-notes.XXXXXX")"
  view_error="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-view.XXXXXX")"

  if ! gh release view "${tag}" --json body --jq '.body // ""' >"${notes_path}" 2>"${view_error}"; then
    cat "${view_error}" >&2
    rm -f "${notes_path}" "${view_error}"
    die "--clobber requires an existing GitHub release ${tag}"
  fi

  rm -f "${view_error}"
  printf '%s\n' "${notes_path}"
}

publish_github_release() {
  local tag="$1"
  local version="$2"
  local dmg_path="$3"
  local release_notes_path="$4"
  local asset_label target_ref
  local -a release_args

  require_tool gh
  asset_label="$(basename "${dmg_path}")"
  target_ref="$(git -C "${repo_root}" rev-parse HEAD)"

  if [[ "${clobber_release}" == "true" ]]; then
    clobber_github_release "${tag}"
  fi

  release_args=(
    "${tag}"
    --draft
    --notes-file "${release_notes_path}"
    --target "${target_ref}"
    --title "Vaultty ${version}"
  )

  step "Creating draft GitHub release ${tag}"
  gh release create "${release_args[@]}" >&2

  step "Uploading DMG to GitHub release"
  if ! gh release upload "${tag}" "${dmg_path}#${asset_label}" >&2; then
    die "DMG upload failed; draft release remains unpublished: ${tag}"
  fi

  step "Publishing GitHub release ${tag}"
  gh release edit "${tag}" --draft=false >&2 ||
    die "Release publish failed; draft release remains unpublished: ${tag}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || die "--output requires a path"
      output_path="$2"
      shift 2
      ;;
    --with-ghostty-vt)
      with_ghostty_vt=true
      shift
      ;;
    --clobber)
      clobber_release=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

configure_codesign_identity

require_tool git
require_tool cargo
git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null ||
  die "scripts/publish.sh must run inside a git repository"
git -C "${repo_root}" rev-parse --verify HEAD >/dev/null 2>&1 ||
  die "Create an initial commit before publishing"
if ! git -C "${repo_root}" remote get-url origin >/dev/null 2>&1 && [[ -z "${GH_REPO:-}" ]]; then
  die "Set a git origin remote or GH_REPO before publishing"
fi
ensure_clean_worktree

current_version="$(package_version)"

if [[ "${clobber_release}" == "true" ]]; then
  version="${current_version}"
  release_notes_path="$(existing_release_notes_path "v${version}")"
else
  release_plan="$(generate_release_plan "${current_version}")"
  release_notes_path="$(printf '%s\n' "${release_plan}" | sed -n '1p')"
  version_path="$(printf '%s\n' "${release_plan}" | sed -n '2p')"
  version="$(<"${version_path}")"

  if ! version_gt "${version}" "${current_version}"; then
    die "Codex proposed ${version}, which is not newer than current Cargo version ${current_version}"
  fi

  if git -C "${repo_root}" rev-parse --verify --quiet "v${version}^{commit}" >/dev/null; then
    die "Tag v${version} already exists"
  fi

  bump_cargo_version "${version}"
  commit_release_version "${version}"
  push_current_branch
fi

app_path="$(build_release_app)"
plist_path="${app_path}/Contents/Info.plist"
built_version="$(plist_value CFBundleShortVersionString "${plist_path}")"
[[ -n "${built_version}" ]] || die "Unable to read CFBundleShortVersionString from ${plist_path}"
[[ "${built_version}" == "${version}" ]] ||
  die "Built app version ${built_version} does not match planned release version ${version}"

if [[ -z "${output_path}" ]]; then
  output_path="${target_dir}/${app_name}-${version}.dmg"
fi
mkdir -p "$(dirname "${output_path}")"
output_dir="$(cd "$(dirname "${output_path}")" && pwd)"
final_dmg="${output_dir}/$(basename "${output_path}")"

info "Version: ${version}"
info "Output: ${final_dmg}"

create_dmg "${app_path}" "${final_dmg}"
notarize_dmg "${final_dmg}"
publish_github_release "v${version}" "${version}" "${final_dmg}" "${release_notes_path}"

done_msg "Published Vaultty ${version}"
printf '%s\n' "${final_dmg}"
