#!/bin/zsh

validate_version() {
  [[ ${1:-} == <->.<->.<-> ]]
}

version_gt() {
  local new_version=${1:-}
  local old_version=${2:-}
  validate_version "$new_version" && validate_version "$old_version" || return 1

  local -a new_parts old_parts
  new_parts=("${(@s:.:)new_version}")
  old_parts=("${(@s:.:)old_version}")

  local index
  for index in 1 2 3; do
    if (( 10#${new_parts[$index]} > 10#${old_parts[$index]} )); then
      return 0
    fi
    if (( 10#${new_parts[$index]} < 10#${old_parts[$index]} )); then
      return 1
    fi
  done

  return 1
}

# The project can already name the next unreleased version. Published tags are
# checked separately and must always be strictly older than the target.
project_version_allows_release() {
  validate_version "${1:-}" && validate_version "${2:-}" || return 1
  [[ "$1" == "$2" ]] || version_gt "$1" "$2"
}

read_single_build_setting() {
  local file=${1:-}
  local key=${2:-}
  [[ -f "$file" && "$key" =~ '^[A-Z0-9_]+$' ]] || return 1

  local output
  output=$(awk -v wanted="$key" '
    $1 == wanted && $2 == "=" {
      value = $3
      sub(/;$/, "", value)
      print value
    }
  ' "$file") || return 1
  [[ -n "$output" ]] || return 1

  local -a values
  values=("${(@f)output}")
  local expected=${values[1]}
  local value
  for value in "${values[@]}"; do
    [[ "$value" == "$expected" ]] || return 1
  done

  print -r -- "$expected"
}

next_build_number() {
  local current
  current=$(read_single_build_setting "${1:-}" CURRENT_PROJECT_VERSION) || return 1
  [[ "$current" == <-> ]] || return 1
  print -r -- $(( 10#$current + 1 ))
}

update_project_versions() {
  local file=${1:-}
  local version=${2:-}
  local build_number=${3:-}
  [[ -f "$file" ]] || return 1
  validate_version "$version" || return 1
  [[ "$build_number" == <-> ]] || return 1

  local current_version current_build
  current_version=$(read_single_build_setting "$file" MARKETING_VERSION) || return 1
  current_build=$(read_single_build_setting "$file" CURRENT_PROJECT_VERSION) || return 1
  [[ "$current_version" != "$version" || "$current_build" != "$build_number" ]] || return 1

  local marketing_count build_count
  marketing_count=$(grep -c '^[[:space:]]*MARKETING_VERSION[[:space:]]*=' "$file") || return 1
  build_count=$(grep -c '^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=' "$file") || return 1
  (( marketing_count > 0 && build_count > 0 )) || return 1

  local temporary_file
  temporary_file=$(mktemp "${file}.tmp.XXXXXX") || return 1
  RELEASE_MARKETING_VERSION="$version" RELEASE_BUILD_NUMBER="$build_number" \
    perl -pe '
      s/^(\s*MARKETING_VERSION\s*=\s*)[^;]+;/$1$ENV{RELEASE_MARKETING_VERSION};/;
      s/^(\s*CURRENT_PROJECT_VERSION\s*=\s*)[^;]+;/$1$ENV{RELEASE_BUILD_NUMBER};/;
    ' "$file" > "$temporary_file" || {
      rm -f -- "$temporary_file"
      return 1
    }

  [[ $(grep -c "^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*$version;" "$temporary_file") -eq $marketing_count ]] || {
    rm -f -- "$temporary_file"
    return 1
  }
  [[ $(grep -c "^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*$build_number;" "$temporary_file") -eq $build_count ]] || {
    rm -f -- "$temporary_file"
    return 1
  }

  mv -- "$temporary_file" "$file"
}

assert_release_notes() {
  local file=${1:-}
  [[ -f "$file" ]] || return 1
  [[ "$(head -n 1 "$file")" == "## What Implemented" ]] || return 1
  grep -Eiq -- '--password|APP_SPECIFIC_PASSWORD|GH_TOKEN' "$file" && return 1

  awk '
    NR == 1 { next }
    /^- .+/ { bullets += 1; next }
    /^[[:space:]]*$/ { next }
    { invalid = 1 }
    END { exit !(bullets > 0 && invalid == 0) }
  ' "$file"
}

render_release_body() {
  assert_release_notes "${1:-}" || return 1
  command cat -- "$1"
}

update_readme_changelog() {
  local readme_file=${1:-}
  local notes_file=${2:-}
  local version=${3:-}
  [[ -f "$readme_file" ]] || return 1
  validate_version "$version" || return 1
  assert_release_notes "$notes_file" || return 1
  grep -Fqx -- "### $version" "$readme_file" && return 1
  [[ $(grep -c -F -- '## Changelog' "$readme_file") -eq 1 ]] || return 1

  local temporary_file
  temporary_file=$(mktemp "${readme_file}.tmp.XXXXXX") || return 1
  awk -v notes_file="$notes_file" -v version="$version" '
    $0 == "## Changelog" {
      print
      print ""
      print "### " version
      notes_line = 0
      while ((getline note < notes_file) > 0) {
        notes_line += 1
        if (notes_line > 1) print note
      }
      close(notes_file)
      next
    }
    { print }
  ' "$readme_file" > "$temporary_file" || {
    rm -f -- "$temporary_file"
    return 1
  }

  [[ $(grep -c -F -- "### $version" "$temporary_file") -eq 1 ]] || {
    rm -f -- "$temporary_file"
    return 1
  }
  mv -- "$temporary_file" "$readme_file"
}

sha256_file() {
  local file=${1:-}
  [[ -f "$file" ]] || return 1
  shasum -a 256 "$file" | awk '{ print $1 }'
}

atomic_install_file() {
  local source_file=${1:-}
  local target_file=${2:-}
  [[ -f "$source_file" && -d "${target_file:h}" ]] || return 1

  local staged_file
  staged_file=$(mktemp "${target_file:h}/.${target_file:t}.release.XXXXXX") || return 1
  cp -p -- "$source_file" "$staged_file" || {
    rm -f -- "$staged_file"
    return 1
  }
  mv -f -- "$staged_file" "$target_file"
}

manifest_write() {
  local file=${1:-}
  shift || return 1
  (( $# > 0 && $# % 2 == 0 )) || return 1

  local -a rows
  local key value
  while (( $# > 0 )); do
    key=$1
    value=$2
    shift 2
    [[ -n "$key" ]] || return 1
    [[ "$key" != *$'\t'* && "$key" != *$'\n'* ]] || return 1
    [[ "$value" != *$'\t'* && "$value" != *$'\n'* ]] || return 1
    rows+=("${key}"$'\t'"${value}")
  done

  local temporary_file
  temporary_file=$(mktemp "${file}.tmp.XXXXXX") || return 1
  print -r -l -- "${rows[@]}" > "$temporary_file" || return 1
  mv -- "$temporary_file" "$file"
}

manifest_read() {
  local file=${1:-}
  local key=${2:-}
  [[ -f "$file" && -n "$key" ]] || return 1

  awk -F '\t' -v wanted="$key" '
    $1 == wanted {
      count += 1
      value = substr($0, index($0, "\t") + 1)
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$file"
}

manifest_assert_schema() {
  local file=${1:-}
  shift || return 1
  [[ -f "$file" && $# -gt 0 ]] || return 1

  local expected actual
  expected=$(print -r -l -- "$@" | LC_ALL=C sort) || return 1
  actual=$(awk -F '\t' '
    NF != 2 || $1 == "" { invalid = 1 }
    { counts[$1] += 1 }
    END {
      if (invalid) exit 1
      for (key in counts) {
        if (counts[key] != 1) exit 1
        print key
      }
    }
  ' "$file" | LC_ALL=C sort) || return 1
  [[ "$actual" == "$expected" ]]
}

assert_artifact_dir_ready() {
  local artifact_dir=${1:-}
  local notes_file=${2:-}
  [[ -d "$artifact_dir" && -f "$notes_file" && "${notes_file:h}" == "$artifact_dir" ]] || return 1

  local entries
  entries=$(find "$artifact_dir" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort) || return 1
  [[ "$entries" == "$notes_file" ]]
}

assert_remote_tag_absent() {
  local repository=${1:-}
  local tag=${2:-}
  [[ -d "$repository" && -n "$tag" ]] || return 1

  local output command_status=0
  output=$(command git -C "$repository" ls-remote --exit-code --tags origin "refs/tags/$tag" 2>&1) || command_status=$?
  case $command_status in
    0)
      print -u2 -r -- "Remote tag already exists: $tag"
      return 2
      ;;
    2)
      [[ -z "$output" ]] || {
        print -u2 -r -- "$output"
        return 1
      }
      return 0
      ;;
    *)
      [[ -z "$output" ]] || print -u2 -r -- "$output"
      return 1
      ;;
  esac
}

assert_github_release_absent() {
  local repository=${1:-}
  local tag=${2:-}
  [[ -n "$repository" && -n "$tag" ]] || return 1

  local output command_status=0 http_status
  output=$(gh api --include "repos/$repository/releases/tags/$tag" 2>&1) || command_status=$?
  http_status=$(print -r -- "$output" | awk '/^HTTP\// { print $2; exit }')
  case "$http_status" in
    404)
      return 0
      ;;
    200)
      print -u2 -r -- "GitHub Release already exists: $tag"
      return 2
      ;;
    *)
      [[ -z "$output" ]] || print -u2 -r -- "$output"
      (( command_status != 0 )) || print -u2 -r -- "Unexpected GitHub API response for $tag"
      return 1
      ;;
  esac
}

assert_git_repository() {
  local repository=${1:-}
  local expected_branch=${2:-}
  local expected_origin=${3:-}
  [[ -d "$repository" && -n "$expected_branch" && -n "$expected_origin" ]] || return 1
  command git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  [[ "$(command git -C "$repository" branch --show-current)" == "$expected_branch" ]] || return 1
  [[ "$(command git -C "$repository" remote get-url origin)" == "$expected_origin" ]] || return 1
}

assert_clean_worktree() {
  local repository=${1:-}
  [[ -d "$repository" ]] || return 1
  [[ -z "$(command git -C "$repository" status --porcelain --untracked-files=all)" ]]
}

latest_version_tag() {
  local repository=${1:-}
  [[ -d "$repository" ]] || return 1

  local latest=""
  local tag version
  for tag in "${(@f)$(command git -C "$repository" tag --list 'v*')}"; do
    version=${tag#v}
    validate_version "$version" || continue
    if [[ -z "$latest" ]] || version_gt "$version" "${latest#v}"; then
      latest=$tag
    fi
  done
  [[ -n "$latest" ]] || return 1
  print -r -- "$latest"
}

latest_remote_version_tag() {
  local repository=${1:-}
  [[ -d "$repository" ]] || return 1

  local output command_status=0
  output=$(command git -C "$repository" ls-remote --tags origin 'refs/tags/v*' 2>&1) || command_status=$?
  if (( command_status != 0 )); then
    [[ -z "$output" ]] || print -u2 -r -- "$output"
    return 1
  fi

  local latest="" line ref version
  for line in "${(@f)output}"; do
    ref=$(print -r -- "$line" | awk '{ print $2 }') || return 1
    ref=${ref#refs/tags/}
    ref=${ref%\^\{\}}
    version=${ref#v}
    validate_version "$version" || continue
    if [[ -z "$latest" ]] || version_gt "$version" "${latest#v}"; then
      latest="v$version"
    fi
  done
  [[ -n "$latest" ]] || return 1
  print -r -- "$latest"
}

assert_target_version() {
  local repository=${1:-}
  local target=${2:-}
  validate_version "$target" || return 1
  local latest
  latest=$(latest_version_tag "$repository") || return 1
  version_gt "$target" "${latest#v}"
}

write_export_options() {
  local file=${1:-}
  local team_id=${2:-}
  [[ -n "$file" && "$team_id" =~ '^[A-Z0-9]+$' ]] || return 1

  plutil -create xml1 "$file" || return 1
  plutil -insert method -string developer-id "$file" || return 1
  plutil -insert destination -string export "$file" || return 1
  plutil -insert signingStyle -string automatic "$file" || return 1
  plutil -insert teamID -string "$team_id" "$file" || return 1
}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || {
      print -u2 -r -- "Missing required command: $command_name"
      return 1
    }
  done
}

find_developer_id_identity() {
  local team_id=${1:-}
  [[ -n "$team_id" ]] || return 1

  local identities matching_line identity_hash
  identities=$(security find-identity -v -p codesigning) || return 1
  matching_line=$(print -r -- "$identities" | grep -E "Developer ID Application: .+ \\(${team_id}\\)" | head -n 1) || return 1
  identity_hash=$(print -r -- "$matching_line" | awk '{ print $2 }')
  [[ "$identity_hash" =~ '^[[:xdigit:]]{40}$' ]] || return 1
  print -r -- "$identity_hash"
}

json_field() {
  local file=${1:-}
  local field=${2:-}
  [[ -f "$file" && -n "$field" ]] || return 1
  plutil -extract "$field" raw -o - "$file"
}

attach_device_from_plist() {
  local file=${1:-}
  [[ -f "$file" ]] || return 1

  local index value
  for index in {0..63}; do
    value=$(plutil -extract "system-entities.$index.dev-entry" raw -o - "$file" 2>/dev/null) || continue
    [[ -n "$value" ]] || continue
    print -r -- "$value"
    return 0
  done
  return 1
}

attach_mount_point_from_plist() {
  local file=${1:-}
  [[ -f "$file" ]] || return 1

  local index value
  for index in {0..63}; do
    value=$(plutil -extract "system-entities.$index.mount-point" raw -o - "$file" 2>/dev/null) || continue
    [[ -n "$value" ]] || continue
    print -r -- "$value"
    return 0
  done
  return 1
}

assert_only_release_changes() {
  local repository=${1:-}
  [[ -d "$repository" ]] || return 1

  local actual
  actual=$(command git -C "$repository" status --porcelain --untracked-files=all | LC_ALL=C sort) || return 1
  local expected=$' M Brewery.xcodeproj/project.pbxproj\n M README.md'
  [[ "$actual" == "$expected" ]]
}

# Only reads the public half; never creates/exports signing secrets during release.
assert_sparkle_public_key() {
  local key_tool=$1 info_plist=$2 account=$3
  local embedded_key signing_key
  embedded_key=$(plutil -extract SUPublicEDKey raw -o - "$info_plist") || return 1
  signing_key=$("$key_tool" -p --account "$account") || return 1
  [[ -n "$embedded_key" && "$embedded_key" == "$signing_key" ]]
}

assert_sparkle_appcast() {
  local feed=$1 dmg=$2 version=$3 build=$4 repository=$5
  local enclosure='/rss/channel/item/enclosure'
  [[ "$(xmllint --xpath 'count(/rss/channel/item)' "$feed")" == 1 ]] || return 1
  [[ "$(xmllint --xpath "count($enclosure)" "$feed")" == 1 ]] || return 1
  [[ "$(xmllint --xpath "string($enclosure/@url)" "$feed")" == "https://github.com/$repository/releases/download/v$version/${dmg:t}" ]] || return 1
  [[ "$(xmllint --xpath "string($enclosure/@length)" "$feed")" == "$(stat -f %z "$dmg")" ]] || return 1
  [[ "$(xmllint --xpath 'string(/rss/channel/item/*[local-name()="version"])' "$feed")" == "$build" ]] || return 1
  [[ "$(xmllint --xpath 'string(/rss/channel/item/*[local-name()="shortVersionString"])' "$feed")" == "$version" ]] || return 1
  local signature
  signature=$(xmllint --xpath "string($enclosure/@*[local-name()='edSignature'])" "$feed") || return 1
  [[ "$signature" =~ '^[A-Za-z0-9+/]{86}==$' ]]
}

verify_release_assets() {
  local readback=$1 dmg_name=$2 dmg_size=$3 dmg_hash=$4 feed_size=$5 feed_hash=$6
  local index name size digest metadata expected_size expected_hash
  local seen_dmg=0 seen_feed=0
  for index in 0 1; do
    name=$(plutil -extract "assets.$index.name" raw -o - "$readback") || return 1
    case "$name" in
      "$dmg_name") (( seen_dmg == 0 )) || return 1; seen_dmg=1; expected_size=$dmg_size; expected_hash=$dmg_hash ;;
      appcast.xml) (( seen_feed == 0 )) || return 1; seen_feed=1; expected_size=$feed_size; expected_hash=$feed_hash ;;
      *) return 1 ;;
    esac
    size=$(plutil -extract "assets.$index.size" raw -o - "$readback") || return 1
    [[ "$size" == "$expected_size" ]] || return 1
    metadata=$(plutil -extract "assets.$index" json -o - "$readback") || return 1
    if digest=$(plutil -extract "assets.$index.digest" raw -o - "$readback" 2>/dev/null); then
      [[ "$digest" == "sha256:$expected_hash" ]] || return 1
    elif ! print -r -- "$metadata" | grep -Eq '"digest"[[:space:]]*:[[:space:]]*null'; then
      return 1
    fi
  done
  (( seen_dmg == 1 && seen_feed == 1 )) || return 1
  ! plutil -extract assets.2 json -o - "$readback" >/dev/null 2>&1
}
