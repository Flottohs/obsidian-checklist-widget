#!/bin/zsh
# Removes the widgets from this Mac. Your notes, templates and this folder are left alone.
for name in checklistwidget weeklywidget; do
  label="com.$(id -un).$name"
  launchctl bootout "gui/$UID/$label" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -f "$HOME/.local/bin/checklist-widget"
echo "Widgets removed. Run ./build.sh to put them back."
