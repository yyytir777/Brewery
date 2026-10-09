#!/bin/zsh

set -u

TEST_DIR=${0:A:h}
SCRIPT_DIR=${TEST_DIR:h}

source "$SCRIPT_DIR/release_lib.sh"

typeset -gi TESTS_RUN=0
typeset -gi TESTS_FAILED=0

pass() {
  print -r -- "PASS: $1"
}

fail() {
  print -u2 -r -- "FAIL: $1"
  TESTS_FAILED+=1
}

assert_status() {
  local name=$1
  local expected=$2
  shift 2
  TESTS_RUN+=1

  local output_file
  output_file=$(mktemp "${TMPDIR:-/tmp}/brewery-release-assert.XXXXXX") || return 1
  "$@" >"$output_file" 2>&1
  local actual=$?
  if [[ $actual -eq $expected ]]; then
    pass "$name"
  else
    fail "$name (expected status $expected, got $actual)"
    sed 's/^/  | /' "$output_file" >&2
  fi
  rm -f -- "$output_file"
}

assert_eq() {
  local name=$1
  local expected=$2
  local actual=$3
  TESTS_RUN+=1

  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name (expected '$expected', got '$actual')"
  fi
}

assert_file_count() {
  local name=$1
  local expected=$2
  local pattern=$3
  local file=$4
  local actual
  actual=$(grep -c -F -- "$pattern" "$file" 2>/dev/null || true)
  assert_eq "$name" "$expected" "$actual"
}

test_version_helpers() {
  assert_status "allows a preselected unpublished project version" 0 project_version_allows_release 1.0.6 1.0.6
  assert_status "allows advancing the project version" 0 project_version_allows_release 1.0.7 1.0.6
  assert_status "rejects downgrading the project version" 1 project_version_allows_release 1.0.5 1.0.6
  assert_status "rejects invalid equal project versions" 1 project_version_allows_release bad bad
  assert_status "accepts a three-part numeric version" 0 validate_version 1.0.7
  assert_status "rejects a v-prefixed version" 1 validate_version v1.0.7
  assert_status "rejects a two-part version" 1 validate_version 1.0
  assert_status "rejects a prerelease version" 1 validate_version 1.0.7-beta
  assert_status "compares multi-digit patch versions numerically" 0 version_gt 1.0.10 1.0.9
  assert_status "compares major versions numerically" 0 version_gt 2.0.0 1.99.99
  assert_status "rejects equal versions" 1 version_gt 1.0.7 1.0.7
  assert_status "rejects an older target version" 1 version_gt 1.0.6 1.0.7
}

test_project_and_readme_helpers() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-test.XXXXXX") || return 1

  local project_file="$fixture_dir/project.pbxproj"
  local readme_file="$fixture_dir/README.md"
  local notes_file="$fixture_dir/release-notes.md"

  print -r -- $'MARKETING_VERSION = 1.0.6;\nCURRENT_PROJECT_VERSION = 1;\nMARKETING_VERSION = 1.0.6;\nCURRENT_PROJECT_VERSION = 1;' > "$project_file"
  print -r -- $'# Brewery\n\n## Changelog\n\n### 1.0.6\n- Existing change' > "$readme_file"
  print -r -- $'## What Implemented\n- Added release automation\n- Improved release verification' > "$notes_file"

  assert_eq "reads a consistent marketing version" "1.0.6" "$(read_single_build_setting "$project_file" MARKETING_VERSION 2>/dev/null)"
  assert_eq "increments a consistent numeric build number" "2" "$(next_build_number "$project_file" 2>/dev/null)"
  assert_status "updates every project version occurrence" 0 update_project_versions "$project_file" 1.0.7 2
  assert_file_count "updates both marketing version settings" 2 "MARKETING_VERSION = 1.0.7;" "$project_file"
  assert_file_count "updates both build number settings" 2 "CURRENT_PROJECT_VERSION = 2;" "$project_file"
  assert_status "inserts changelog notes once" 0 update_readme_changelog "$readme_file" "$notes_file" 1.0.7
  assert_file_count "adds the target changelog heading once" 1 "### 1.0.7" "$readme_file"
  assert_file_count "copies the first release bullet once" 1 "- Added release automation" "$readme_file"
  assert_status "rejects a duplicate changelog version" 1 update_readme_changelog "$readme_file" "$notes_file" 1.0.7

  local install_source="$fixture_dir/install-source"
  local install_target="$fixture_dir/install-target"
  print -r -- replacement > "$install_source"
  print -r -- original > "$install_target"
  assert_status "atomically installs a prepared metadata file" 0 atomic_install_file "$install_source" "$install_target"
  assert_eq "atomic metadata install replaces the complete target" "replacement" "$(<"$install_target")"

  local inconsistent="$fixture_dir/inconsistent.pbxproj"
  print -r -- $'MARKETING_VERSION = 1.0.6;\nMARKETING_VERSION = 1.0.5;' > "$inconsistent"
  assert_status "rejects inconsistent project settings" 1 read_single_build_setting "$inconsistent" MARKETING_VERSION

  rm -rf -- "$fixture_dir"
}

