#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
source "$SCRIPT_DIR/release_lib.sh"

readonly REPOSITORY_ROOT=${SCRIPT_DIR:h}
readonly PROJECT_PATH="$REPOSITORY_ROOT/Brewery.xcodeproj"
readonly PROJECT_FILE="$PROJECT_PATH/project.pbxproj"
readonly README_FILE="$REPOSITORY_ROOT/README.md"
readonly EXPECTED_BRANCH=main
readonly EXPECTED_ORIGIN=https://github.com/yyytir777/Brewery.git
readonly GITHUB_REPOSITORY=yyytir777/Brewery
readonly TEAM_ID=Y65C87UHRQ
readonly NOTARY_PROFILE=brewery-notary
readonly SPARKLE_ACCOUNT=brewery-sparkle

fail() {
  print -u2 -r -- "ERROR: $1"
  return 1
}

usage() {
  print -u2 -r -- "Usage: scripts/release.sh <prepare|publish> <VERSION>"
}

main() {
  if (( $# != 2 )); then
    usage
    return 64
  fi

  local mode=$1
  local version=$2
  if [[ "$mode" != prepare && "$mode" != publish ]]; then
    usage
    return 64
  fi
  if ! validate_version "$version"; then
    print -u2 -r -- "Invalid version: $version (expected X.Y.Z)"
    return 64
  fi

  case "$mode" in
    prepare)
      prepare_release "$version"
      ;;
    publish)
      publish_release "$version"
      ;;
  esac
}

