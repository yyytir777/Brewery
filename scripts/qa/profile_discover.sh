#!/bin/zsh
# Record an already-open Release Brewery window; this script never drives its UI.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  print -u2 'Usage: zsh scripts/qa/profile_discover.sh PID /absolute/new-recording.trace [seconds=45] [light|swiftui]'
  exit 2
fi
brewery_profile_pid=$1
brewery_profile_output=$2
brewery_profile_seconds=${3:-45}
brewery_profile_mode=${4:-light}
case "$brewery_profile_mode" in
  light) brewery_profile_instruments=(--template 'Time Profiler' --instrument Hitches --instrument os_signpost) ;;
  swiftui) brewery_profile_instruments=(--template SwiftUI --instrument os_signpost) ;;
  *) print -u2 'Recording mode must be light or swiftui.'; exit 2 ;;
esac
if [[ $brewery_profile_pid != <-> || $brewery_profile_seconds != <-> ]] || (( brewery_profile_seconds < 5 || brewery_profile_seconds > 60 )); then
  print -u2 'PID must be numeric; recording duration must be 5–60 seconds.'
  exit 2
fi
if [[ $brewery_profile_mode == swiftui ]] && (( brewery_profile_seconds > 15 )); then
  print -u2 'Use 5–15 seconds for SwiftUI graph captures; longer recordings can be expensive to finalize.'
  exit 2
fi
if [[ $brewery_profile_output != /*.trace || -e $brewery_profile_output ]]; then
  print -u2 'Choose a new absolute .trace output path.'
  exit 2
fi
brewery_profile_base=${brewery_profile_output%.trace}
for brewery_profile_suffix in -toc.xml -intervals.xml -hitches.xml; do
  if [[ -e ${brewery_profile_base}${brewery_profile_suffix} ]]; then
    print -u2 'An export path already exists; choose another recording name.'
    exit 2
  fi
done
brewery_profile_command=$(/bin/ps -p "$brewery_profile_pid" -o comm=)
if [[ $brewery_profile_command != */Brewery.app/Contents/MacOS/Brewery ]]; then
  print -u2 'The PID is not a Brewery app executable. Open the Release app first.'
  exit 2
fi

print 'During the recording, search in Discover using the native UI. Do not install or remove packages.'
/usr/bin/xcrun xctrace record "${brewery_profile_instruments[@]}" \
  --attach "$brewery_profile_pid" --time-limit "${brewery_profile_seconds}s" \
  --output "$brewery_profile_output" --no-prompt
/usr/bin/xcrun xctrace export --input "$brewery_profile_output" --toc --output "${brewery_profile_base}-toc.xml"
/usr/bin/xcrun xctrace export --input "$brewery_profile_output" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost-interval"]' \
  --output "${brewery_profile_base}-intervals.xml"
/usr/bin/xcrun xctrace export --input "$brewery_profile_output" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]' \
  --output "${brewery_profile_base}-hitches.xml"
print "Saved ${brewery_profile_output} and XML exports. Empty samples are not a passing latency measurement."