test_notes_checksum_and_manifest_helpers() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-test.XXXXXX") || return 1

  local notes_file="$fixture_dir/release-notes.md"
  local manifest_file="$fixture_dir/release.manifest"
  local payload_file="$fixture_dir/payload"

  print -r -- $'## What Implemented\n- Added release automation' > "$notes_file"
  print -rn -- 'brewery' > "$payload_file"

  assert_status "accepts Brewery-style release notes" 0 assert_release_notes "$notes_file"
  print -r -- $'## Changes\n- Added release automation' > "$notes_file"
  assert_status "rejects the wrong release-note heading" 1 assert_release_notes "$notes_file"
  print -r -- $'## What Implemented\n- ' > "$notes_file"
  assert_status "rejects an empty release-note bullet" 1 assert_release_notes "$notes_file"
  print -r -- $'## What Implemented\n- Use --password secret' > "$notes_file"
  assert_status "rejects password material in release notes" 1 assert_release_notes "$notes_file"

  local digest
  digest=$(sha256_file "$payload_file" 2>/dev/null)
  assert_eq "computes the known SHA-256 digest" "35e7dccc7e21bac3738fec68ddf4aef763f94f8fa955413b00c01923a41a8392" "$digest"

  assert_status "writes a literal manifest" 0 manifest_write "$manifest_file" version 1.0.7 title "Release : v1.0.7"
  assert_eq "reads a literal manifest value" "Release : v1.0.7" "$(manifest_read "$manifest_file" title 2>/dev/null)"
  assert_status "rejects a missing manifest key" 1 manifest_read "$manifest_file" missing
  assert_status "rejects a manifest value containing a tab" 1 manifest_write "$manifest_file" bad $'contains\ta tab'
  assert_status "accepts an exact manifest schema" 0 manifest_assert_schema "$manifest_file" version title
  assert_status "rejects a manifest with an unexpected key" 1 manifest_assert_schema "$manifest_file" version
  assert_status "rejects a manifest with a missing key" 1 manifest_assert_schema "$manifest_file" version title missing

  local artifact_dir="$fixture_dir/artifacts"
  mkdir -p -- "$artifact_dir"
  print -r -- $'## What Implemented\n- Safe release' > "$artifact_dir/release-notes.md"
  assert_status "accepts an artifact directory containing only release notes" 0 assert_artifact_dir_ready "$artifact_dir" "$artifact_dir/release-notes.md"
  print -r -- unexpected > "$artifact_dir/leftover.txt"
  assert_status "rejects unexpected files in the artifact directory" 1 assert_artifact_dir_ready "$artifact_dir" "$artifact_dir/release-notes.md"

  rm -rf -- "$fixture_dir"
}

test_prepare_preflight_helpers() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-git-test.XXXXXX") || return 1

  mkdir -p -- "$fixture_dir/Configuration"
  plutil -create xml1 "$fixture_dir/Configuration/Brewery-Info.plist"
  plutil -insert SUPublicEDKey -string fixture-public-key "$fixture_dir/Configuration/Brewery-Info.plist"
  command git -C "$fixture_dir" init -q -b main
  command git -C "$fixture_dir" config user.email release-test@example.com
  command git -C "$fixture_dir" config user.name "Release Test"
  print -r -- 'fixture' > "$fixture_dir/tracked.txt"
  command git -C "$fixture_dir" add tracked.txt
  command git -C "$fixture_dir" commit -q -m 'initial'
  command git -C "$fixture_dir" tag v1.0.5
  command git -C "$fixture_dir" remote add origin https://github.com/yyytir777/Brewery.git

  assert_status "accepts clean main with the expected origin" 0 assert_git_repository "$fixture_dir" main https://github.com/yyytir777/Brewery.git
  print -r -- 'dirty' > "$fixture_dir/dirty.txt"
  assert_status "rejects an untracked worktree file" 1 assert_clean_worktree "$fixture_dir"
  rm -f -- "$fixture_dir/dirty.txt"

  command git -C "$fixture_dir" switch -q -c feature/test
  assert_status "rejects a non-main branch" 1 assert_git_repository "$fixture_dir" main https://github.com/yyytir777/Brewery.git
  command git -C "$fixture_dir" switch -q main

  assert_eq "finds the latest semantic version tag" "v1.0.5" "$(latest_version_tag "$fixture_dir" 2>/dev/null)"
  assert_status "accepts a newer target than the latest tag" 0 assert_target_version "$fixture_dir" 1.0.6
  assert_status "rejects a target equal to the latest tag" 1 assert_target_version "$fixture_dir" 1.0.5
  assert_status "rejects an older target than the latest tag" 1 assert_target_version "$fixture_dir" 1.0.4

  local export_options="$fixture_dir/ExportOptions.plist"
  assert_status "writes Developer ID export options" 0 write_export_options "$export_options" Y65C87UHRQ
  assert_eq "sets developer-id export method" "developer-id" "$(plutil -extract method raw -o - "$export_options" 2>/dev/null)"
  assert_eq "sets local export destination" "export" "$(plutil -extract destination raw -o - "$export_options" 2>/dev/null)"
  assert_eq "sets automatic export signing" "automatic" "$(plutil -extract signingStyle raw -o - "$export_options" 2>/dev/null)"
  assert_eq "sets the export team" "Y65C87UHRQ" "$(plutil -extract teamID raw -o - "$export_options" 2>/dev/null)"

  local attach_plist="$fixture_dir/attach.plist"
  print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>system-entities</key><array>
<dict><key>dev-entry</key><string>/dev/disk99</string></dict>
<dict><key>dev-entry</key><string>/dev/disk99s1</string><key>mount-point</key><string>/Volumes/Brewery</string></dict>
</array></dict></plist>' > "$attach_plist"
  assert_eq "reads the attached disk device from hdiutil plist" "/dev/disk99" "$(attach_device_from_plist "$attach_plist" 2>/dev/null)"
  assert_eq "reads the mounted volume from hdiutil plist" "/Volumes/Brewery" "$(attach_mount_point_from_plist "$attach_plist" 2>/dev/null)"

  rm -rf -- "$fixture_dir"
}

