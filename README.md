# Setup the scripts to mount your SMB share on login

Open `org.kochtobi.mount-time-machine.plist` and enter your information in the program arguments.
```bash
vim org.kochtobi.mount-time-machine.plist
```

Then move the files and start the agent in launchctl
```bash
mv org.kochtobi.mount-time-machine.plist ~/Library/LaunchAgents/
mv mounting-skript.sh /usr/local/bin/
chmod +x /usr/local/bin/mounting-skript.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.kochtobi.mount-time-machine.plist
```
