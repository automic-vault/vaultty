#!/usr/local/bin/av inject +APPLE_PASSWORD +TEAM_IDENTIFIER +TEAM_COMMON_NAME /bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
vault_dir="${VAULT_DIR:-$HOME/src/automic-vault}"

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

Build, notarize, and publish the Vaultty DMG to a GitHub release.

The shebang injects APPLE_PASSWORD from Automic Vault before the script starts.

Options:
  --output PATH       Write the DMG to PATH before publishing.
  --with-ghostty-vt  Build the app with bundled libghostty-vt support.
  --clobber          Delete an existing GitHub release for vX.Y.Z first.
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

load_env_file() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -n "${line}" && "${line}" != \#* && "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue

    key="${line%%=*}"
    value="${line#*=}"
    if [[ -z "${!key+x}" ]]; then
      export "${key}=${value}"
    fi
  done <"${env_file}"
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

latest_release_tag_before() {
  local target_tag="$1"
  local release_tag releases

  if ! releases="$(
    gh release list \
      --exclude-drafts \
      --limit 50 \
      --json tagName \
      --jq '.[].tagName'
  )"; then
    die "Unable to list GitHub releases"
  fi

  while IFS= read -r release_tag; do
    if [[ -n "${release_tag}" && "${release_tag}" != "${target_tag}" ]]; then
      printf '%s\n' "${release_tag}"
      return 0
    fi
  done <<<"${releases}"

  return 1
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

generate_release_notes() {
  local tag="$1"
  local target_ref="$2"
  local notes_path previous_tag prompt

  require_tool codex
  require_tool gh

  notes_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-notes.XXXXXX")"

  if previous_tag="$(latest_release_tag_before "${tag}")"; then
    ensure_git_tag_available "${previous_tag}"
    prompt="Summarize the user-facing changes in Vaultty since the last release.

Repository: ${repo_root}
Previous release tag: ${previous_tag}
New release tag: ${tag}
Compare range: ${previous_tag}..${target_ref}

Inspect the git history and diff for that range. Write concise GitHub release notes in Markdown.
Focus on behavior, fixes, user-visible improvements, packaging, and operational changes.
Do not include a title, preamble, commit hashes, contributor lists, or references to GitHub auto-generated notes.
Do not edit files or create commits.
Use short bullets grouped under clear headings only when useful."
  else
    prompt="Write initial GitHub release notes for Vaultty.

Repository: ${repo_root}
New release tag: ${tag}
Target ref: ${target_ref}

Inspect the repository and recent git history. Write concise GitHub release notes in Markdown.
Focus on behavior, fixes, user-visible improvements, packaging, and operational changes.
Do not include a title, preamble, commit hashes, contributor lists, or references to GitHub auto-generated notes.
Do not edit files or create commits.
Use short bullets grouped under clear headings only when useful."
  fi

  step "Generating release notes with Codex"
  codex exec \
    --cd "${repo_root}" \
    --sandbox read-only \
    --config approval_policy=\"never\" \
    --color never \
    --ephemeral \
    --output-last-message "${notes_path}" \
    "${prompt}" \
    >&2 ||
    die "Codex release note generation failed"

  [[ -s "${notes_path}" ]] || die "Codex generated empty release notes"
  printf '%s\n' "${notes_path}"
}

clobber_github_release() {
  local tag="$1"
  local notes_path view_error

  require_tool gh
  notes_path="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-notes.XXXXXX")"
  view_error="$(mktemp "${TMPDIR:-/tmp}/vaultty-release-view.XXXXXX")"

  if ! gh release view "${tag}" --json body --jq '.body' >"${notes_path}" 2>"${view_error}"; then
    if grep -Eiq 'release not found|not found|HTTP 404' "${view_error}"; then
      rm -f "${view_error}"
      printf 'Rebuilt release %s.\n' "${tag}" >"${notes_path}"
      printf '%s\n' "${notes_path}"
      return 0
    fi

    cat "${view_error}" >&2
    rm -f "${notes_path}" "${view_error}"
    die "Unable to check existing GitHub release ${tag}"
  fi

  rm -f "${view_error}"
  if [[ ! -s "${notes_path}" ]]; then
    printf 'Rebuilt release %s.\n' "${tag}" >"${notes_path}"
  fi

  step "Clobbering existing GitHub release ${tag}"
  gh release delete "${tag}" --yes --cleanup-tag >&2 ||
    die "Unable to clobber existing GitHub release ${tag}"

  printf '%s\n' "${notes_path}"
}

publish_github_release() {
  local tag="$1"
  local version="$2"
  local dmg_path="$3"
  local asset_label target_ref release_notes_path
  local -a release_args

  require_tool gh
  asset_label="$(basename "${dmg_path}")"
  target_ref="$(git -C "${repo_root}" rev-parse --abbrev-ref HEAD)"
  if [[ "${target_ref}" == "HEAD" ]]; then
    target_ref="$(git -C "${repo_root}" rev-parse HEAD)"
  fi

  if [[ "${clobber_release}" == "true" ]]; then
    release_notes_path="$(clobber_github_release "${tag}")"
  else
    release_notes_path="$(generate_release_notes "${tag}" "${target_ref}")"
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

load_env_file "${vault_dir}/.env"
load_env_file "${repo_root}/.env"
configure_codesign_identity

require_tool git
git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null ||
  die "scripts/publish.sh must run inside a git repository"
git -C "${repo_root}" rev-parse --verify HEAD >/dev/null 2>&1 ||
  die "Create an initial commit before publishing"
if ! git -C "${repo_root}" remote get-url origin >/dev/null 2>&1 && [[ -z "${GH_REPO:-}" ]]; then
  die "Set a git origin remote or GH_REPO before publishing"
fi

app_path="$(build_release_app)"
plist_path="${app_path}/Contents/Info.plist"
version="$(plist_value CFBundleShortVersionString "${plist_path}")"
[[ -n "${version}" ]] || die "Unable to read CFBundleShortVersionString from ${plist_path}"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "Release publishing requires an X.Y.Z version, got: ${version}"

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
publish_github_release "v${version}" "${version}" "${final_dmg}"

done_msg "Published Vaultty ${version}"
printf '%s\n' "${final_dmg}"
