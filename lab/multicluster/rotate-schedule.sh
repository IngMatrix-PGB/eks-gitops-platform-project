#!/bin/sh
# Opt-in scheduler for `make mc-spoke-rotate` (lab-multicluster only).
# Backs mc-spoke-rotate-schedule / -unschedule / -schedule-status.
#
#   install    macOS: writes a user LaunchAgent that runs
#              `make mc-spoke-rotate MIN_HOURS=8` from this checkout every
#              6 hours (and once at load), logging to
#              .local/logs/spoke-rotate.log; Linux: prints the crontab
#              line to add by hand, installs nothing.
#   uninstall  macOS: unloads the LaunchAgent and deletes its plist.
#   status     whether it is installed, and the log's last lines.
#
# This is persistent configuration on the operator's machine, so no
# other target installs it. The log never holds a token: spoke-rotate.sh
# prints only spoke names and expiry times.
set -eu
[ -f lab/multicluster/spoke-rotate.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
label="local.eks-gitops-lab.spoke-rotate"
interval=21600
repo="$(pwd -P)"
log="$repo/.local/logs/spoke-rotate.log"
plist="${HOME:?HOME is not set}/Library/LaunchAgents/${label}.plist"
domain="gui/$(id -u)"
action="${1:-}"

if [ "$(uname -s)" != "Darwin" ]; then
  case "$action" in
    install)
      echo "Not macOS: nothing installed. To schedule it, add this line with 'crontab -e':"
      echo "0 */6 * * * cd '$repo' && make mc-spoke-rotate MIN_HOURS=8 >> '$log' 2>&1"
      exit 0 ;;
    uninstall|status) echo "Not macOS: no LaunchAgent is managed here - check 'crontab -l'"; exit 0 ;;
    *) echo "usage: rotate-schedule.sh install|uninstall|status" >&2; exit 1 ;;
  esac
fi

case "$action" in
  install)
    mkdir -p "$repo/.local/logs" "$(dirname "$plist")"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>cd '${repo}' &amp;&amp; date -u +%Y-%m-%dT%H:%M:%SZ &amp;&amp; make mc-spoke-rotate MIN_HOURS=8</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>StartInterval</key><integer>${interval}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${log}</string>
  <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
EOF
    chmod 644 "$plist"
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    launchctl bootstrap "$domain" "$plist"
    echo "OK: LaunchAgent '$label' installed - every $((interval / 3600))h and now; log $log"
    echo "    remove it with: make mc-spoke-rotate-unschedule"
    ;;
  uninstall)
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    if [ -f "$plist" ]; then rm -f -- "$plist"; echo "OK: LaunchAgent '$label' removed"; else echo "OK: LaunchAgent '$label' was not installed"; fi
    ;;
  status)
    if launchctl print "$domain/$label" >/dev/null 2>&1; then echo "installed: yes ($plist)"; else echo "installed: no"; fi
    if [ -f "$log" ]; then echo "last log lines:"; tail -n 5 "$log" | sed 's/^/    /'; fi
    ;;
  *) echo "usage: rotate-schedule.sh install|uninstall|status" >&2; exit 1 ;;
esac