test_release_cli_argument_validation() {
  assert_status "CLI rejects a missing mode" 64 zsh "$SCRIPT_DIR/release.sh"
  assert_status "CLI rejects an unknown mode" 64 zsh "$SCRIPT_DIR/release.sh" unknown 1.0.7
  assert_status "CLI rejects an invalid version" 64 zsh "$SCRIPT_DIR/release.sh" prepare v1.0.7
}

write_fake_release_tool() {
  local fake_tool=$1
  print -r -- $'#!/bin/zsh
set -u
tool=${0:t}
print -r -- "$tool $*" >> "$FAKE_COMMAND_LOG"

case "$tool" in
  git)
    subcommand=${1:-}
    if [[ "$subcommand" == -C ]]; then
      subcommand=${3:-}
    fi
    if [[ "$subcommand" == push ]]; then
      return 0
    fi
    if [[ "$subcommand" == ls-remote ]]; then
      if [[ "${@: -1}" == "refs/tags/v*" ]]; then
        if [[ -n "${FAKE_REMOTE_LATEST_STATE:-}" && -f "$FAKE_REMOTE_LATEST_STATE" ]]; then
          remote_latest=$(cat "$FAKE_REMOTE_LATEST_STATE")
        else
          remote_latest=${FAKE_REMOTE_LATEST_TAG:-v1.0.5}
        fi
        print -r -- "abc123 refs/tags/$remote_latest"
        return 0
      fi
      case "${FAKE_REMOTE_TAG_RESULT:-absent}" in
        absent) return 2 ;;
        exists) print -r -- $\'abc123\\trefs/tags/v1.0.7\'; return 0 ;;
        error) print -u2 -r -- "fatal: simulated remote failure"; return 128 ;;
      esac
    fi
    if [[ "$subcommand" == diff && -n "${FAKE_TAMPER_ON_PREVIEW_DMG:-}" && ! -f "${FAKE_TAMPER_MARKER:-/nonexistent}" ]]; then
      print -rn -- tampered >> "$FAKE_TAMPER_ON_PREVIEW_DMG"
      : > "$FAKE_TAMPER_MARKER"
    fi
    if [[ "$subcommand" == diff && -n "${FAKE_ADVANCE_REMOTE_ON_PREVIEW:-}" && ! -f "$FAKE_ADVANCE_REMOTE_ON_PREVIEW" ]]; then
      print -r -- v1.0.6 > "$FAKE_ADVANCE_REMOTE_ON_PREVIEW"
    fi
    exec /usr/bin/git "$@"
    ;;
  security)
    print -r -- $\'  1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Developer ID Application: Release Test (Y65C87UHRQ)"\'
    print -r -- "     1 valid identities found"
    ;;
  gh)
    if [[ "${1:-}" == auth && "${2:-}" == status ]]; then
      return 0
    fi
    if [[ "${1:-}" == api ]]; then
      case "${FAKE_GH_API_RESULT:-absent}" in
        absent) print -r -- "HTTP/2.0 404 Not Found"; return 1 ;;
        exists) print -r -- "HTTP/2.0 200 OK"; return 0 ;;
        error) print -u2 -r -- "simulated GitHub transport failure"; return 1 ;;
      esac
    fi
    if [[ "${1:-}" == release && "${2:-}" == view ]]; then
      state=${FAKE_GH_RELEASE_STATE:-}
      [[ -n "$state" && -f "$state" ]] || return 1
      if [[ " $* " == *" --json tagName,name,body,isDraft,isPrerelease,assets,url "* ]]; then
        [[ "${FAKE_GH_DIGEST_READ_ERROR:-0}" == 0 ]] || return 1
        plist=$(mktemp "${TMPDIR:-/tmp}/fake-gh-release.XXXXXX") || return 1
        command plutil -create xml1 "$plist"
        command plutil -insert tagName -string "$(cat "${state}.tag")" "$plist"
        command plutil -insert name -string "$(cat "${state}.title")" "$plist"
        command plutil -insert body -string "$(cat "${state}.body")" "$plist"
        command plutil -insert isDraft -bool false "$plist"
        command plutil -insert isPrerelease -bool false "$plist"
        command plutil -insert url -string "https://github.com/yyytir777/Brewery/releases/tag/$(cat "${state}.tag")" "$plist"
        command plutil -insert assets -array "$plist"
        command plutil -insert assets.0 -dictionary "$plist"
        command plutil -insert assets.0.name -string "$(cat "${state}.asset")" "$plist"
        command plutil -insert assets.0.size -integer "$(cat "${state}.size")" "$plist"
        command plutil -insert assets.0.digest -string "$(cat "${state}.digest")" "$plist"
        command plutil -insert assets.1 -dictionary "$plist"
        command plutil -insert assets.1.name -string appcast.xml "$plist"
        command plutil -insert assets.1.size -integer "$(cat "${state}.feed-size")" "$plist"
        command plutil -insert assets.1.digest -string "$(cat "${state}.feed-digest")" "$plist"
        command plutil -convert json -o - "$plist"
        rm -f -- "$plist"
        return 0
      fi
      args=("$@")
      query_index=${args[(i)--jq]}
      query=${args[$(( query_index + 1 ))]:-}
      case "$query" in
        .tagName) cat "${state}.tag" ;;
        .name) cat "${state}.title" ;;
        .body) cat "${state}.body" ;;
        .isDraft) print -r -- false ;;
        .isPrerelease) print -r -- false ;;
        \'.assets | length\') print -r -- 1 ;;
        \'.assets[0].name\') cat "${state}.asset" ;;
        \'.assets[0].size\') cat "${state}.size" ;;
        \'.assets[0].digest\')
          [[ "${FAKE_GH_DIGEST_READ_ERROR:-0}" == 0 ]] || return 1
          cat "${state}.digest"
          ;;
        .url) print -r -- "https://github.com/yyytir777/Brewery/releases/tag/$(cat "${state}.tag")" ;;
        *) return 1 ;;
      esac
      return 0
    fi
    if [[ "${1:-}" == release && "${2:-}" == create ]]; then
      state=${FAKE_GH_RELEASE_STATE:?missing fake release state}
      tag=${3:?missing tag}
      dmg=${4:?missing dmg}
      feed=${5:?missing appcast}
      args=("$@")
      title_index=${args[(i)--title]}
      notes_index=${args[(i)--notes-file]}
      title=${args[$(( title_index + 1 ))]}
      notes=${args[$(( notes_index + 1 ))]}
      print -r -- "$tag" > "${state}.tag"
      print -r -- "$title" > "${state}.title"
      cp "$notes" "${state}.body"
      print -r -- "${dmg:t}" > "${state}.asset"
      stat -f %z "$dmg" > "${state}.size"
      print -r -- "sha256:$(shasum -a 256 "$dmg" | awk \'{ print $1 }\')" > "${state}.digest"
      stat -f %z "$feed" > "${state}.feed-size"
      print -r -- "sha256:$(shasum -a 256 "$feed" | awk \'{ print $1 }\')" > "${state}.feed-digest"
      : > "$state"
      return 0
    fi
    return 0
    ;;
  xcodebuild)
    args=("$@")
    if [[ " $* " == *" archive "* || " $* " == *" -resolvePackageDependencies "* ]]; then
      index=${args[(i)-archivePath]}
      if (( index <= ${#args} )); then
        archive_path=${args[$(( index + 1 ))]}
        mkdir -p -- "$archive_path"
      fi
      index=${args[(i)-derivedDataPath]}
      derived_path=${args[$(( index + 1 ))]}
      sparkle_bin="$derived_path/SourcePackages/artifacts/sparkle/Sparkle/bin"
      mkdir -p -- "$sparkle_bin"
      for sparkle_tool in generate_keys generate_appcast sign_update; do
        cp "$0" "$sparkle_bin/$sparkle_tool"
      done
      return 0
    fi
    if [[ " $* " == *" -exportArchive "* ]]; then
      index=${args[(i)-exportPath]}
      export_path=${args[$(( index + 1 ))]}
      mkdir -p -- "$export_path/Brewery.app/Contents"
      command plutil -create xml1 "$export_path/Brewery.app/Contents/Info.plist"
      command plutil -insert SUPublicEDKey -string fixture-public-key "$export_path/Brewery.app/Contents/Info.plist"
      return 0
    fi
    return 0
    ;;
  sign_update)
    return "${FAKE_SPARKLE_VERIFY_FAIL:-0}"
    ;;
  generate_keys)
    [[ "${FAKE_SPARKLE_MISSING_KEY:-0}" == 0 ]] || return 1
    print -r -- "${FAKE_SPARKLE_PUBLIC_KEY:-fixture-public-key}"
    ;;
  generate_appcast)
    [[ "${FAKE_SPARKLE_GENERATION_FAIL:-0}" == 0 ]] || return 1
    args=("$@")
    index=${args[(i)--download-url-prefix]}
    prefix=${args[$(( index + 1 ))]}
    folder=${args[-1]}
    signature=$(printf "%086d==" 0)
    print -r -- "<rss xmlns:sparkle=\\\"http://www.andymatuschak.org/xml-namespaces/sparkle\\\"><channel><item><sparkle:version>2</sparkle:version><sparkle:shortVersionString>1.0.7</sparkle:shortVersionString><enclosure url=\\\"${prefix}Brewery-1.0.7.dmg\\\" length=\\\"$(stat -f %z "$folder/Brewery-1.0.7.dmg")\\\" sparkle:edSignature=\\\"$signature\\\" /></item></channel></rss>" > "$folder/appcast.xml"
    ;;
  create-dmg)
    args=("$@")
    output_path=${args[-2]}
    print -rn -- "signed dmg" > "$output_path"
    ;;
  xcrun)
    if [[ "${1:-}" == notarytool && "${2:-}" == history ]]; then
      print -r -- $\'{"history":[]}\'
      return 0
    fi
    if [[ "${1:-}" == notarytool && "${2:-}" == submit ]]; then
      print -r -- "{\\\"id\\\":\\\"11111111-2222-3333-4444-555555555555\\\",\\\"status\\\":\\\"${FAKE_NOTARY_STATUS:-Accepted}\\\"}"
      return 0
    fi
    if [[ "${1:-}" == notarytool && "${2:-}" == wait ]]; then
      print -r -- "{\\\"id\\\":\\\"${3:-unknown}\\\",\\\"status\\\":\\\"${FAKE_NOTARY_STATUS:-Accepted}\\\"}"
      return "${FAKE_NOTARY_EXIT:-0}"
    fi
    if [[ "${1:-}" == notarytool && "${2:-}" == log ]]; then
      print -r -- "{\\\"jobId\\\":\\\"${3:-unknown}\\\",\\\"status\\\":\\\"${FAKE_NOTARY_STATUS:-Accepted}\\\",\\\"issues\\\":[]}" > "${4:?missing log path}"
      return 0
    fi
    if [[ "${1:-}" == stapler ]]; then
      if [[ "${2:-}" == staple && -n "${FAKE_STAPLED_MARKER:-}" ]]; then
        : > "$FAKE_STAPLED_MARKER"
      fi
      return 0
    fi
    return 1
    ;;
  hdiutil)
    if [[ "${1:-}" == verify ]]; then
      return 0
    fi
    if [[ "${1:-}" == attach ]]; then
      mkdir -p -- "$FAKE_MOUNT_POINT/Brewery.app"
      print -r -- "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict><key>system-entities</key><array>
