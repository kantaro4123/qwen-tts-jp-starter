on run
	set appPath to POSIX path of (path to me)
	set launcherScript to quoted form of (appPath & "Contents/Resources/launcher.sh")
	set chosenAction to choose from list {"起動", "初回セットアップ", "更新", "ローカル文字起こしを追加"} with prompt "やりたい操作を選んでください" default items {"起動"}
	if chosenAction is false then
		return
	end if
	set actionName to item 1 of chosenAction
	set actionArg to "run"
	if actionName is "初回セットアップ" then
		set actionArg to "setup"
	else if actionName is "更新" then
		set actionArg to "update"
	else if actionName is "ローカル文字起こしを追加" then
		set actionArg to "install-local-asr"
	end if
	do shell script "chmod +x " & launcherScript
	do shell script "open -a Terminal " & launcherScript & " --args " & actionArg
end run