prepare_release() {
  local version=$1
  local tag="v$version"
  local artifact_dir="$REPOSITORY_ROOT/.release/$version"
  local notes_file="$artifact_dir/release-notes.md"
  local archive_path="$artifact_dir/Brewery-$version.xcarchive"
  local export_dir="$artifact_dir/export"
  local export_options="$artifact_dir/ExportOptions.plist"
  local dmg_source="$artifact_dir/dmg-source"
  local dmg_path="$artifact_dir/Brewery-$version.dmg"
  local appcast_path="$artifact_dir/appcast.xml"
  local submit_json="$artifact_dir/notary-submit.json"
  local wait_json="$artifact_dir/notary-wait.json"
  local notary_log="$artifact_dir/notary-log.json"
  local attach_plist="$artifact_dir/hdiutil-attach.plist"
  local verification_log="$artifact_dir/verification.log"
  local manifest_file="$artifact_dir/release.manifest"
  local original_project="$artifact_dir/original-project.pbxproj"
  local original_readme="$artifact_dir/original-README.md"
  local prepared_project="$artifact_dir/prepared-project.pbxproj"
  local prepared_readme="$artifact_dir/prepared-README.md"

  require_commands git gh security xcodebuild xcrun codesign spctl hdiutil create-dmg plutil shasum perl awk grep sed ditto stat find mktemp cp tee date uname xmllint || return 1
  [[ "$(uname -s)" == Darwin ]] || fail "macOS is required for Developer ID release preparation" || return 1
  assert_git_repository "$REPOSITORY_ROOT" "$EXPECTED_BRANCH" "$EXPECTED_ORIGIN" || fail "Release must run from clean main with origin $EXPECTED_ORIGIN" || return 1
  assert_clean_worktree "$REPOSITORY_ROOT" || fail "Working tree must be clean before prepare" || return 1
  assert_release_notes "$notes_file" || fail "Missing or invalid release notes: $notes_file" || return 1
  assert_artifact_dir_ready "$artifact_dir" "$notes_file" || fail "Artifact directory must contain only release-notes.md before prepare: $artifact_dir" || return 1
  assert_target_version "$REPOSITORY_ROOT" "$version" || fail "Version $version must be newer than the latest release tag" || return 1

  [[ -z "$(git -C "$REPOSITORY_ROOT" tag --list "$tag")" ]] || fail "Local tag already exists: $tag" || return 1

  gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication is invalid; run gh auth login -h github.com" || return 1
  local local_latest_tag remote_latest_tag
  local_latest_tag=$(latest_version_tag "$REPOSITORY_ROOT") || fail "Could not determine the latest local semantic tag" || return 1
  remote_latest_tag=$(latest_remote_version_tag "$REPOSITORY_ROOT") || fail "Could not determine the latest remote semantic tag" || return 1
  [[ "$local_latest_tag" == "$remote_latest_tag" ]] || fail "Local tags are stale (local $local_latest_tag, remote $remote_latest_tag); run git fetch --tags and retry" || return 1
  version_gt "$version" "${remote_latest_tag#v}" || fail "Version $version must be newer than remote release tag $remote_latest_tag" || return 1
  local remote_check=0
  assert_remote_tag_absent "$REPOSITORY_ROOT" "$tag" || remote_check=$?
  (( remote_check == 0 )) || fail "Could not prove remote tag is absent" || return 1
  remote_check=0
  assert_github_release_absent "$GITHUB_REPOSITORY" "$tag" || remote_check=$?
  (( remote_check == 0 )) || fail "Could not prove GitHub Release is absent" || return 1

  local signing_identity
  signing_identity=$(find_developer_id_identity "$TEAM_ID") || fail "No Developer ID Application identity found for team $TEAM_ID" || return 1
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1 || fail "Notary Keychain profile '$NOTARY_PROFILE' is missing or invalid" || return 1

  local current_version build_number base_tag source_head original_project_sha256 original_readme_sha256
  current_version=$(read_single_build_setting "$PROJECT_FILE" MARKETING_VERSION) || fail "Could not read a consistent MARKETING_VERSION" || return 1
  version_gt "$version" "$current_version" || fail "Version $version must be newer than project version $current_version" || return 1
  build_number=$(next_build_number "$PROJECT_FILE") || fail "Could not calculate the next build number" || return 1
  base_tag=$(latest_version_tag "$REPOSITORY_ROOT") || return 1
  source_head=$(git -C "$REPOSITORY_ROOT" rev-parse HEAD) || return 1
  original_project_sha256=$(sha256_file "$PROJECT_FILE") || return 1
  original_readme_sha256=$(sha256_file "$README_FILE") || return 1

  mkdir -p -- "$artifact_dir"
  write_export_options "$export_options" "$TEAM_ID" || fail "Could not write ExportOptions.plist" || return 1
  cp -- "$PROJECT_FILE" "$original_project" || fail "Could not preserve the original project file" || return 1
  cp -- "$README_FILE" "$original_readme" || fail "Could not preserve the original README" || return 1
  cp -- "$PROJECT_FILE" "$prepared_project" || return 1
  cp -- "$README_FILE" "$prepared_readme" || return 1
  update_project_versions "$prepared_project" "$version" "$build_number" || fail "Could not pre-render project versions" || return 1
  update_readme_changelog "$prepared_readme" "$notes_file" "$version" || fail "Could not pre-render README Changelog" || return 1

  # Resolve tooling and validate the existing signing key before the expensive archive.
  xcodebuild -resolvePackageDependencies -project "$PROJECT_PATH" -scheme Brewery \
    -derivedDataPath "$artifact_dir/DerivedData" 2>&1 | tee "$artifact_dir/resolve-packages.log" || return 1
  local sparkle_bin="$artifact_dir/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
  [[ -x "$sparkle_bin/generate_keys" && -x "$sparkle_bin/generate_appcast" && -x "$sparkle_bin/sign_update" ]] || fail "Sparkle release tools missing from $sparkle_bin" || return 1
  assert_sparkle_public_key "$sparkle_bin/generate_keys" "$REPOSITORY_ROOT/Configuration/Brewery-Info.plist" "$SPARKLE_ACCOUNT" || fail "Sparkle Keychain signing key is missing or differs from the source public key" || return 1

  print -r -- "Archiving Brewery $version (build $build_number)..."
  xcodebuild archive \
    -project "$PROJECT_PATH" \
    -scheme Brewery \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    -derivedDataPath "$artifact_dir/DerivedData" \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    2>&1 | tee "$artifact_dir/archive.log" || return 1

  xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options" \
    2>&1 | tee "$artifact_dir/export.log" || return 1

  local exported_app="$export_dir/Brewery.app"
  [[ -d "$exported_app" ]] || fail "Export did not produce Brewery.app" || return 1
  codesign --verify --deep --strict --verbose=2 "$exported_app" || return 1
  assert_sparkle_public_key "$sparkle_bin/generate_keys" "$exported_app/Contents/Info.plist" "$SPARKLE_ACCOUNT" || fail "Sparkle Keychain signing key is missing or differs from the app public key" || return 1

  mkdir -p -- "$dmg_source"
  ditto "$exported_app" "$dmg_source/Brewery.app" || return 1
  [[ "$(find "$dmg_source" -mindepth 1 -maxdepth 1 -print)" == "$dmg_source/Brewery.app" ]] || fail "DMG source contains unexpected entries" || return 1
  create-dmg \
    --volname Brewery \
    --window-size 600 400 \
    --icon-size 128 \
    --icon Brewery.app 150 200 \
    --app-drop-link 450 200 \
    --codesign "$signing_identity" \
    "$dmg_path" \
    "$dmg_source" || return 1

  [[ -f "$dmg_path" ]] || fail "create-dmg did not produce $dmg_path" || return 1
  codesign --verify --verbose=2 "$dmg_path" || return 1

  local submit_exit=0 wait_exit=0
  xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json > "$submit_json" || submit_exit=$?

  local notary_status notary_id
  notary_id=$(json_field "$submit_json" id) || fail "Could not read notarization submission ID (submit exit $submit_exit)" || return 1
  (( submit_exit == 0 )) || fail "Notarization upload failed after creating submission $notary_id" || return 1

  xcrun notarytool wait "$notary_id" \
    --keychain-profile "$NOTARY_PROFILE" \
    --timeout 30m \
    --output-format json > "$wait_json" || wait_exit=$?
  notary_status=$(json_field "$wait_json" status) || {
    print -u2 -r -- "Notarization wait ended without a readable status. Submission: $notary_id (exit $wait_exit)"
    print -u2 -r -- "Inspect: xcrun notarytool info $notary_id --keychain-profile $NOTARY_PROFILE"
    print -u2 -r -- "Log after completion: xcrun notarytool log $notary_id '$notary_log' --keychain-profile $NOTARY_PROFILE"
    return 1
  }
  if [[ "$notary_status" != Accepted && "$notary_status" != Invalid ]]; then
    print -u2 -r -- "Notarization is not terminal: $notary_status. Submission: $notary_id (wait exit $wait_exit)"
    print -u2 -r -- "Inspect: xcrun notarytool info $notary_id --keychain-profile $NOTARY_PROFILE"
    print -u2 -r -- "Log after completion: xcrun notarytool log $notary_id '$notary_log' --keychain-profile $NOTARY_PROFILE"
    return 1
  fi
  xcrun notarytool log "$notary_id" "$notary_log" --keychain-profile "$NOTARY_PROFILE" || {
    print -u2 -r -- "Could not download the notarization log. Submission: $notary_id ($notary_status)"
    print -u2 -r -- "Inspect: xcrun notarytool info $notary_id --keychain-profile $NOTARY_PROFILE"
    return 1
  }
  if [[ "$notary_status" != Accepted ]]; then
    fail "Notarization returned $notary_status; inspect $notary_log"
    print -u2 -r -- "Inspect: xcrun notarytool info $notary_id --keychain-profile $NOTARY_PROFILE"
    return 1
  fi
  (( wait_exit == 0 )) || fail "notarytool wait exited $wait_exit despite Accepted status" || return 1
  if grep -Eiq '"severity"[[:space:]]*:[[:space:]]*"warning"' "$notary_log"; then
    print -u2 -r -- "WARNING: Apple accepted the submission with warnings; inspect $notary_log"
  fi

  xcrun stapler staple "$dmg_path" || return 1
  xcrun stapler validate "$dmg_path" || return 1
  hdiutil verify "$dmg_path" || return 1

  local attach_device="" mount_point=""
  {
    hdiutil attach -readonly -nobrowse -plist "$dmg_path" > "$attach_plist" || return 1
    attach_device=$(attach_device_from_plist "$attach_plist") || fail "Could not identify the attached DMG device" || return 1
    mount_point=$(attach_mount_point_from_plist "$attach_plist") || fail "Could not identify the mounted DMG volume" || return 1
    [[ -n "$mount_point" && -d "$mount_point/Brewery.app" ]] || fail "Mounted DMG does not contain Brewery.app" || return 1
    codesign --verify --deep --strict --verbose=2 "$mount_point/Brewery.app" || return 1
    spctl --assess --type execute --verbose=4 "$mount_point/Brewery.app" || return 1
  } always {
    if [[ -n "$attach_device" ]]; then
      hdiutil detach "$attach_device" || return 1
    fi
  }
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path" || return 1

  # Sign only the final stapled bytes. A fresh folder prevents stale releases/deltas.
  local feed_source="$artifact_dir/appcast-source"
  mkdir -p -- "$feed_source" || return 1
  cp -- "$dmg_path" "$feed_source/Brewery-$version.dmg" || return 1
  cp -- "$notes_file" "$feed_source/Brewery-$version.md" || return 1
  "$sparkle_bin/generate_appcast" --maximum-deltas 0 --embed-release-notes --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$tag/" \
    "$feed_source" 2>&1 | tee "$artifact_dir/appcast.log" || return 1
  cp -- "$feed_source/appcast.xml" "$appcast_path" || return 1
  assert_sparkle_appcast "$appcast_path" "$dmg_path" "$version" "$build_number" "$GITHUB_REPOSITORY" || fail "Generated Sparkle appcast does not match the prepared release" || return 1

  local update_signature
  update_signature=$(xmllint --xpath "string(/rss/channel/item/enclosure/@*[local-name()='edSignature'])" "$appcast_path") || return 1
  "$sparkle_bin/sign_update" --verify --account "$SPARKLE_ACCOUNT" "$dmg_path" "$update_signature" || fail "Sparkle signature does not verify the final DMG" || return 1

  print -r -l -- \
    "Sparkle signed appcast: passed" \
    "codesign app: passed" \
    "codesign dmg: passed" \
    "notarytool: Accepted ($notary_id)" \
    "stapler validate: passed" \
    "hdiutil verify: passed" \
    "mounted app codesign: passed" \
    "mounted app Gatekeeper: passed" \
    "DMG Gatekeeper: passed" > "$verification_log" || return 1

  local dmg_sha256 dmg_size notes_sha256 prepared_at
  dmg_sha256=$(sha256_file "$dmg_path") || return 1
  dmg_size=$(stat -f %z "$dmg_path") || return 1
  notes_sha256=$(sha256_file "$notes_file") || return 1
  prepared_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1

  [[ "$(sha256_file "$PROJECT_FILE")" == "$original_project_sha256" ]] || fail "Project file changed while prepare was running" || return 1
  [[ "$(sha256_file "$README_FILE")" == "$original_readme_sha256" ]] || fail "README changed while prepare was running" || return 1

  local project_sha256 readme_sha256 submit_sha256 wait_sha256 notary_log_sha256 verification_sha256
  project_sha256=$(sha256_file "$prepared_project") || return 1
  readme_sha256=$(sha256_file "$prepared_readme") || return 1
  submit_sha256=$(sha256_file "$submit_json") || return 1
  wait_sha256=$(sha256_file "$wait_json") || return 1
  notary_log_sha256=$(sha256_file "$notary_log") || return 1
  verification_sha256=$(sha256_file "$verification_log") || return 1
  local metadata_committed=0
  {
    atomic_install_file "$prepared_project" "$PROJECT_FILE" || fail "Could not atomically apply prepared project versions" || return 1
    atomic_install_file "$prepared_readme" "$README_FILE" || fail "Could not atomically apply prepared README" || return 1
    [[ "$(sha256_file "$PROJECT_FILE")" == "$project_sha256" ]] || fail "Applied project metadata hash mismatch" || return 1
    [[ "$(sha256_file "$README_FILE")" == "$readme_sha256" ]] || fail "Applied README hash mismatch" || return 1
    manifest_write "$manifest_file" \
      version "$version" \
      build_number "$build_number" \
      base_tag "$base_tag" \
      source_head "$source_head" \
      project_sha256 "$project_sha256" \
      readme_sha256 "$readme_sha256" \
      notes_sha256 "$notes_sha256" \
      dmg_sha256 "$dmg_sha256" \
      dmg_size "$dmg_size" \
      appcast_sha256 "$(sha256_file "$appcast_path")" \
      appcast_size "$(stat -f %z "$appcast_path")" \
      notary_status "$notary_status" \
      notary_id "$notary_id" \
      submit_sha256 "$submit_sha256" \
      wait_sha256 "$wait_sha256" \
      notary_log_sha256 "$notary_log_sha256" \
      verification_sha256 "$verification_sha256" \
      prepared_at_utc "$prepared_at" || return 1
    metadata_committed=1
  } always {
    if (( metadata_committed == 0 )); then
      atomic_install_file "$original_project" "$PROJECT_FILE" || print -u2 -r -- "CRITICAL: could not restore the original project file"
      atomic_install_file "$original_readme" "$README_FILE" || print -u2 -r -- "CRITICAL: could not restore the original README"
    fi
  }

  print -r -- ""
  print -r -- "Prepared Release : $tag"
  print -r -- "Source: $source_head (after $base_tag)"
  print -r -- "Version: $version"
  print -r -- "Build: $build_number"
  print -r -- "Prepared: $prepared_at"
  print -r -- "Notarization: $notary_status ($notary_id)"
  print -r -- "DMG: $dmg_path"
  print -r -- "Size: $dmg_size bytes"
  print -r -- "SHA-256: $dmg_sha256"
  print -r -- "Appcast: $appcast_path ($(stat -f %z "$appcast_path") bytes)"
  print -r -- "Appcast SHA-256: $(sha256_file "$appcast_path")"
  print -r -- "Verification:"
  sed 's/^/  /' "$verification_log"
  print -r -- ""
  render_release_body "$notes_file"
  print -r -- ""
  git -C "$REPOSITORY_ROOT" diff -- Brewery.xcodeproj/project.pbxproj README.md
  print -r -- "Proposed publish commands:"
  print -r -- "  git commit -m 'chore: release $tag'"
  print -r -- "  git tag -a '$tag' -m 'Release $tag'"
  print -r -- "  git push --atomic origin main 'refs/tags/$tag'"
  print -r -- "  gh release create '$tag' 'Brewery-$version.dmg' 'appcast.xml' --title 'Release : $tag' --notes-file release-notes.md --verify-tag"
  print -r -- "Prepared only; nothing was committed, tagged, pushed, or published."
}

