#!/bin/bash
# Record one video per R3 motion test, so every transition has a labelled clip.
set -u
cd "$(dirname "$0")/../.." || exit 1
IOS=ios
SIM="${SIM:-7C728EE6-A05D-492A-A367-A98B4BF888AA}"
DD=/tmp/com-r3-main
V=verification

record_one() { # $1 = bundle/class, $2 = test name, $3 = out dir, $4 = out name
    local only="$1/$2" outdir="$3" name="$4"
    mkdir -p "$outdir"
    xcrun simctl io "$SIM" recordVideo --codec h264 "$outdir/$name.mp4" >/dev/null 2>&1 &
    local rec=$!
    sleep 2
    (cd "$IOS" && xcodebuild test -project Com.xcodeproj -scheme Com \
        -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DD" \
        -only-testing:"$only" 2>&1) | grep -E "Test Case|Executed|TEST " | tail -3
    kill -INT "$rec" 2>/dev/null
    wait "$rec" 2>/dev/null
    sleep 1
    echo "  -> $outdir/$name.mp4 ($(du -h "$outdir/$name.mp4" 2>/dev/null | cut -f1))"
}

for t in testRecTabs testRecStates testRecBubble testRecMenuAndStage testRecWorkSidebar testRecTodayPush testRecHomeSend; do
    echo "=== work/$t"
    record_one ComUITests/R3WorkUITests "$t" "$V/oct10-r3-work" "rec-${t#testRec}"
done

for t in testR3EvidencePocketMotion testR3TodoCheckMotion testR3DialStackMotion testR3DenseDialAndTimeline testR3TodoCheckUndoAndDetail; do
    echo "=== pages/$t"
    record_one ComUITests/R3PagesUITests "$t" "$V/oct10-r3-pages" "rec-${t#testR3}"
done
