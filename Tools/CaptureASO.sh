#!/bin/bash
# Explicitly targets a dedicated, already booted simulator with the Debug app installed.
# Usage: bash Tools/CaptureASO.sh <simulator-uuid> [split|pip|duet|stack|portrait]
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: bash Tools/CaptureASO.sh <dedicated-simulator-uuid> [screen]" >&2
    exit 1
fi
task_simulator="$1"
task_screens=(split pip duet stack portrait)
if [[ $# -eq 2 ]]; then
    case "$2" in
        split|pip|duet|stack|portrait) task_screens=("$2") ;;
        *) echo "Unknown screenshot route: $2" >&2; exit 1 ;;
    esac
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_base="$task_root/Metadata/ASO/2026-09"
task_data="$(xcrun simctl get_app_container "$task_simulator" com.flinter.splitcam data)"
task_documents="$task_data/Documents"
task_work="$(mktemp -d -t splitcam-aso-capture)"
task_validator="$task_work/check-frame"
swiftc -module-cache-path /private/tmp/splitcam-swift-cache "$task_root/Tools/ValidateASO.swift" -o "$task_validator"

xcrun simctl ui "$task_simulator" content_size large
xcrun simctl status_bar "$task_simulator" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100

for task_language in en zh-Hans; do
    for task_screen in "${task_screens[@]}"; do
        case "$task_screen" in
            split)
                task_front="$task_base/source/demo-front.png"
                task_back="$task_base/source/demo-back.png"
                ;;
            pip)
                task_front="$task_base/source/scenes/pip-front.png"
                task_back="$task_base/source/demo-back.png"
                ;;
            *)
                task_front="$task_base/source/scenes/$task_screen-front.png"
                task_back="$task_base/source/scenes/$task_screen-back.png"
                ;;
        esac
        # The debug preview route loads this pair at launch. UI is never painted over.
        xcrun simctl terminate "$task_simulator" com.flinter.splitcam 2>/dev/null || true
        cp "$task_front" "$task_documents/demo-front.png"
        cp "$task_back" "$task_documents/demo-back.png"
        xcrun simctl launch "$task_simulator" com.flinter.splitcam -preview-screen "$task_screen" -AppleLanguages "($task_language)" -settings.defaultVideoQuality standard
        # Wait for demo camera content, not merely a successful process launch.
        task_capture="$task_base/raw/$task_language/$task_screen.png"
        task_ready=0
        for task_attempt in 1 2 3 4 5; do
            sleep 2
            xcrun simctl io "$task_simulator" screenshot "$task_capture"
            if "$task_validator" --frame "$task_capture"; then
                task_ready=1
                break
            fi
        done
        if [[ "$task_ready" -ne 1 ]]; then
            echo "Camera preview did not become ready: $task_language/$task_screen" >&2
            exit 1
        fi
    done
done
echo "Captured selected native camera screenshots in both languages with scene-specific demo photography."