release_field() {
  local tag=$1
  local field=$2
  gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json "$field" --jq ".$field"
}

published_verification_failure() {
  local tag=$1
  local reason=$2
  print -u2 -r -- "GitHub Release $tag was created, but read-back verification failed: $reason"
  print -u2 -r -- "Recheck safely: gh release view '$tag' --repo '$GITHUB_REPOSITORY' --json tagName,name,body,isDraft,isPrerelease,assets,url"
  return 1
}

validate_prepared_local_state() {
  local version=$1
  local manifest_file=$2
  local notes_file=$3
  local dmg_path=$4
  local artifact_dir=${manifest_file:h}
  local manifest_head manifest_project_hash manifest_readme_hash manifest_notes_hash
  local manifest_dmg_hash manifest_dmg_size manifest_submit_hash manifest_wait_hash manifest_notary_log_hash manifest_verification_hash

  manifest_head=$(manifest_read "$manifest_file" source_head) || return 1
  manifest_project_hash=$(manifest_read "$manifest_file" project_sha256) || return 1
  manifest_readme_hash=$(manifest_read "$manifest_file" readme_sha256) || return 1
  manifest_notes_hash=$(manifest_read "$manifest_file" notes_sha256) || return 1
  manifest_dmg_hash=$(manifest_read "$manifest_file" dmg_sha256) || return 1
  manifest_dmg_size=$(manifest_read "$manifest_file" dmg_size) || return 1
  manifest_submit_hash=$(manifest_read "$manifest_file" submit_sha256) || return 1
  manifest_wait_hash=$(manifest_read "$manifest_file" wait_sha256) || return 1
  manifest_notary_log_hash=$(manifest_read "$manifest_file" notary_log_sha256) || return 1
  manifest_verification_hash=$(manifest_read "$manifest_file" verification_sha256) || return 1

  assert_git_repository "$REPOSITORY_ROOT" "$EXPECTED_BRANCH" "$EXPECTED_ORIGIN" || fail "Repository branch or origin changed after prepare" || return 1
  [[ "$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)" == "$manifest_head" ]] || fail "Source HEAD changed after prepare" || return 1
  [[ "$(sha256_file "$PROJECT_FILE")" == "$manifest_project_hash" ]] || fail "Project file changed after prepare" || return 1
  [[ "$(sha256_file "$README_FILE")" == "$manifest_readme_hash" ]] || fail "README changed after prepare" || return 1
  [[ "$(sha256_file "$notes_file")" == "$manifest_notes_hash" ]] || fail "Release notes changed after prepare" || return 1
  [[ "$(sha256_file "$dmg_path")" == "$manifest_dmg_hash" ]] || fail "DMG changed after prepare" || return 1
  [[ "$(stat -f %z "$dmg_path")" == "$manifest_dmg_size" ]] || fail "DMG size changed after prepare" || return 1
  [[ "$(sha256_file "$artifact_dir/appcast.xml")" == "$(manifest_read "$manifest_file" appcast_sha256)" ]] || fail "Appcast changed after prepare" || return 1
  [[ "$(stat -f %z "$artifact_dir/appcast.xml")" == "$(manifest_read "$manifest_file" appcast_size)" ]] || fail "Appcast size changed after prepare" || return 1
  [[ "$(sha256_file "$artifact_dir/notary-submit.json")" == "$manifest_submit_hash" ]] || fail "Notary submission evidence changed after prepare" || return 1
  [[ "$(sha256_file "$artifact_dir/notary-wait.json")" == "$manifest_wait_hash" ]] || fail "Notary wait evidence changed after prepare" || return 1
  [[ "$(sha256_file "$artifact_dir/notary-log.json")" == "$manifest_notary_log_hash" ]] || fail "Notary log changed after prepare" || return 1
  [[ "$(sha256_file "$artifact_dir/verification.log")" == "$manifest_verification_hash" ]] || fail "Verification evidence changed after prepare" || return 1
  assert_only_release_changes "$REPOSITORY_ROOT" || fail "Only the prepared project and README changes may be present" || return 1
}

