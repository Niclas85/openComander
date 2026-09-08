-- Drive the visible path field, then press Return; no internal app state.
on run taskArguments
    set taskPaneIndex to (item 1 of taskArguments) as integer
    set taskPath to item 2 of taskArguments
    tell application "System Events" to tell process "OpenCommander"
        set frontmost to true
        set taskElements to entire contents of window 1
        set taskIndex to 0
        repeat with taskElementReference in taskElements
            set taskElement to contents of taskElementReference
            if role of taskElement is "AXTextField" then
                set taskIndex to taskIndex + 1
                if taskIndex is taskPaneIndex then
                    set value of taskElement to taskPath
                    set value of attribute "AXFocused" of taskElement to true
                    key code 36
                    return
                end if
            end if
        end repeat
        error "Path field not found"
    end tell
end run