<dict><key>dev-entry</key><string>/dev/disk99</string></dict>
<dict><key>dev-entry</key><string>/dev/disk99s1</string><key>mount-point</key><string>$FAKE_MOUNT_POINT</string></dict>
</array></dict></plist>"
      return 0
    fi
    if [[ "${1:-}" == detach ]]; then
      return 0
    fi
    return 1
    ;;
  codesign)
    return 0
    ;;
  spctl)
    if [[ "${FAKE_REJECT_PRENOTARY_SPCTL:-0}" == 1 && ! -f "${FAKE_STAPLED_MARKER:-/nonexistent}" ]]; then
      return 1
    fi
    return 0
    ;;
esac' > "$fake_tool"
  chmod +x "$fake_tool"
}

test_publish_fails_closed_when_digest_readback_fails() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-readback-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"
  local release_state="$fixture_dir/.release/github-release-state"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "readback fixture prepares successfully" 0 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    FAKE_GH_DIGEST_READ_ERROR=1 \
    assert_status "publish fails closed when release digest read-back fails" 1 \
      run_publish_with_input "PUBLISH v1.0.7" "$fixture_dir/scripts/release.sh" 1.0.7

  assert_status "read-back failure occurs after release creation" 0 test -f "$release_state"
  assert_file_count "read-back failure does not create a second release" 1 "gh release create" "$command_log"

  rm -rf -- "$fixture_dir"
}

