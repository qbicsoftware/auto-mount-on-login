# Setup the scripts to mount your SMB share on login

Open `org.kochtobi.mount-time-machine.plist` and enter your information in the program arguments.
Them move and start the agent in launchctl
```bash
cp org.kochtobi.mount-time-machine.plist ~/Library/LaunchAgents/
cp mounting-skript.sh /usr/local/bin/
chmod +x /usr/local/bin/mounting-skript.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.kochtobi.mount-time-machine.plist
```
