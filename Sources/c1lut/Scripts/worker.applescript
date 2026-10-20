-- c1lut worker: renders Capture One styles on the c1lut grid and turns each render into a .cube LUT.
--
--   osascript c1lut-export.scpt <gui|cli> <target> <style> [<style> …]
--
-- The Scripts-menu entry starts it in the background in "gui" mode; `c1lut export` runs it in
-- "cli" mode. `c1lut install` compiles it and fills in the path of the c1lut helper below.

property c1lut : "@C1LUT@"
property recipeName : "c1lut"

on run argv
	if (count of argv) < 3 then error "usage: c1lut-export.scpt <gui|cli> <target> <style> [<style> …]"
	set gui to (item 1 of argv is "gui")
	set targetId to item 2 of argv
	set styleNames to items 3 thru -1 of argv
	try
		set summary to my exportStyles(targetId, styleNames, gui)
	on error errorMessage number errorNumber
		if not gui then error errorMessage number errorNumber
		if errorNumber is not -128 then my alert("c1lut: " & errorMessage)
		return
	end try
	if gui then
		my showSummary(summary)
	else
		return report of summary
	end if
end run

on exportStyles(targetId, styleNames, gui)
	set supportDir to my helperOutput({"path", "support"})
	set outDir to my helperOutput({"path", "output", "--target", targetId})
	set gridFile to my helperOutput({"grid", "--target", targetId})
	set gridFolder to do shell script "dirname " & quoted form of gridFile
	set gridName to do shell script "basename " & quoted form of gridFile & " .tif"
	do shell script "mkdir -p " & quoted form of outDir

	set {doc, openedHere, sessionFolder} to my openSession(supportDir)
	try
		set v to my gridVariant(doc, gridFile, gridName, sessionFolder & "/Capture")
		set renderDir to my prepareRecipe(doc, sessionFolder)
		my checkBaseline(doc, v, renderDir, gridFolder, targetId, gui)

		set entries to {}
		set lutFiles to {}
		set total to count of styleNames
		repeat with i from 1 to total
			set styleName to (item i of styleNames) as text
			if gui then display notification styleName with title "c1lut" subtitle ("Style " & i & " of " & total)
			set notes to my applyStyle(v, styleName)
			set rendered to my render(doc, v, "c1lut-" & i, renderDir)
			set {exitStatus, outLines} to my runHelper({"build", rendered, "--name", styleName, "--target", targetId, "--out", outDir})
			do shell script "rm -f " & quoted form of rendered
			if exitStatus is not 0 then error "Could not build the LUT for “" & styleName & "”: " & my joinWith(outLines, " ")
			set lutFile to item 1 of my plainLines(outLines)
			set end of lutFiles to lutFile
			set entry to "• " & styleName & " → " & my baseName(lutFile)
			repeat with noteRef in (notes & my warningLines(outLines))
				set entry to entry & linefeed & "    " & (contents of noteRef)
			end repeat
			set end of entries to entry
		end repeat
		-- Leave the grid neutral for next time.
		my clearAdjustments(v)
	on error errorMessage number errorNumber
		if openedHere then my closeSession(doc)
		error errorMessage number errorNumber
	end try
	if openedHere then my closeSession(doc)
	return {report:my joinWith(entries, linefeed), outFolder:outDir, lutFiles:lutFiles, targetId:targetId}
end exportStyles

-- MARK: Capture One

