-- mount-time-machine.applescript
--
-- Entry point for MountTimeMachine.app, the tiny application wrapper that the
-- installer builds around mount-time-machine.sh.
--
-- Why a wrapper at all?
--
-- macOS protects network volumes (an SMB share mounted under /Volumes) with the
-- privacy system TCC. Permission is granted per application, and the consent
-- dialog ("... would like to access files on a network volume") can only be
-- shown for a process that has an application identity. A shell script started
-- directly by launchd has none, so every read is denied with
-- "Operation not permitted" and the user is never asked.
--
-- This bundle gives the LaunchAgent that identity. The bundle is ad-hoc signed
-- by install.sh; TCC records the grant against that code signature, so nothing
-- mutable is kept inside the bundle. Instead the applet runs the script from
-- /usr/local/bin and reads its settings from ~/.config/auto-mount-on-login.
--
-- Configuration is not taken from the environment: AppleScript's `do shell
-- script` starts a shell with a fixed, minimal environment and does not inherit
-- the LaunchAgent's EnvironmentVariables.
--
-- The app shows no window and no Dock icon.

on run
	try
		set scriptPath to "/usr/local/bin/mount-time-machine.sh"
		set configPath to (POSIX path of (path to home folder)) & ".config/auto-mount-on-login/config.env"

		-- `set -a` exports everything config.env defines, so the shell script
		-- sees the configured TM_VOLUME, SMB_USER, ... PATH is set explicitly:
		-- `do shell script` otherwise uses a minimal /usr/bin:/bin:/usr/sbin:/sbin.
		set cmd to "export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" & ¬
			"; if [ -r " & quoted form of configPath & " ]; then set -a; . " & ¬
			quoted form of configPath & "; set +a; fi; exec " & quoted form of scriptPath

		-- The script may wait for Apple's password dialog (PROMPT_TIMEOUT,
		-- 300s by default), so raise AppleScript's default 120s cap.
		with timeout of 3600 seconds
			do shell script cmd
		end timeout
	on error errMsg number errNum
		-- Do not re-raise: an uncaught error makes the applet show a modal
		-- dialog, and this runs unattended from launchd. The shell script logs
		-- its own errors to ~/Library/Logs/auto-mount-on-login.log; returning
		-- the text keeps the app quiet.
		return errMsg & " (" & errNum & ")"
	end try
end run
