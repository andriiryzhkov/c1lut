-- Export Styles as LUTs: the Capture One Scripts-menu entry for c1lut.
--
-- Asks which styles to export and what the LUTs are for, then starts the c1lut worker in the
-- background so Capture One stays responsive while it renders. `c1lut install` compiles this into
-- ~/Library/Scripts/Capture One Scripts/ and fills in the paths below.

property c1lut : "@C1LUT@"
property worker : "@WORKER@"
property panasonicPage : "@PANASONIC_PAGE@"

on run
	try
		my startExport()
	on error errorMessage number errorNumber
		if errorNumber is not -128 then
			display dialog "c1lut: " & errorMessage buttons {"OK"} default button "OK" with title "c1lut" with icon caution
		end if
	end try
end run

on startExport()
	set supportDir to my helperOutput({"path", "support"})

	-- c1lut's own window: the target and Capture One's styles as a tree with checkboxes.
	set {targetId, styleNames} to my pickStyles()
	if styleNames is {} then return

	my ensureBase(targetId)
	my ensureSession(supportDir)

	set command to "/usr/bin/osascript " & quoted form of worker & " gui " & quoted form of targetId
	repeat with styleName in styleNames
		set command to command & " " & quoted form of (contents of styleName)
	end repeat
	do shell script "nohup " & command & " > " & quoted form of (supportDir & "/export.log") & " 2>&1 &"
	set styleCount to count of styleNames
	set styleWord to "styles"
	if styleCount is 1 then set styleWord to "style"
	display notification "Exporting " & styleCount & " " & styleWord & ". Capture One opens the c1lut session while it works." with title "c1lut"
end startExport

-- Opens c1lut's picker window with Capture One's styles in their folders.
-- Returns {target id, chosen style names}; the names are {} when cancelled.
on pickStyles()
	tell application "Capture One" to set styleList to available styles
	if (count of styleList) is 0 then error "Capture One has no styles yet."
	set appPath to POSIX path of (path to application "Capture One")
	set {exitStatus, outLines} to my runHelper({"pick-styles", "--app", appPath, "--"} & styleList)
	if exitStatus is 5 then return {"", {}} -- Cancel
	if exitStatus is not 0 then error my joinWith(outLines, return)

	-- "target<TAB>id" and "style<TAB>name" lines; anything else is noise from macOS.
	set targetId to ""
	set styleNames to {}
	repeat with lineRef in outLines
		set s to contents of lineRef
		if s starts with ("target" & tab) then set targetId to text 8 thru -1 of s
		if s starts with ("style" & tab) then set end of styleNames to text 7 thru -1 of s
	end repeat
	if targetId is "" then return {"", {}}
	return {targetId, styleNames}
end pickStyles

-- V-Log targets start from Panasonic's V-Log → V-709 LUT. The installer usually downloads it;
-- otherwise c1lut downloads it from Panasonic now, or the user picks a copy they already have.
on ensureBase(targetId)
	set {exitStatus, outLines} to my runHelper({"grid", "--target", targetId})
	if exitStatus is 0 then return
	if exitStatus is not 3 then error my joinWith(outLines, return)

	set choice to button returned of (display dialog "c1lut needs Panasonic’s V-Log → V-709 LUT once. It turns V-Log into a normal-looking image before your style is applied, the way the camera does." & return & return & "c1lut can download it from Panasonic now, or you can choose a .cube you already have." buttons {"Cancel", "Choose File…", "Download from Panasonic"} default button "Download from Panasonic" with title "c1lut")
	if choice is "Download from Panasonic" then
		set {exitStatus, outLines} to my runHelper({"setup", "--download-vlog-base"})
		if exitStatus is not 0 then
			set choice to button returned of (display dialog "c1lut couldn’t download Panasonic’s LUT." & return & return & "Download “VLog_to_V709_forV35_EN.zip” from Panasonic’s LUT page, unzip it, then choose the .cube file inside." buttons {"Cancel", "Open Panasonic’s Page", "Choose File…"} default button "Open Panasonic’s Page" with title "c1lut" with icon caution)
			if choice is "Open Panasonic’s Page" then do shell script "open " & quoted form of panasonicPage
		end if
	end if
	if exitStatus is not 0 or choice is "Choose File…" then my chooseBase()
	my helperOutput({"grid", "--target", targetId})
end ensureBase

on chooseBase()
	set lutFile to choose file with prompt "Choose Panasonic’s V-Log to V-709 LUT (.cube):"
	set {exitStatus, outLines} to my runHelper({"setup", "--vlog-base", POSIX path of lutFile})
	if exitStatus is not 0 then error my joinWith(outLines, return)
	set warnings to my warningLines(outLines)
	if warnings is not {} then
		display dialog my joinWith(warnings, return) buttons {"Cancel", "Use It Anyway"} default button "Cancel" with title "c1lut" with icon caution
	end if
end chooseBase

-- c1lut renders in a Capture One session of its own, so catalogs and sessions stay untouched.
on ensureSession(supportDir)
	set configFile to supportDir & "/session-path"
	try
		set sessionPath to do shell script "cat " & quoted form of configFile
		do shell script "test -e " & quoted form of sessionPath
		return
	end try

	display dialog "c1lut renders your styles in a Capture One session of its own, so your catalogs and sessions stay untouched." & return & return & "If you don’t have one yet: click Cancel, choose File › New Session…, name it “c1lut”, save it anywhere (for example in Documents), then run this script again." buttons {"Cancel", "Locate Session…"} default button "Locate Session…" with title "c1lut"
	set sessionFile to choose file with prompt "Select the c1lut session file (.cosessiondb):"
	set sessionPath to POSIX path of sessionFile
	if sessionPath ends with "/" then set sessionPath to text 1 thru -2 of sessionPath
	if sessionPath does not end with ".cosessiondb" then error "That is not a Capture One session file (.cosessiondb)."
	do shell script "mkdir -p " & quoted form of supportDir & " && printf %s " & quoted form of sessionPath & " > " & quoted form of configFile
end ensureSession

-- MARK: Helpers

-- Runs the c1lut helper. Returns {exit status, output lines (stdout and stderr)}.
on runHelper(args)
	set command to quoted form of c1lut
	repeat with arg in args
		set command to command & " " & quoted form of ((contents of arg) as text)
	end repeat
	set outLines to paragraphs of (do shell script command & " 2>&1; echo \"exit:$?\"")
	set exitStatus to (text 6 thru -1 of (last item of outLines)) as integer
	if (count of outLines) > 1 then
		set outLines to items 1 thru -2 of outLines
	else
		set outLines to {}
	end if
	return {exitStatus, outLines}
end runHelper

on helperOutput(args)
	set {exitStatus, outLines} to my runHelper(args)
	if exitStatus is not 0 then error my joinWith(outLines, return) number (1000 + exitStatus)
	return item 1 of my plainLines(outLines)
end helperOutput

on plainLines(outLines)
	set kept to {}
	repeat with lineRef in outLines
		set s to contents of lineRef
		if s is not "" and s does not start with "warning: " then set end of kept to s
	end repeat
	return kept
end plainLines

on warningLines(outLines)
	set kept to {}
	repeat with lineRef in outLines
		set s to contents of lineRef
		if s starts with "warning: " then set end of kept to (text 10 thru -1 of s)
	end repeat
	return kept
end warningLines

on joinWith(items_, separator)
	set saved to AppleScript's text item delimiters
	set AppleScript's text item delimiters to separator
	set joined to items_ as text
	set AppleScript's text item delimiters to saved
	return joined
end joinWith