test_remote_absence_checks_fail_closed() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-remote-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"

  PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" \
    assert_status "accepts a definitely absent remote tag" 0 assert_remote_tag_absent "$fixture_dir" v1.0.7
  PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" FAKE_REMOTE_TAG_RESULT=exists \
    assert_status "distinguishes an existing remote tag" 2 assert_remote_tag_absent "$fixture_dir" v1.0.7
  PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" FAKE_REMOTE_TAG_RESULT=error \
    assert_status "fails closed on a remote tag transport error" 1 assert_remote_tag_absent "$fixture_dir" v1.0.7
  local remote_latest
  remote_latest=$(PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" latest_remote_version_tag "$fixture_dir" 2>/dev/null)
  assert_eq "finds the latest remote semantic tag" v1.0.5 "$remote_latest"
  remote_latest=$(PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" FAKE_REMOTE_LATEST_TAG=v1.0.6 latest_remote_version_tag "$fixture_dir" 2>/dev/null)
  assert_eq "detects a newer remote semantic tag" v1.0.6 "$remote_latest"

  PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" \
    assert_status "accepts a definite GitHub release 404" 0 assert_github_release_absent yyytir777/Brewery v1.0.7
  PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" FAKE_GH_API_RESULT=exists \
    assert_status "distinguishes an existing GitHub release" 2 assert_github_release_absent yyytir777/Brewery v1.0.7
  PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" FAKE_GH_API_RESULT=error \
    assert_status "fails closed on a GitHub release transport error" 1 assert_github_release_absent yyytir777/Brewery v1.0.7

  rm -rf -- "$fixture_dir"
}

make_release_fixture() {
  local fixture_dir=$1
  local version=$2
  mkdir -p -- "$fixture_dir/scripts" "$fixture_dir/bin" "$fixture_dir/.release/$version" "$fixture_dir/fake-mount"
  cp "$SCRIPT_DIR/release.sh" "$fixture_dir/scripts/release.sh"
  cp "$SCRIPT_DIR/release_lib.sh" "$fixture_dir/scripts/release_lib.sh"

  print -r -- $'MARKETING_VERSION = 1.0.6;\nCURRENT_PROJECT_VERSION = 1;\nMARKETING_VERSION = 1.0.6;\nCURRENT_PROJECT_VERSION = 1;' > "$fixture_dir/Brewery.xcodeproj.project.pbxproj"
  mkdir -p -- "$fixture_dir/Brewery.xcodeproj"
  cp "$fixture_dir/Brewery.xcodeproj.project.pbxproj" "$fixture_dir/Brewery.xcodeproj/project.pbxproj"
  rm -f -- "$fixture_dir/Brewery.xcodeproj.project.pbxproj"
  print -r -- $'# Brewery\n\n## Changelog\n\n### 1.0.6\n- Existing change' > "$fixture_dir/README.md"
  print -r -- $'## What Implemented\n- Added safe release automation\n- Added notarization verification' > "$fixture_dir/.release/$version/release-notes.md"
  print -r -- $'.release/\nbin/\nfake-mount/\nRELEASE_AI.md\nRELEASE_IMPLEMENTATION_PLAN.md' > "$fixture_dir/.gitignore"

  mkdir -p -- "$fixture_dir/Configuration"
  plutil -create xml1 "$fixture_dir/Configuration/Brewery-Info.plist"
  plutil -insert SUPublicEDKey -string fixture-public-key "$fixture_dir/Configuration/Brewery-Info.plist"
  command git -C "$fixture_dir" init -q -b main
  command git -C "$fixture_dir" config user.email release-test@example.com
  command git -C "$fixture_dir" config user.name "Release Test"
  command git -C "$fixture_dir" add .gitignore Brewery.xcodeproj/project.pbxproj README.md scripts Configuration
  command git -C "$fixture_dir" commit -q -m 'initial'
  command git -C "$fixture_dir" tag v1.0.5
  command git -C "$fixture_dir" remote add origin https://github.com/yyytir777/Brewery.git

  local fake_tool="$fixture_dir/bin/fake-release-tool"
  write_fake_release_tool "$fake_tool"
  local tool
  for tool in git security gh xcodebuild create-dmg xcrun hdiutil codesign spctl; do
    ln -s fake-release-tool "$fixture_dir/bin/$tool"
  done
}

test_prepare_artifact_workflow() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-prepare-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_REJECT_PRENOTARY_SPCTL=1 \
    FAKE_STAPLED_MARKER="$fixture_dir/.release/stapled" \
    assert_status "prepare completes the signed notarized artifact workflow" 0 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7

  assert_file_count "prepare updates both project marketing versions" 2 "MARKETING_VERSION = 1.0.7;" "$fixture_dir/Brewery.xcodeproj/project.pbxproj"
  assert_file_count "prepare updates both project build numbers" 2 "CURRENT_PROJECT_VERSION = 2;" "$fixture_dir/Brewery.xcodeproj/project.pbxproj"
  assert_file_count "prepare adds the release changelog once" 1 "### 1.0.7" "$fixture_dir/README.md"
  assert_status "prepare creates the versioned DMG" 0 test -f "$fixture_dir/.release/1.0.7/Brewery-1.0.7.dmg"
  assert_status "prepare creates a signed appcast" 0 test -f "$fixture_dir/.release/1.0.7/appcast.xml"
  assert_file_count "prepare signs with dedicated account" 1 "generate_appcast --maximum-deltas 0 --embed-release-notes --account brewery-sparkle" "$command_log"
  assert_status "prepare creates a release manifest" 0 test -f "$fixture_dir/.release/1.0.7/release.manifest"
  assert_eq "prepare records accepted notarization" "Accepted" "$(manifest_read "$fixture_dir/.release/1.0.7/release.manifest" notary_status 2>/dev/null)"
  assert_eq "prepare does not create a release commit" "initial" "$(command git -C "$fixture_dir" log -1 --pretty=%s)"
  assert_eq "prepare does not create the target tag" "" "$(command git -C "$fixture_dir" tag --list v1.0.7)"
  assert_file_count "prepare archives exactly once" 1 "xcodebuild archive" "$command_log"
  assert_file_count "prepare submits exactly once" 1 "xcrun notarytool submit" "$command_log"
  assert_file_count "prepare staples exactly once" 1 "xcrun stapler staple" "$command_log"
  assert_file_count "prepare detaches the mounted DMG" 1 "hdiutil detach" "$command_log"

  rm -rf -- "$fixture_dir"
}

