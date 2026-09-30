import Foundation

enum AppRelaunchPlanner {
    static func shellCommand(appPath: String, currentProcessID: Int32) -> String {
        let pid = Int(currentProcessID)
        let quotedAppPath = shellQuoted(appPath)
        return """
app_path=\(quotedAppPath)
app_executable="$app_path/Contents/MacOS/CodexSwitch"
log_dir="$HOME/.codexswitch/logs"
/bin/mkdir -p "$log_dir"
log_file="$log_dir/relaunch.log"
echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] relaunch requested app=\(appPath) old_pid=\(pid)" >> "$log_file"
# Termination is bounded to a few seconds; allow generous slack before giving up.
attempts=0
while kill -0 \(pid) 2>/dev/null; do
  if [ "$attempts" -ge 300 ]; then
    echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] relaunch aborted old_pid=\(pid) still running" >> "$log_file"
    exit 1
  fi
  attempts=$((attempts + 1))
  sleep 0.1
done
attempts=0
while /usr/bin/pgrep -fx "$app_executable" >/dev/null 2>&1; do
  if [ "$attempts" -ge 100 ]; then
    break
  fi
  attempts=$((attempts + 1))
  sleep 0.1
done
# LaunchServices can briefly still consider the exited app running, so the
# first open may be absorbed; verify and retry.
for launch in 1 2 3; do
  sleep 1.0
  if [ "$launch" -gt 1 ]; then
    echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] relaunch retry app=\(appPath) attempt=$launch" >> "$log_file"
  fi
  /usr/bin/open \(quotedAppPath)
  sleep 3.0
  if /usr/bin/pgrep -fx "$app_executable" >/dev/null 2>&1; then
    echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] relaunch succeeded attempt=$launch" >> "$log_file"
    exit 0
  fi
done
echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] relaunch failed app=\(appPath)" >> "$log_file"
exit 1
"""
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
