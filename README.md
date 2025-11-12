
## What does this repository solve?

When the applie time machine is configured to use a SMB share, disconnects can interrupt the backup.
As login items are only triggered once on login and many people do not log out but only lock their screen, a re-mounting is never attempted. 
This leads to missed backups and manual effort to connect to the SMB share using the Finder. 

By following the steps in this repository, a re-connection and re-mounting of the required volumes are attempted every minute. The mount attempt is only made when located within a defined network.

## Setup the scripts to mount your SMB share on login

Clone this repository and navigate into the created folder

```bash
git clone https://github.com/KochTobi/auto-mount-on-login.git
cd auto-mount-on-login
```

Open `org.kochtobi.mount-time-machine.plist` and enter your information in the program arguments.
```bash
vim org.kochtobi.mount-time-machine.plist
```
**_Make sure to replace all comments with your information!_**

Then move the files and start the agent in launchctl
```bash
mv org.kochtobi.mount-time-machine.plist ~/Library/LaunchAgents/
mv mounting-skript.sh /usr/local/bin/
chmod +x /usr/local/bin/mounting-skript.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.kochtobi.mount-time-machine.plist
```
You may be asked to enter your ZDV password.