test_notary_rejection_stops_prepare() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-reject-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_NOTARY_STATUS=Invalid \
    FAKE_NOTARY_EXIT=1 \
    assert_status "notary rejection fails prepare" 1 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7

  assert_file_count "rejection leaves project versions unchanged" 2 "MARKETING_VERSION = 1.0.6;" "$fixture_dir/Brewery.xcodeproj/project.pbxproj"
  assert_file_count "rejection leaves README unchanged" 0 "### 1.0.7" "$fixture_dir/README.md"
  assert_status "rejection preserves the notary submission" 0 test -f "$fixture_dir/.release/1.0.7/notary-submit.json"
  assert_status "rejection preserves the notary wait response" 0 test -f "$fixture_dir/.release/1.0.7/notary-wait.json"
  assert_status "rejection preserves the notary log" 0 test -f "$fixture_dir/.release/1.0.7/notary-log.json"
  assert_status "rejection creates no publish manifest" 1 test -f "$fixture_dir/.release/1.0.7/release.manifest"
  assert_file_count "rejection never staples the DMG" 0 "xcrun stapler staple" "$command_log"
  assert_file_count "notary wait has a bounded timeout" 1 "xcrun notarytool wait 11111111-2222-3333-4444-555555555555 --keychain-profile brewery-notary --timeout 30m" "$command_log"

  rm -rf -- "$fixture_dir"
}

test_prepare_rejects_leftover_artifacts() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-leftover-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"
  print -r -- stale > "$fixture_dir/.release/1.0.7/stale-output"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    assert_status "prepare rejects a version directory with leftover artifacts" 1 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7
  assert_file_count "leftover artifact rejection happens before archive" 0 "xcodebuild archive" "$command_log"

  rm -rf -- "$fixture_dir"
}

test_prepare_rejects_stale_local_tags() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-stale-tag-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_REMOTE_LATEST_TAG=v1.0.6 \
    assert_status "prepare rejects stale local release tags" 1 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7
  assert_file_count "stale tag rejection happens before archive" 0 "xcodebuild archive" "$command_log"

  rm -rf -- "$fixture_dir"
}

run_publish_with_input() {
  local input=$1
  local script=$2
  local version=$3
  print -r -- "$input" | zsh "$script" publish "$version"
}

test_publish_confirmation_and_integrity() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-publish-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"
  local release_state="$fixture_dir/.release/github-release-state"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "publish fixture prepares successfully" 0 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "exact confirmation publishes the prepared release" 0 \
      run_publish_with_input "PUBLISH v1.0.7" "$fixture_dir/scripts/release.sh" 1.0.7

  assert_eq "publish creates the fixed release commit" "chore: release v1.0.7" "$(command git -C "$fixture_dir" log -1 --pretty=%s)"
  assert_eq "publish creates the annotated target tag" "v1.0.7" "$(command git -C "$fixture_dir" tag --list v1.0.7)"
  assert_file_count "publish pushes branch and tag atomically once" 1 "push --atomic origin main refs/tags/v1.0.7" "$command_log"
  assert_file_count "publish creates one GitHub Release" 1 "gh release create v1.0.7" "$command_log"
  assert_status "publish fake records the GitHub Release" 0 test -f "$release_state"

  rm -rf -- "$fixture_dir"
}