publish_release() {
  local version=$1
  local tag="v$version"
  local artifact_dir="$REPOSITORY_ROOT/.release/$version"
  local notes_file="$artifact_dir/release-notes.md"
  local dmg_path="$artifact_dir/Brewery-$version.dmg"
  local appcast_path="$artifact_dir/appcast.xml"
  local manifest_file="$artifact_dir/release.manifest"

  require_commands git gh shasum stat awk || return 1
  assert_git_repository "$REPOSITORY_ROOT" "$EXPECTED_BRANCH" "$EXPECTED_ORIGIN" || fail "Publish must run from main with origin $EXPECTED_ORIGIN" || return 1
  [[ -f "$manifest_file" ]] || fail "Missing preparation manifest: $manifest_file" || return 1
  manifest_assert_schema "$manifest_file" \
    version build_number base_tag source_head project_sha256 readme_sha256 notes_sha256 \
    dmg_sha256 dmg_size appcast_sha256 appcast_size notary_status notary_id submit_sha256 wait_sha256 notary_log_sha256 \
    verification_sha256 prepared_at_utc || fail "Release manifest schema is invalid" || return 1
  assert_release_notes "$notes_file" || fail "Release notes changed or are invalid" || return 1
  [[ -f "$dmg_path" ]] || fail "Missing prepared DMG: $dmg_path" || return 1

  local manifest_version manifest_build manifest_base_tag manifest_prepared_at manifest_head manifest_project_hash manifest_readme_hash
  local manifest_notes_hash manifest_dmg_hash manifest_dmg_size manifest_status manifest_id
  manifest_version=$(manifest_read "$manifest_file" version) || fail "Manifest version is missing or duplicated" || return 1
  manifest_build=$(manifest_read "$manifest_file" build_number) || return 1
  manifest_base_tag=$(manifest_read "$manifest_file" base_tag) || return 1
  manifest_prepared_at=$(manifest_read "$manifest_file" prepared_at_utc) || return 1
  manifest_head=$(manifest_read "$manifest_file" source_head) || fail "Manifest source_head is missing or duplicated" || return 1
  manifest_project_hash=$(manifest_read "$manifest_file" project_sha256) || return 1
  manifest_readme_hash=$(manifest_read "$manifest_file" readme_sha256) || return 1
  manifest_notes_hash=$(manifest_read "$manifest_file" notes_sha256) || return 1
  manifest_dmg_hash=$(manifest_read "$manifest_file" dmg_sha256) || return 1
  manifest_dmg_size=$(manifest_read "$manifest_file" dmg_size) || return 1
  local manifest_appcast_hash manifest_appcast_size
  manifest_appcast_hash=$(manifest_read "$manifest_file" appcast_sha256) || return 1
  manifest_appcast_size=$(manifest_read "$manifest_file" appcast_size) || return 1
  manifest_status=$(manifest_read "$manifest_file" notary_status) || return 1
  manifest_id=$(manifest_read "$manifest_file" notary_id) || return 1

  [[ "$manifest_version" == "$version" ]] || fail "Manifest version does not match $version" || return 1
  [[ "$manifest_build" == <-> ]] || fail "Manifest build number is invalid" || return 1
  validate_version "${manifest_base_tag#v}" || fail "Manifest base tag is invalid" || return 1
  [[ "$manifest_base_tag" == v* ]] || fail "Manifest base tag is invalid" || return 1
  [[ "$manifest_prepared_at" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ]] || fail "Manifest preparation timestamp is invalid" || return 1
  [[ "$manifest_id" =~ '^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$' ]] || fail "Manifest notarization ID is invalid" || return 1
  [[ "$manifest_status" == Accepted ]] || fail "Manifest notarization status is not Accepted" || return 1
  [[ "$(read_single_build_setting "$PROJECT_FILE" MARKETING_VERSION)" == "$version" ]] || fail "Project marketing version differs from manifest" || return 1
  [[ "$(read_single_build_setting "$PROJECT_FILE" CURRENT_PROJECT_VERSION)" == "$manifest_build" ]] || fail "Project build number differs from manifest" || return 1
  [[ "$(json_field "$artifact_dir/notary-submit.json" id)" == "$manifest_id" ]] || fail "Notary submission ID differs from manifest" || return 1
  [[ "$(json_field "$artifact_dir/notary-wait.json" id)" == "$manifest_id" ]] || fail "Notary wait ID differs from manifest" || return 1
  [[ "$(json_field "$artifact_dir/notary-wait.json" status)" == "$manifest_status" ]] || fail "Notary wait status differs from manifest" || return 1
  [[ "$(json_field "$artifact_dir/notary-log.json" jobId)" == "$manifest_id" ]] || fail "Notary log ID differs from manifest" || return 1
  validate_prepared_local_state "$version" "$manifest_file" "$notes_file" "$dmg_path" || return 1

  [[ -z "$(git -C "$REPOSITORY_ROOT" tag --list "$tag")" ]] || fail "Local tag already exists: $tag" || return 1
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI authentication is invalid" || return 1
  local remote_latest_tag
  remote_latest_tag=$(latest_remote_version_tag "$REPOSITORY_ROOT") || fail "Could not determine latest remote tag before publish" || return 1
  [[ "$remote_latest_tag" == "$manifest_base_tag" ]] || fail "Remote latest tag changed after prepare ($manifest_base_tag -> $remote_latest_tag)" || return 1
  local remote_check=0
  assert_remote_tag_absent "$REPOSITORY_ROOT" "$tag" || remote_check=$?
  (( remote_check == 0 )) || fail "Could not prove remote tag is absent" || return 1
  remote_check=0
  assert_github_release_absent "$GITHUB_REPOSITORY" "$tag" || remote_check=$?
  (( remote_check == 0 )) || fail "Could not prove GitHub Release is absent" || return 1

  print -r -- "Release : $tag"
  print -r -- "Source: $manifest_head (after $manifest_base_tag)"
  print -r -- "Build: $manifest_build"
  print -r -- "Prepared: $manifest_prepared_at"
  print -r -- "Notarization: Accepted ($manifest_id)"
  print -r -- "DMG: $dmg_path"
  print -r -- "Size: $manifest_dmg_size bytes"
  print -r -- "SHA-256: $manifest_dmg_hash"
  print -r -- "Appcast: $appcast_path ($manifest_appcast_size bytes)"
  print -r -- "Appcast SHA-256: $manifest_appcast_hash"
  print -r -- ""
  render_release_body "$notes_file"
  print -r -- ""
  git -C "$REPOSITORY_ROOT" diff -- Brewery.xcodeproj/project.pbxproj README.md
  print -r -- "Commands after confirmation:"
  print -r -- "  git commit -m 'chore: release $tag'"
  print -r -- "  git tag -a '$tag' -m 'Release $tag'"
  print -r -- "  git push --atomic origin main 'refs/tags/$tag'"
  print -r -- "  gh release create '$tag' 'Brewery-$version.dmg' 'appcast.xml' --title 'Release : $tag' --notes-file release-notes.md --verify-tag"
  print -n -- "Type PUBLISH $tag to continue: "

  local confirmation
  IFS= read -r confirmation || fail "Publish cancelled: no confirmation received" || return 1
  [[ "$confirmation" == "PUBLISH $tag" ]] || fail "Publish cancelled" || return 1

  validate_prepared_local_state "$version" "$manifest_file" "$notes_file" "$dmg_path" || return 1

  remote_latest_tag=$(latest_remote_version_tag "$REPOSITORY_ROOT") || fail "Could not determine latest remote tag after confirmation" || return 1
  [[ "$remote_latest_tag" == "$manifest_base_tag" ]] || fail "Remote latest tag changed while confirmation was pending ($manifest_base_tag -> $remote_latest_tag)" || return 1
  remote_check=0
  assert_remote_tag_absent "$REPOSITORY_ROOT" "$tag" || remote_check=$?
  (( remote_check == 0 )) || fail "Remote tag state changed while confirmation was pending" || return 1
  remote_check=0
  assert_github_release_absent "$GITHUB_REPOSITORY" "$tag" || remote_check=$?
  (( remote_check == 0 )) || fail "GitHub Release state changed while confirmation was pending" || return 1

  git -C "$REPOSITORY_ROOT" add -- Brewery.xcodeproj/project.pbxproj README.md || return 1
  local staged_files
  staged_files=$(git -C "$REPOSITORY_ROOT" diff --cached --name-only | LC_ALL=C sort) || return 1
  [[ "$staged_files" == $'Brewery.xcodeproj/project.pbxproj\nREADME.md' ]] || fail "Unexpected staged files; refusing to commit" || return 1
  git -C "$REPOSITORY_ROOT" diff --cached --quiet && fail "Prepared release has no staged changes" && return 1
  [[ "$(git -C "$REPOSITORY_ROOT" show :Brewery.xcodeproj/project.pbxproj | shasum -a 256 | awk '{ print $1 }')" == "$manifest_project_hash" ]] || fail "Staged project file differs from prepared state" || return 1
  [[ "$(git -C "$REPOSITORY_ROOT" show :README.md | shasum -a 256 | awk '{ print $1 }')" == "$manifest_readme_hash" ]] || fail "Staged README differs from prepared state" || return 1

  git -C "$REPOSITORY_ROOT" commit -m "chore: release $tag" || return 1
  local committed_files
  committed_files=$(git -C "$REPOSITORY_ROOT" diff-tree --no-commit-id --name-only -r HEAD | LC_ALL=C sort) || return 1
  if [[ "$(git -C "$REPOSITORY_ROOT" rev-parse HEAD^)" != "$manifest_head" || \
        "$committed_files" != $'Brewery.xcodeproj/project.pbxproj\nREADME.md' || \
        "$(git -C "$REPOSITORY_ROOT" show HEAD:Brewery.xcodeproj/project.pbxproj | shasum -a 256 | awk '{ print $1 }')" != "$manifest_project_hash" || \
        "$(git -C "$REPOSITORY_ROOT" show HEAD:README.md | shasum -a 256 | awk '{ print $1 }')" != "$manifest_readme_hash" ]]; then
    print -u2 -r -- "Release commit was created locally but its contents differ from the prepared manifest."
    print -u2 -r -- "No tag, push, or GitHub Release was created. Inspect HEAD before retrying."
    return 1
  fi
  [[ "$(git -C "$REPOSITORY_ROOT" branch --show-current)" == "$EXPECTED_BRANCH" ]] || fail "Branch changed after release commit" || return 1
  [[ "$(sha256_file "$notes_file")" == "$manifest_notes_hash" ]] || fail "Release notes changed before tag/push" || return 1
  [[ "$(sha256_file "$dmg_path")" == "$manifest_dmg_hash" ]] || fail "DMG changed before tag/push" || return 1

  [[ "$(sha256_file "$appcast_path")" == "$manifest_appcast_hash" ]] || fail "Appcast changed before tag/push" || return 1

  git -C "$REPOSITORY_ROOT" tag -a "$tag" -m "Release $tag" || return 1
  [[ "$(git -C "$REPOSITORY_ROOT" rev-parse "$tag^{commit}")" == "$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)" ]] || fail "Release tag does not point to the verified release commit" || return 1
  if ! git -C "$REPOSITORY_ROOT" push --atomic origin main "refs/tags/$tag"; then
    fail "Atomic push failed. The release commit and tag exist locally only."
    return 1
  fi

  if [[ "$(sha256_file "$notes_file")" != "$manifest_notes_hash" || "$(sha256_file "$dmg_path")" != "$manifest_dmg_hash" || "$(sha256_file "$appcast_path")" != "$manifest_appcast_hash" ]]; then
    print -u2 -r -- "Remote commit and tag were pushed, but release inputs changed before GitHub Release creation."
    print -u2 -r -- "GitHub Release was not created. Restore the files until all manifest checks succeed:"
    print -u2 -r -- "  test \"\$(shasum -a 256 '$notes_file' | awk '{ print \$1 }')\" = '$manifest_notes_hash'"
    print -u2 -r -- "  test \"\$(shasum -a 256 '$dmg_path' | awk '{ print \$1 }')\" = '$manifest_dmg_hash'"
    print -u2 -r -- "  test \"\$(shasum -a 256 '$appcast_path' | awk '{ print \$1 }')\" = '$manifest_appcast_hash'"
    print -u2 -r -- "Then create the missing Release:"
    print -u2 -r -- "  gh release create '$tag' '$dmg_path' '$appcast_path' --repo '$GITHUB_REPOSITORY' --title 'Release : $tag' --notes-file '$notes_file' --verify-tag"
    return 1
  fi

  if ! gh release create "$tag" "$dmg_path" "$appcast_path" \
    --repo "$GITHUB_REPOSITORY" \
    --title "Release : $tag" \
    --notes-file "$notes_file" \
    --verify-tag; then
    print -u2 -r -- "Remote commit and tag were pushed, but GitHub Release creation failed."
    print -u2 -r -- "Retry: gh release create $tag '$dmg_path' '$appcast_path' --repo $GITHUB_REPOSITORY --title 'Release : $tag' --notes-file '$notes_file' --verify-tag"
    return 1
  fi

  local readback_json="$artifact_dir/github-release-readback.json"
  if ! gh release view "$tag" --repo "$GITHUB_REPOSITORY" \
    --json tagName,name,body,isDraft,isPrerelease,assets,url > "$readback_json"; then
    published_verification_failure "$tag" "GitHub API/transport read failed"
    return 1
  fi

  local remote_tag remote_title remote_body remote_draft remote_prerelease
  local remote_url expected_body
  remote_tag=$(json_field "$readback_json" tagName) || published_verification_failure "$tag" "missing tagName" || return 1
  remote_title=$(json_field "$readback_json" name) || published_verification_failure "$tag" "missing name" || return 1
  remote_body=$(json_field "$readback_json" body) || published_verification_failure "$tag" "missing body" || return 1
  remote_draft=$(json_field "$readback_json" isDraft) || published_verification_failure "$tag" "missing draft state" || return 1
  remote_prerelease=$(json_field "$readback_json" isPrerelease) || published_verification_failure "$tag" "missing prerelease state" || return 1
  verify_release_assets "$readback_json" "Brewery-$version.dmg" "$manifest_dmg_size" "$manifest_dmg_hash" "$manifest_appcast_size" "$manifest_appcast_hash" || published_verification_failure "$tag" "release asset names, sizes, or digests differ from prepared files" || return 1
  remote_url=$(json_field "$readback_json" url) || published_verification_failure "$tag" "missing URL" || return 1
  expected_body=$(render_release_body "$notes_file") || return 1

  [[ "$remote_tag" == "$tag" ]] || published_verification_failure "$tag" "tag mismatch" || return 1
  [[ "$remote_title" == "Release : $tag" ]] || published_verification_failure "$tag" "title mismatch" || return 1
  [[ "$remote_body" == "$expected_body" ]] || published_verification_failure "$tag" "body mismatch" || return 1
  [[ "$remote_draft" == false && "$remote_prerelease" == false ]] || published_verification_failure "$tag" "draft/prerelease state mismatch" || return 1

  print -r -- "Published and verified: $remote_url"
}

main "$@"
