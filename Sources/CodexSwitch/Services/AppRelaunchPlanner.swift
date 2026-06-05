import Foundation

enum AppRelaunchPlanner {
    static func shellCommand(appPath: String, currentProcessID: Int32) -> String {
        let pid = Int(currentProcessID)
        let quotedAppPath = shellQuoted(appPath)
        return """
log_dir="$HOME/.codexswitch/logs"
/bin/mkdir -p "$log_dir"
log_file="$log_dir/relaunch.log"
echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] relaunch requested app=\(appPath) old_pid=\(pid)" >> "$log_file"
attempts=0
while kill -0 \(pid) 2>/dev/null; do
  if [ "$attempts" -ge 80 ]; then
    break
  fi
  attempts=$((attempts + 1))
  sleep 0.1
done
attempts=0
while /usr/bin/pgrep -x CodexSwitch >/dev/null 2>&1; do
  if [ "$attempts" -ge 80 ]; then
    break
  fi
  attempts=$((attempts + 1))
  sleep 0.1
done
sleep 1.0
/usr/bin/open -n \(quotedAppPath)
sleep 3.0
if ! /usr/bin/pgrep -x CodexSwitch >/dev/null 2>&1; then
  echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] relaunch retry app=\(appPath)" >> "$log_file"
  /usr/bin/open -n \(quotedAppPath)
fi
"""
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