test_publish_cancellation_and_tamper_detection() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-cancel-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"
  local release_state="$fixture_dir/.release/github-release-state"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "cancel fixture prepares successfully" 0 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "ordinary yes does not pass the publish gate" 1 \
      run_publish_with_input yes "$fixture_dir/scripts/release.sh" 1.0.7
  assert_eq "cancel leaves the source commit unchanged" "initial" "$(command git -C "$fixture_dir" log -1 --pretty=%s)"
  assert_eq "cancel creates no target tag" "" "$(command git -C "$fixture_dir" tag --list v1.0.7)"
  assert_status "cancel creates no GitHub Release" 1 test -f "$release_state"

  cp "$fixture_dir/.release/1.0.7/appcast.xml" "$fixture_dir/.release/original-appcast.xml"
  print -rn -- tampered >> "$fixture_dir/.release/1.0.7/appcast.xml"
  PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" FAKE_MOUNT_POINT="$fixture_dir/fake-mount" FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "changed appcast is rejected before confirmation" 1 \
      run_publish_with_input "PUBLISH v1.0.7" "$fixture_dir/scripts/release.sh" 1.0.7
  cp "$fixture_dir/.release/original-appcast.xml" "$fixture_dir/.release/1.0.7/appcast.xml"
  print -rn -- tampered >> "$fixture_dir/.release/1.0.7/Brewery-1.0.7.dmg"
  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "changed DMG is rejected before confirmation" 1 \
      run_publish_with_input "PUBLISH v1.0.7" "$fixture_dir/scripts/release.sh" 1.0.7
  assert_eq "tamper rejection leaves the source commit unchanged" "initial" "$(command git -C "$fixture_dir" log -1 --pretty=%s)"
  assert_file_count "cancel and tamper paths never push" 0 "git push --atomic" "$command_log"

  rm -rf -- "$fixture_dir"
}

test_publish_revalidates_after_confirmation() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-race-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"
  local release_state="$fixture_dir/.release/github-release-state"
  local dmg_path="$fixture_dir/.release/1.0.7/Brewery-1.0.7.dmg"
  local tamper_marker="$fixture_dir/.release/tampered-during-preview"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "race fixture prepares successfully" 0 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    FAKE_TAMPER_ON_PREVIEW_DMG="$dmg_path" \
    FAKE_TAMPER_MARKER="$tamper_marker" \
    assert_status "publish rejects a DMG changed while confirmation waits" 1 \
      run_publish_with_input "PUBLISH v1.0.7" "$fixture_dir/scripts/release.sh" 1.0.7

  assert_eq "confirmation-time tamper creates no release commit" "initial" "$(command git -C "$fixture_dir" log -1 --pretty=%s)"
  assert_eq "confirmation-time tamper creates no tag" "" "$(command git -C "$fixture_dir" tag --list v1.0.7)"
  assert_file_count "confirmation-time tamper never pushes" 0 "push --atomic" "$command_log"
  assert_file_count "confirmation-time tamper never creates a release" 0 "gh release create" "$command_log"

  rm -rf -- "$fixture_dir"
}

test_publish_rejects_newer_remote_release_after_confirmation() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-remote-race-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"
  local release_state="$fixture_dir/.release/github-release-state"
  local remote_latest_state="$fixture_dir/.release/remote-latest-state"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    FAKE_REMOTE_LATEST_STATE="$remote_latest_state" \
    assert_status "remote race fixture prepares successfully" 0 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    FAKE_REMOTE_LATEST_STATE="$remote_latest_state" \
    FAKE_ADVANCE_REMOTE_ON_PREVIEW="$remote_latest_state" \
    assert_status "publish rejects a newer remote release created during confirmation" 1 \
      run_publish_with_input "PUBLISH v1.0.7" "$fixture_dir/scripts/release.sh" 1.0.7

  assert_eq "remote release race creates no local commit" "initial" "$(command git -C "$fixture_dir" log -1 --pretty=%s)"
  assert_file_count "remote release race never pushes" 0 "push --atomic" "$command_log"
  assert_file_count "remote release race never creates a GitHub Release" 0 "gh release create" "$command_log"

  rm -rf -- "$fixture_dir"
}

test_publish_rejects_verification_evidence_tamper() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-evidence-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"
  local release_state="$fixture_dir/.release/github-release-state"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "evidence fixture prepares successfully" 0 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7

  print -r -- tampered >> "$fixture_dir/.release/1.0.7/verification.log"
  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "publish rejects changed verification evidence" 1 \
      run_publish_with_input "PUBLISH v1.0.7" "$fixture_dir/scripts/release.sh" 1.0.7

  assert_eq "evidence tamper creates no release commit" "initial" "$(command git -C "$fixture_dir" log -1 --pretty=%s)"
  assert_file_count "evidence tamper never pushes" 0 "push --atomic" "$command_log"
  assert_file_count "evidence tamper never creates a release" 0 "gh release create" "$command_log"

  rm -rf -- "$fixture_dir"
}

test_publish_rejects_commit_hook_tamper_before_push() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-hook-test.XXXXXX") || return 1
  make_release_fixture "$fixture_dir" 1.0.7
  local command_log="$fixture_dir/.release/commands.log"
  local release_state="$fixture_dir/.release/github-release-state"

  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "hook fixture prepares successfully" 0 \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7

  print -r -- $'#!/bin/zsh\nprint -r -- "hook mutation" >> .gitignore\n/usr/bin/git add .gitignore' > "$fixture_dir/.git/hooks/pre-commit"
  chmod +x "$fixture_dir/.git/hooks/pre-commit"
  PATH="$fixture_dir/bin:$PATH" \
    FAKE_COMMAND_LOG="$command_log" \
    FAKE_MOUNT_POINT="$fixture_dir/fake-mount" \
    FAKE_GH_RELEASE_STATE="$release_state" \
    assert_status "publish rejects commit content changed by a hook" 1 \
      run_publish_with_input "PUBLISH v1.0.7" "$fixture_dir/scripts/release.sh" 1.0.7

  assert_eq "hook tamper creates no target tag" "" "$(command git -C "$fixture_dir" tag --list v1.0.7)"
  assert_file_count "hook tamper is detected before push" 0 "push --atomic" "$command_log"
  assert_file_count "hook tamper creates no GitHub Release" 0 "gh release create" "$command_log"

  rm -rf -- "$fixture_dir"
}

