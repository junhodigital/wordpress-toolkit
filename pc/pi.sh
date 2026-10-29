#!/usr/bin/env bash
# Run a toolkit command on the Pi, lending it this PC's SSH keys for the live hosts for the
# length of that one command (ssh-agent forwarding). Runs on the PC (Git Bash).
#
#   pc/pi.sh bin/refresh.sh vistaclinic --yes
#   pc/pi.sh bin/publish.py vistaclinic post 123
#
# The keys never leave the PC and the Pi stores none: a private agent is started here, the
# keys are loaded into it, the Pi uses it through the ssh connection, and the agent is killed
# when the command ends. So live hosts are reachable from the Pi only while a command started
# here is running.
#
# Keys lent: PI_LEND_KEYS (space separated), default ~/.ssh/vc-hostinger.
# The Pi: PI (default dnasc@davideRasberry).
set -euo pipefail
[ $# -ge 1 ] || { sed -n '2,8p' "$0"; exit 2; }
pi=${PI:-dnasc@davideRasberry}
eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null' EXIT
for key in ${PI_LEND_KEYS:-~/.ssh/vc-hostinger}; do
	ssh-add -q -t 3600 "$key"
done
ssh -o ForwardAgent=yes "$pi" "cd ~/Documents/wordpressServers && $(printf '%q ' "$@")"