-- Opens the session c1lut renders in (chosen once in the Scripts-menu entry).
-- Returns {document, whether this script opened it, the session's folder}.
on openSession(supportDir)
	try
		set sessionPath to do shell script "cat " & quoted form of (supportDir & "/session-path")
		do shell script "test -e " & quoted form of sessionPath
	on error
		error "c1lut has no Capture One session yet. Run Scripts › Export Styles as LUTs in Capture One once to choose it."
	end try
	set sessionName to do shell script "basename " & quoted form of sessionPath & " .cosessiondb"
	set sessionFolder to do shell script "dirname " & quoted form of sessionPath
	set existing to my findDocument(sessionName)
	if existing is not missing value then return {existing, false, sessionFolder}

	set sessionFile to POSIX file sessionPath
	tell application "Capture One" to open sessionFile
	repeat 60 times
		delay 0.5
		set opened to my findDocument(sessionName)
		if opened is not missing value then return {opened, true, sessionFolder}
	end repeat
	error "Capture One did not open the c1lut session (" & sessionPath & ")."
end openSession

on findDocument(sessionName)
	tell application "Capture One"
		repeat with d in documents
			set documentName to name of d
			if documentName is sessionName or documentName is (sessionName & ".cosessiondb") then return contents of d
		end repeat
	end tell
	return missing value
end findDocument

on closeSession(doc)
	try
		tell application "Capture One" to close doc
	end try
end closeSession

-- Copies the grid into the session's Capture folder, shows that folder and returns the grid
-- image's variant. Capture One won't browse folders inside ~/Library, where c1lut keeps grids.
on gridVariant(doc, gridFile, gridName, captureFolder)
	set gridCopy to captureFolder & "/" & gridName & ".tif"
	do shell script "mkdir -p " & quoted form of captureFolder & " && find " & quoted form of captureFolder & " -maxdepth 1 -name 'grid-*.tif' ! -name " & quoted form of (gridName & ".tif") & " -delete && { [ -e " & quoted form of gridCopy & " ] || cp " & quoted form of gridFile & " " & quoted form of gridCopy & "; }"
	tell application "Capture One" to browse doc to path captureFolder
	repeat 120 times
		tell application "Capture One"
			set matches to (every image of doc whose name starts with gridName)
			if (count of matches) > 0 then return first variant of (item 1 of matches)
		end tell
		delay 0.5
	end repeat
	error "Capture One did not show the c1lut grid from " & gridFolder & "."
end gridVariant

-- The c1lut recipe: full-size 16-bit TIFF in sRGB, no output sharpening, into the session's
-- Output folder (a custom folder doesn't stick on a new recipe). Returns that folder's path.
on prepareRecipe(doc, sessionFolder)
	set renderDir to sessionFolder & "/Output"
	try
		tell application "Capture One" to set outputFolder to output of doc
		set renderDir to POSIX path of outputFolder
		if renderDir ends with "/" then set renderDir to text 1 thru -2 of renderDir
	end try
	tell application "Capture One"
		tell doc
			if not (exists recipe recipeName) then make new recipe with properties {name:recipeName}
			tell recipe recipeName
				set enabled to true
				set output format to TIFF
				set bits to 16
				set TIFF compression to Uncompressed
				set scaling method to Fixed
				set scaling unit to percent
				set primary scaling value to 100
				set upscale to false
				set sharpening to no output sharpening
				set root folder type to output location
				set output sub folder to ""
				set existing files to overwrite
			end tell
		end tell
	end tell
	-- Capture One names profiles by their description, which differs between setups.
	repeat with candidate in {"sRGB Color Space Profile", "sRGB IEC61966-2.1", "sRGB"}
		tell application "Capture One"
			try
				set color profile of recipe recipeName of doc to (contents of candidate)
			end try
			set actualProfile to color profile of recipe recipeName of doc
		end tell
		if actualProfile is (contents of candidate) then return renderDir
	end repeat
	error "Could not set the c1lut recipe’s ICC profile to sRGB. In the c1lut session, select the “c1lut” process recipe, set its ICC Profile to sRGB and try again."
end prepareRecipe

-- Renders the grid once without a style and checks it comes back unchanged.
-- Done once per grid; a marker file remembers that it passed.
on checkBaseline(doc, v, renderDir, gridFolder, targetId, gui)
	set marker to gridFolder & "/.c1lut-checked"
	try
		do shell script "test -e " & quoted form of marker
		return
	end try
	my clearAdjustments(v)
	set rendered to my render(doc, v, "c1lut-check", renderDir)
	set {exitStatus, outLines} to my runHelper({"check", rendered, "--target", targetId})
	do shell script "rm -f " & quoted form of rendered
	if exitStatus is 0 then
		do shell script "touch " & quoted form of marker
		return
	end if
	set msg to my joinWith(outLines, return)
	if exitStatus is not 4 or not gui then error msg
	tell application "Capture One"
		activate
		display dialog msg buttons {"Cancel", "Continue Anyway"} default button "Cancel" with title "c1lut" with icon caution
	end tell
end checkBaseline

-- Back to a neutral grid: default adjustments, no extra layers, no local adjustments.
on clearAdjustments(v)
	tell application "Capture One"
		reset adjustments v
		set layerRefs to every layer of v
	end tell
	repeat with i from (count of layerRefs) to 1 by -1
		set layerRef to item i of layerRefs
		tell application "Capture One"
			if kind of layerRef is not background then delete layerRef
		end tell
	end repeat
	my dropLocal(v, "")
end clearAdjustments

-- Applies a style to the grid and removes what a LUT can't hold. Returns notes for the summary.
on applyStyle(v, styleName)
	my clearAdjustments(v)
	set notes to {}
	tell application "Capture One"
		set profileBefore to missing value
		set curveBefore to missing value
		try
			set profileBefore to color profile of adjustments of v
		end try
		try
			set curveBefore to film curve of adjustments of v
		end try
		apply style (first layer of v whose kind is background) named styleName
		-- Base characteristics only make sense for raw files.
		try
			if profileBefore is not missing value and color profile of adjustments of v is not profileBefore then
				set color profile of adjustments of v to profileBefore
				set end of notes to "Ignored the style’s ICC profile (it only applies to raw files)."
			end if
		end try
		try
			if curveBefore is not missing value and film curve of adjustments of v is not curveBefore then
				set film curve of adjustments of v to curveBefore
				set end of notes to "Ignored the style’s film curve (it only applies to raw files)."
			end if
		end try
		set layerRefs to every layer of v
	end tell
	set notes to notes & my dropLocal(v, "")

	repeat with i from (count of layerRefs) to 1 by -1
		set layerRef to item i of layerRefs
		tell application "Capture One"
			set layerName to name of layerRef
			set isBackground to (kind of layerRef is background)
			set isFilled to (kind of layerRef is filled)
		end tell
		if isFilled then
			-- A filled layer covers the whole image, so its global adjustments still apply.
			set notes to notes & my dropLocal(layerRef, "Layer “" & layerName & "”: ")
		else if not isBackground then
			tell application "Capture One" to delete layerRef
			set end of notes to "Removed layer “" & layerName & "” (masked adjustments can’t be part of a LUT)."
		end if
	end repeat
	return notes
end applyStyle

-- Sets adjustments that mix neighbouring pixels to 0 on a variant or layer.
-- Returns a note listing the ones that were set.
on dropLocal(owner, prefix)
	set dropped to {}
	tell application "Capture One"
		try
			set currentValue to clarity amount of adjustments of owner
			if currentValue is not 0 then
				set clarity amount of adjustments of owner to 0
				set end of dropped to "Clarity " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to clarity structure of adjustments of owner
			if currentValue is not 0 then
				set clarity structure of adjustments of owner to 0
				set end of dropped to "Structure " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to dehaze amount of adjustments of owner
			if currentValue is not 0 then
				set dehaze amount of adjustments of owner to 0
				set end of dropped to "Dehaze " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to highlight recovery of adjustments of owner
			if currentValue is not 0 then
				set highlight recovery of adjustments of owner to 0
				set end of dropped to "HDR Highlight " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to shadow recovery of adjustments of owner
			if currentValue is not 0 then
				set shadow recovery of adjustments of owner to 0
				set end of dropped to "HDR Shadow " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to vignetting amount of adjustments of owner
			if currentValue is not 0 then
				set vignetting amount of adjustments of owner to 0
				set end of dropped to "Vignetting " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to sharpening amount of adjustments of owner
			if currentValue is not 0 then
				set sharpening amount of adjustments of owner to 0
				set end of dropped to "Sharpening " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to noise reduction luminance of adjustments of owner
			if currentValue is not 0 then
				set noise reduction luminance of adjustments of owner to 0
				set end of dropped to "Noise Reduction " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to noise reduction color of adjustments of owner
			if currentValue is not 0 then
				set noise reduction color of adjustments of owner to 0
				set end of dropped to "Color Noise Reduction " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to noise reduction single pixel of adjustments of owner
			if currentValue is not 0 then
				set noise reduction single pixel of adjustments of owner to 0
				set end of dropped to "Single Pixel " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to film grain impact of adjustments of owner
			if currentValue is not 0 then
				set film grain impact of adjustments of owner to 0
				set end of dropped to "Film Grain " & my numberText(currentValue)
			end if
		end try
		try
			set currentValue to moire amount of adjustments of owner
			if currentValue is not 0 then
				set moire amount of adjustments of owner to 0
				set end of dropped to "Moiré " & my numberText(currentValue)
			end if
		end try
	end tell
	if dropped is {} then return {}
	return {prefix & "Dropped " & my joinWith(dropped, ", ") & " (local adjustments can’t be part of a LUT)."}
end dropLocal

-- Processes the grid with the c1lut recipe and waits for the file. Returns its path.
on render(doc, v, outName, renderDir)
	do shell script "rm -f " & quoted form of renderDir & "/" & quoted form of outName & ".*"
	tell application "Capture One"
		set output name format of recipe recipeName of doc to outName
		set jobId to (process v recipe recipeName) as text
	end tell
	if jobId starts with "ERROR" then error "Capture One could not process the grid (" & jobId & "). Processing from scripts needs Capture One Pro."

	set idleChecks to 0
	repeat 600 times -- up to 5 minutes
		delay 0.5
		set pending to 0
		try
			tell application "Capture One" to set pending to count of (every job of doc whose id is jobId)
		end try
		set found to do shell script "ls " & quoted form of renderDir & " | grep '^" & outName & "\\.' | head -n 1"
		if found is not "" and pending is 0 then
			set renderedFile to renderDir & "/" & found
			set sizeBefore to do shell script "stat -f %z " & quoted form of renderedFile
			delay 0.5
			set sizeAfter to do shell script "stat -f %z " & quoted form of renderedFile
			if sizeBefore is sizeAfter and sizeAfter is not "0" then return renderedFile
		else if pending is 0 then
			-- The job is done but no file has appeared: give it 10 seconds, then stop.
			set idleChecks to idleChecks + 1
			if idleChecks > 20 then error "Capture One processed the grid, but the file isn’t in " & renderDir & ". Check the “c1lut” process recipe in the c1lut session."
		end if
	end repeat
	error "Capture One did not finish processing the grid within 5 minutes."
end render

-- MARK: Results

on showSummary(summary)
	set lutCount to count of (lutFiles of summary)
	set msg to "Exported " & lutCount & " LUT" & my plural(lutCount) & " to " & (outFolder of summary) & ":" & return & return & (report of summary)
	tell application "Capture One"
		activate
		set choice to button returned of (display dialog msg buttons {"Show in Finder", "OK"} default button "OK" with title "c1lut")
	end tell
	if choice is "Show in Finder" then do shell script "open " & quoted form of (outFolder of summary)
	if (targetId of summary) starts with "lumix" then my offerCardCopy(lutFiles of summary)
end showSummary

-- Lumix cameras load LUTs from the top folder of the memory card.
on offerCardCopy(lutFiles)
	set cards to paragraphs of (do shell script "for v in /Volumes/*; do [ -d \"$v/DCIM\" ] && echo \"$v\"; done; true")
	if (count of cards) is 0 then return
	if (count of cards) is 1 then
		set card to item 1 of cards
		tell application "Capture One"
			set choice to button returned of (display dialog "Copy the LUTs to the memory card “" & my baseName(card) & "”? The camera loads them from the card’s top folder." buttons {"Not Now", "Copy"} default button "Copy" with title "c1lut")
		end tell
		if choice is not "Copy" then return
	else
		tell application "Capture One"
			set picked to choose from list cards with title "c1lut" with prompt "Copy the LUTs to which memory card?"
		end tell
		if picked is false then return
		set card to item 1 of picked
	end if
	repeat with lutFile in lutFiles
		do shell script "cp " & quoted form of (contents of lutFile) & " " & quoted form of (card & "/")
	end repeat
	tell application "Capture One"
		display dialog "Copied. On the camera, add them in the LUT Library menu." buttons {"OK"} default button "OK" with title "c1lut"
	end tell
end offerCardCopy

on alert(msg)
	tell application "Capture One"
		activate
		display dialog msg buttons {"OK"} default button "OK" with title "c1lut" with icon caution
	end tell
end alert

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

-- Runs the helper and returns its first line of output, or raises its error.
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

on baseName(p)
	return do shell script "basename " & quoted form of p
end baseName

on plural(n)
	if n is 1 then return ""
	return "s"
end plural

-- Adjustment values as Capture One shows them, e.g. -0.2 rather than -0.20000000298.
on numberText(value)
	set rounded to (round (value * 10) rounding as taught in school) / 10
	if rounded mod 1 is 0 then return (rounded as integer) as text
	return rounded as text
end numberText