test_sparkle_failures_stop_prepare() {
  local scenario fixture_dir command_log
  for scenario in missing-key wrong-key generation signature; do
    fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-sparkle-test.XXXXXX") || return 1
    make_release_fixture "$fixture_dir" 1.0.7
    command_log="$fixture_dir/.release/commands.log"
    local -a failure_environment
    case "$scenario" in
      missing-key) failure_environment=(FAKE_SPARKLE_MISSING_KEY=1) ;;
      wrong-key) failure_environment=(FAKE_SPARKLE_PUBLIC_KEY=wrong-key) ;;
      generation) failure_environment=(FAKE_SPARKLE_GENERATION_FAIL=1) ;;
      signature) failure_environment=(FAKE_SPARKLE_VERIFY_FAIL=1) ;;
    esac
    assert_status "Sparkle $scenario failure blocks prepare" 1 \
      env PATH="$fixture_dir/bin:$PATH" FAKE_COMMAND_LOG="$command_log" \
      FAKE_MOUNT_POINT="$fixture_dir/fake-mount" "${failure_environment[@]}" \
      zsh "$fixture_dir/scripts/release.sh" prepare 1.0.7
    assert_status "Sparkle $scenario failure creates no manifest" 1 test -f "$fixture_dir/.release/1.0.7/release.manifest"
    assert_file_count "Sparkle $scenario failure preserves project versions" 2 "MARKETING_VERSION = 1.0.6;" "$fixture_dir/Brewery.xcodeproj/project.pbxproj"
    if [[ "$scenario" == *key ]]; then
      assert_file_count "Sparkle $scenario stops before archive" 0 "xcodebuild archive" "$command_log"
    fi
    rm -rf -- "$fixture_dir"
  done
}

test_sparkle_feed_and_asset_validation() {
  local fixture_dir
  fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/brewery-release-feed-test.XXXXXX") || return 1
  local dmg="$fixture_dir/Brewery-1.0.7.dmg" feed="$fixture_dir/appcast.xml" readback="$fixture_dir/assets.json"
  print -rn -- fixture > "$dmg"
  local signature=$(printf '%086d==' 0)
  print -r -- "<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><sparkle:version>2</sparkle:version><sparkle:shortVersionString>1.0.7</sparkle:shortVersionString><enclosure url=\"https://github.com/yyytir777/Brewery/releases/download/v1.0.7/Brewery-1.0.7.dmg\" length=\"7\" sparkle:edSignature=\"$signature\" /></item></channel></rss>" > "$feed"
  assert_status "appcast metadata matches versioned artifact" 0 assert_sparkle_appcast "$feed" "$dmg" 1.0.7 2 yyytir777/Brewery
  assert_status "appcast rejects wrong version" 1 assert_sparkle_appcast "$feed" "$dmg" 1.0.8 2 yyytir777/Brewery
  assert_status "appcast rejects wrong build" 1 assert_sparkle_appcast "$feed" "$dmg" 1.0.7 3 yyytir777/Brewery
  print -rn -- extra >> "$dmg"
  assert_status "appcast rejects changed archive size" 1 assert_sparkle_appcast "$feed" "$dmg" 1.0.7 2 yyytir777/Brewery
  print -r -- '{"assets":[{"name":"appcast.xml","size":10,"digest":"sha256:feed"},{"name":"Brewery-1.0.7.dmg","size":7,"digest":"sha256:dmg"}]}' > "$readback"
  assert_status "release readback accepts both assets in either order" 0 verify_release_assets "$readback" Brewery-1.0.7.dmg 7 dmg 10 feed
  assert_status "release readback rejects wrong appcast digest" 1 verify_release_assets "$readback" Brewery-1.0.7.dmg 7 dmg 10 wrong
  assert_status "release readback rejects wrong appcast size" 1 verify_release_assets "$readback" Brewery-1.0.7.dmg 7 dmg 11 feed
  plutil -remove assets.0 "$readback"
  assert_status "release readback rejects missing appcast" 1 verify_release_assets "$readback" Brewery-1.0.7.dmg 7 dmg 10 feed
  rm -rf -- "$fixture_dir"
}

test_sparkle_feed_and_asset_validation
test_sparkle_failures_stop_prepare
test_version_helpers
test_project_and_readme_helpers
test_notes_checksum_and_manifest_helpers
test_prepare_preflight_helpers
test_release_cli_argument_validation
test_remote_absence_checks_fail_closed
test_prepare_artifact_workflow
test_notary_rejection_stops_prepare
test_prepare_rejects_leftover_artifacts
test_prepare_rejects_stale_local_tags
test_publish_confirmation_and_integrity
test_publish_cancellation_and_tamper_detection
test_publish_revalidates_after_confirmation
test_publish_rejects_newer_remote_release_after_confirmation
test_publish_rejects_verification_evidence_tamper
test_publish_rejects_commit_hook_tamper_before_push
test_publish_fails_closed_when_digest_readback_fails

print -r -- "$TESTS_RUN tests, $TESTS_FAILED failures"
exit $(( TESTS_FAILED == 0 ? 0 : 1 ))
