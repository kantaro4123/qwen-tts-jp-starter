on run
	set appPath to POSIX path of (path to me)
	set launcherScript to quoted form of (appPath & "Contents/Resources/launcher.sh")
	do shell script "chmod +x " & launcherScript
	do shell script "open -a Terminal " & launcherScript
end run
