; KeyboardGuard - generic per-device key blocker / remapper
; Lets you: install the Interception driver, reboot, pick a keyboard device,
; then either BLOCK a key on it, or REMAP it to send a different key.
; All other keys / other keyboards / on-screen keyboard / touch keyboard are untouched.

; Off, not Force: the background Service and any GUI window you open are the
; same exe. "Force" would make AHK treat them as duplicates of "one instance"
; and kill whichever was running first - which was silently killing the
; Service every time the GUI was opened, and vice versa.
#SingleInstance Off
#Requires AutoHotkey v2.0
Persistent
DetectHiddenWindows true

; This app needs admin rights for everything it does (writing into its own
; Program Files folder, installing the driver, installing the service), so
; it elevates itself once up front instead of prompting separately per action.
;
; Windows' elevation (runas) can silently launch the new process with its
; working directory reset to somewhere the app can't write to, which breaks
; the FileInstall calls below (they use paths relative to the working dir).
; Pass WorkingDir explicitly on the relaunch, and pin it again unconditionally
; right after - covers the relaunched case, the already-elevated case, and
; the Windows Service case (nssm sets a working dir too, but this is a
; free, harmless belt-and-braces fix either way).
if (!A_IsAdmin) {
    argsStr := ""
    for a in A_Args
        argsStr .= ' "' a '"'
    try Run('*RunAs "' A_ScriptFullPath '"' argsStr, A_ScriptDir)
    ExitApp
}
SetWorkingDir(A_ScriptDir)

; ---- Embed runtime dependencies into the compiled exe ----
; Only extract files that are missing. These are static third-party binaries
; that never change between our builds, so there's no need to overwrite them
; on every launch - which matters because the background Service may already
; be running and holding them open, so an unconditional overwrite would fail.
if (A_IsCompiled) {
    try {
        DirCreate("Lib")
        DirCreate("Lib\x64")
        if !FileExist("Lib\AutoHotInterception.ahk")
            FileInstall("Lib\AutoHotInterception.ahk", "Lib\AutoHotInterception.ahk", 1)
        if !FileExist("Lib\CLR.ahk")
            FileInstall("Lib\CLR.ahk", "Lib\CLR.ahk", 1)
        ; The managed .NET assembly the whole library hosts via the CLR - this
        ; was missing from earlier builds (silently masked by a leftover copy
        ; from early testing), which would break on any fresh install.
        if !FileExist("Lib\AutoHotInterception.dll")
            FileInstall("Lib\AutoHotInterception.dll", "Lib\AutoHotInterception.dll", 1)
        if !FileExist("Lib\x64\interception.dll")
            FileInstall("Lib\x64\interception.dll", "Lib\x64\interception.dll", 1)
        if !FileExist("install-interception.exe")
            FileInstall("install-interception.exe", "install-interception.exe", 1)
        if !FileExist("nssm.exe")
            FileInstall("nssm.exe", "nssm.exe", 1)
        ; Strip "downloaded from the internet" marks if present - the .NET
        ; CLR can silently fail to load an assembly flagged this way (fails
        ; with a generic "Failed" error, which is what led to finding this).
        for f in ["Lib\AutoHotInterception.dll", "Lib\x64\interception.dll", "install-interception.exe", "nssm.exe"]
            try FileDelete(f ":Zone.Identifier")
    } catch as e {
        MsgBox("KeyboardGuard couldn't write its files to:`n" A_ScriptDir "`n`nError: " e.Message "`n`nTry running it as administrator, or reinstall it.", "Startup error", "Iconx")
        ExitApp
    }
}
#include Lib\AutoHotInterception.ahk

; Shared under ProgramData (not per-user AppData) so both the interactive GUI
; (run by you) and the background Windows Service (runs as SYSTEM, has its
; own separate profile) read/write the same rules files.
RulesFile := A_AppDataCommon "\KeyboardGuard\rules.txt"
RemapRulesFile := A_AppDataCommon "\KeyboardGuard\remap_rules.txt"
DirCreate(A_AppDataCommon "\KeyboardGuard")

AHI := ""                  ; lazily-created AutoHotInterception instance
Rules := []                 ; block rules: {vid, pid, handle, code, keyname}
ActiveSubs := []            ; list of {id, code} currently subscribed while blocking
Blocking := false
RemapRules := []            ; remap rules: {vid, pid, handle, code, keyname, targetkey}
ActiveRemapSubs := []        ; list of {id, code} currently subscribed while remapping
Remapping := false
DeviceCache := Map()        ; index shown in list -> {id, vid, pid, handle}
CapturedCode := 0
Capturing := false
CaptureDevId := 0          ; device currently subscribed for block-tab capture, if any
CapturedTargetKeyName := ""
CapturingTarget := false
SourceCaptureDevId := 0    ; device currently subscribed for remap-tab source capture, if any
LastAHIError := ""

; ---------------- Autostart / service silent mode ----------------
if (A_Args.Length > 0 && A_Args[1] = "/auto") {
    LoadRules()
    LoadRemapRules()
    ; Retry for a while in case this runs as a service starting at boot,
    ; before the Interception driver has finished initializing.
    SetTimer(TryStartInAutoMode, 5000)
    TryStartInAutoMode()
    try TraySetup()
    return
}

; A Windows Service runs in Session 0, which has no access to the user's
; desktop - Send() calls from there silently go nowhere. Blocking still
; works fine there (it's the driver refusing to pass the key through, not
; an injection), but remapping fundamentally cannot: it needs to inject a
; replacement keystroke into a real desktop session. So the Service (Session
; 0) only ever does blocking; remapping only runs from the interactive
; "run after login" scheduled task, which executes in the user's own
; session and has real desktop access.
IsInteractiveSession() {
    DllCall("kernel32\ProcessIdToSessionId", "uint", DllCall("GetCurrentProcessId", "uint"), "uint*", &sessionId := 0)
    return sessionId != 0
}

TryStartInAutoMode() {
    global AHI
    if (AHI != "")
        return
    if (TrySetupAHI()) {
        StartBlocking()
        if IsInteractiveSession()
            StartRemapping()
        SetTimer(TryStartInAutoMode, 0)
    }
}

; ---------------- GUI ----------------
; +Resize gives a normal resizable window with minimize/maximize/close all
; present, so it can be maximized or resized to fit smaller laptop screens.
MainGui := Gui("+Resize", "KeyboardGuard")
MainGui.SetFont("s10")
MainGui.OnEvent("Close", (*) => ExitApp())

MainGui.Add("GroupBox", "x15 y15 w560 h95", "Step 1 - Interception Driver")
lblDriver := MainGui.Add("Text", "x30 y38 w530", "Checking driver status...")
btnInstallDriver := MainGui.Add("Button", "x30 y68 w170", "Install Driver")
btnInstallDriver.OnEvent("Click", OnInstallDriver)
btnUninstallDriver := MainGui.Add("Button", "x210 y68 w170", "Uninstall Driver")
btnUninstallDriver.OnEvent("Click", OnUninstallDriver)
btnReboot := MainGui.Add("Button", "x390 y68 w170", "Reboot Now")
btnReboot.OnEvent("Click", OnReboot)

MainGui.Add("GroupBox", "x15 y118 w560 h100", "Step 2 - Choose Keyboard")
btnRefresh := MainGui.Add("Button", "x30 y141 w170", "Refresh Keyboard List")
btnRefresh.OnEvent("Click", OnRefreshKeyboards)
lvDevices := MainGui.Add("ListView", "x210 y138 w350 h72", ["ID", "VID", "PID", "Handle"])
lvDevices.ModifyCol(1, 30)
lvDevices.ModifyCol(2, 70)
lvDevices.ModifyCol(3, 70)
lvDevices.ModifyCol(4, 165)

tabY := 226
tabH := 340
tab := MainGui.Add("Tab3", "x15 y" tabY " w560 h" tabH, ["Block a Key", "Remap a Key"])

; ---- Tab 1: Block a Key ----
tab.UseTab(1)
contentTop := tabY + 40
btnCapture := MainGui.Add("Button", "x30 y" contentTop " w170 h30", "Capture Key From Selected")
btnCapture.OnEvent("Click", OnCaptureKey)
lblCapture := MainGui.Add("Text", "x210 y" (contentTop + 6) " w350", "Select a device above, click Capture, then press the key.")

btnVirtualKb := MainGui.Add("Button", "x30 y" (contentTop + 36) " w170 h30", "Pick From Virtual Keyboard")
btnVirtualKb.OnEvent("Click", OnVirtualKeyboardBlock)
MainGui.Add("Text", "x210 y" (contentTop + 42) " w350", "Use this if the key sends no signal at all (fully dead, not just stuck).")

btnAddRule := MainGui.Add("Button", "x30 y" (contentTop + 72) " w170 h30", "Add As Blocked Rule")
btnAddRule.OnEvent("Click", OnAddRule)

lvRules := MainGui.Add("ListView", "x30 y" (contentTop + 108) " w530 h100", ["Device", "Key Blocked"])
lvRules.ModifyCol(1, 430)
lvRules.ModifyCol(2, 100)
btnRemoveRule := MainGui.Add("Button", "x30 y" (contentTop + 218) " w170 h30", "Remove Selected Rule")
btnRemoveRule.OnEvent("Click", OnRemoveRule)
btnStart := MainGui.Add("Button", "x210 y" (contentTop + 218) " w170 h30", "Start Blocking")
btnStart.OnEvent("Click", OnStartBlocking)
btnStop := MainGui.Add("Button", "x390 y" (contentTop + 218) " w170 h30", "Stop Blocking")
btnStop.OnEvent("Click", OnStopBlocking)

; ---- Tab 2: Remap a Key ----
tab.UseTab(2)
btnCaptureSource := MainGui.Add("Button", "x30 y" contentTop " w170 h30", "Capture Source Key")
btnCaptureSource.OnEvent("Click", OnCaptureSourceKey)
lblCaptureSource := MainGui.Add("Text", "x210 y" (contentTop + 6) " w350", "Select a device above, click here, then press the faulty key.")

btnVirtualKbSource := MainGui.Add("Button", "x30 y" (contentTop + 36) " w170 h30", "Pick From Virtual Keyboard")
btnVirtualKbSource.OnEvent("Click", OnVirtualKeyboardRemapSource)
MainGui.Add("Text", "x210 y" (contentTop + 42) " w350", "Use this if the key sends no signal at all (fully dead, not just stuck).")

btnCaptureTarget := MainGui.Add("Button", "x30 y" (contentTop + 72) " w170 h30", "Capture Key To Send Instead")
btnCaptureTarget.OnEvent("Click", OnCaptureTargetKey)
lblCaptureTarget := MainGui.Add("Text", "x210 y" (contentTop + 78) " w350", "Click here, then press any key/key combo - it can be on any keyboard.")

btnAddRemapRule := MainGui.Add("Button", "x30 y" (contentTop + 108) " w170 h30", "Add As Remap Rule")
btnAddRemapRule.OnEvent("Click", OnAddRemapRule)

lvRemapRules := MainGui.Add("ListView", "x30 y" (contentTop + 144) " w530 h80", ["Device", "From", "To"])
lvRemapRules.ModifyCol(1, 330)
lvRemapRules.ModifyCol(2, 100)
lvRemapRules.ModifyCol(3, 100)
btnRemoveRemapRule := MainGui.Add("Button", "x30 y" (contentTop + 234) " w170 h30", "Remove Selected Rule")
btnRemoveRemapRule.OnEvent("Click", OnRemoveRemapRule)
btnStartRemap := MainGui.Add("Button", "x210 y" (contentTop + 234) " w170 h30", "Start Remapping")
btnStartRemap.OnEvent("Click", OnStartRemapping)
btnStopRemap := MainGui.Add("Button", "x390 y" (contentTop + 234) " w170 h30", "Stop Remapping")
btnStopRemap.OnEvent("Click", OnStopRemapping)

tab.UseTab()

; Everything below is positioned using absolute Y derived from the tab's own
; bottom edge (tabY + tabH), NOT relative "y+N" flow - relative flow after a
; Tab3 control measures from wherever the last tab-page control happened to
; land, which can be well inside the tab's visible rectangle and overlap it.
belowTabY := tabY + tabH + 10

chkAutostart := MainGui.Add("Checkbox", "x15 y" belowTabY, "Run automatically after I log in (background, tray icon)")
chkAutostart.OnEvent("Click", OnAutostartToggle)

svcBoxY := belowTabY + 20
MainGui.Add("GroupBox", "x15 y" svcBoxY " w560 h90", "Step 3 - Protect The Lock/Login Screen Too (Windows Service)")
lblServiceInfo := MainGui.Add("Text", "x30 y" (svcBoxY + 20) " w530", "Runs from boot, before you log in - protects the password screen for BLOCK rules. Remap rules need Windows' desktop, so they only apply after login (via 'Run automatically after I log in' above).")
lblServiceStatus := MainGui.Add("Text", "x30 y" (svcBoxY + 42) " w530", "Service status: checking...")
btnInstallService := MainGui.Add("Button", "x30 y" (svcBoxY + 58) " w170", "Install As Service")
btnInstallService.OnEvent("Click", OnInstallService)
btnUninstallService := MainGui.Add("Button", "x210 y" (svcBoxY + 58) " w170", "Uninstall Service")
btnUninstallService.OnEvent("Click", OnUninstallService)

statusY := svcBoxY + 98
lblStatus := MainGui.Add("Text", "x15 y" statusY " w560", "Ready.")
windowH := statusY + 25

LoadRules()
LoadRemapRules()
RefreshDriverStatus()
RefreshRulesListView()
RefreshRemapRulesListView()
RefreshServiceStatus()
chkAutostart.Value := IsAutostartTaskPresent() ? 1 : 0
MainGui.Show("w595 h" windowH)
return

; ---------------- Driver status / install ----------------
RefreshDriverStatus() {
    global lblDriver
    installed := IsDriverInstalled()
    lblDriver.Text := installed
        ? "Driver status: INSTALLED. If you just installed it, reboot before using Step 2 onward."
        : "Driver status: NOT installed. Click 'Install Driver', then reboot."
}

IsDriverInstalled(&reason := "") {
    kbClass := "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}"
    try {
        val := RegRead(kbClass, "UpperFilters")
    } catch as e {
        reason := "RegRead(UpperFilters) threw: " e.Message
        return false
    }
    if InStr(val, "keyboard") {
        reason := "OK"
        return true
    }
    reason := "UpperFilters = [" val "] (doesn't contain 'keyboard')"
    return false
}

OnInstallDriver(*) {
    global lblStatus
    exePath := A_ScriptDir "\install-interception.exe"
    if !FileExist(exePath) {
        MsgBox("install-interception.exe not found next to this program.", "Error", "Iconx")
        return
    }
    try {
        RunWait('"' exePath '" /install', , "Hide")
    } catch as e {
        MsgBox("Driver install failed: " e.Message, "Install Driver", "Iconx")
        return
    }
    RefreshDriverStatus()
    MsgBox("Driver install command completed. You MUST reboot for it to take effect before using Step 2 onward.", "Install Driver", "Iconi")
}

OnUninstallDriver(*) {
    exePath := A_ScriptDir "\install-interception.exe"
    if !FileExist(exePath) {
        MsgBox("install-interception.exe not found next to this program.", "Error", "Iconx")
        return
    }
    try {
        RunWait('"' exePath '" /uninstall', , "Hide")
    } catch as e {
        MsgBox("Driver uninstall failed: " e.Message, "Uninstall Driver", "Iconx")
        return
    }
    RefreshDriverStatus()
    MsgBox("Driver uninstall command completed. Reboot to finish removing it.", "Uninstall Driver", "Iconi")
}

OnReboot(*) {
    result := MsgBox("This will restart your computer now. Save your work first.`n`nReboot now?", "Reboot", "YesNo Icon!")
    if (result = "Yes")
        Run("shutdown /r /t 5")
}

; ---------------- AHI setup ----------------
TrySetupAHI() {
    global AHI, LastAHIError
    if (AHI != "")
        return true
    ; Retry briefly - right after reboot/login there can be a short window
    ; where the registry entry is written but a re-check a moment later
    ; would already see it, so this rules out pure timing flukes.
    loop 3 {
        if (IsDriverInstalled(&reason)) {
            try {
                AHI := AutoHotInterception()
                return true
            } catch as e {
                AHI := ""
                detail := "Message=[" e.Message "]"
                try detail .= " What=[" e.What "]"
                try detail .= " Extra=[" e.Extra "]"
                try detail .= " Number=[" Format("0x{:X}", e.Number) "]"
                try detail .= " File=[" e.File "] Line=[" e.Line "]"
                LastAHIError := "AutoHotInterception() init failed. " detail
                return false
            }
        }
        LastAHIError := reason
        if (A_Index < 3)
            Sleep(500)
    }
    return false
}

; ---------------- Device list ----------------
OnRefreshKeyboards(*) {
    global lvDevices, DeviceCache, lblStatus
    lvDevices.Delete()
    DeviceCache := Map()
    if (!TrySetupAHI()) {
        MsgBox("Driver isn't installed/active yet. Install it and reboot first.`n`nDetail: " LastAHIError, "Not ready", "Iconx")
        return
    }
    list := AHI.GetDeviceList()
    Loop 10 {
        if (!list.Has(A_Index))
            continue
        dev := list[A_Index]
        row := lvDevices.Add(, dev.id, Format("0x{:04X}", dev.VID), Format("0x{:04X}", dev.PID), dev.Handle)
        DeviceCache[row] := {id: dev.id, vid: dev.VID, pid: dev.PID, handle: dev.Handle}
    }
    lblStatus.Text := "Found " DeviceCache.Count " keyboard(s). Type on the one you want to identify, or select it directly if you know it."
    MsgBox("Found " DeviceCache.Count " keyboard(s) - see the list above.", "Refresh Keyboard List", "Iconi")
}

; ---------------- Key capture (Block tab) ----------------
OnCaptureKey(*) {
    global lvDevices, DeviceCache, lblCapture, AHI, CapturedCode, Capturing, CaptureDevId
    row := lvDevices.GetNext()
    if (!row) {
        MsgBox("Select a keyboard in the list first (click Refresh if the list is empty).", "No selection")
        return
    }
    if (!TrySetupAHI()) {
        MsgBox("Driver isn't installed/active yet.`n`nDetail: " LastAHIError, "Not ready", "Iconx")
        return
    }
    dev := DeviceCache[row]
    CapturedCode := 0
    Capturing := true
    CaptureDevId := dev.id
    ; Move focus off the button - we only observe the key while capturing
    ; (block=false), so it also reaches Windows normally, and Space on a
    ; focused button re-clicks it, restarting this whole capture in a loop.
    lvDevices.Focus()
    lblCapture.Text := "Press the key you want to block now (on that keyboard)..."
    AHI.SubscribeKeyboard(dev.id, false, CaptureCallback.Bind(dev.id))
    SetTimer(() => StopCapture(dev.id), -8000)
}

CaptureCallback(id, code, state) {
    global CapturedCode, Capturing, lblCapture, AHI, CaptureDevId
    if (!Capturing || state != 1)
        return
    CapturedCode := code
    Capturing := false
    CaptureDevId := 0
    keyName := GetKeyName(Format("SC{:x}", code))
    lblCapture.Text := "Captured: " (keyName != "" ? keyName : "?") " (scan code 0x" Format("{:X}", code) "). Click 'Add As Blocked Rule' to save it."
    AHI.UnsubscribeKeyboard(id)
}

StopCapture(id) {
    global Capturing, AHI, lblCapture, CaptureDevId
    if (Capturing) {
        Capturing := false
        CaptureDevId := 0
        try AHI.UnsubscribeKeyboard(id)
        lblCapture.Text := "No key detected within 8 seconds. Try again."
    }
}

; ---------------- Virtual keyboard (for a key that sends no signal at all) ----------------
; A stuck key still fires real keystrokes (often repeatedly), so physical
; capture works fine for it. A dead key sends nothing, so there is no
; keystroke to capture - this lets you pick it by clicking its picture
; instead, using AHK's own key-name-to-scancode table rather than reading a
; press from the hardware.
OnVirtualKeyboardBlock(*) {
    global lvDevices
    if (!lvDevices.GetNext()) {
        MsgBox("Select a keyboard in the list first (click Refresh if the list is empty).", "No selection")
        return
    }
    ShowVirtualKeyboard(VKBlockPicked)
}

VKBlockPicked(code, keyName) {
    global CapturedCode, lblCapture, Capturing, CaptureDevId, AHI
    ; Cancel any in-flight physical capture first - otherwise its 8-second
    ; timeout can fire moments later, see Capturing still true (it was never
    ; cleared since the physical callback never ran), and stomp this result
    ; back to "No key detected".
    if (Capturing) {
        Capturing := false
        if (CaptureDevId)
            try AHI.UnsubscribeKeyboard(CaptureDevId)
        CaptureDevId := 0
    }
    CapturedCode := code
    lblCapture.Text := "Captured: " keyName " (via virtual keyboard, scan code 0x" Format("{:X}", code) "). Click 'Add As Blocked Rule' to save it."
}

OnVirtualKeyboardRemapSource(*) {
    global lvDevices
    if (!lvDevices.GetNext()) {
        MsgBox("Select a keyboard in the list first (click Refresh if the list is empty).", "No selection")
        return
    }
    ShowVirtualKeyboard(VKRemapSourcePicked)
}

VKRemapSourcePicked(code, keyName) {
    global CapturedCode, lblCaptureSource, Capturing, SourceCaptureDevId, AHI
    if (Capturing) {
        Capturing := false
        if (SourceCaptureDevId)
            try AHI.UnsubscribeKeyboard(SourceCaptureDevId)
        SourceCaptureDevId := 0
    }
    CapturedCode := code
    lblCaptureSource.Text := "Captured source: " keyName " (via virtual keyboard, scan code 0x" Format("{:X}", code) ")."
}

; onPick(code, keyName) is called once, with the scan code (matching what
; physical capture would have produced) and the AHK key name, then the
; popup closes itself.
ShowVirtualKeyboard(onPick) {
    vk := Gui("+AlwaysOnTop +ToolWindow", "Virtual Keyboard - Click The Key")
    vk.SetFont("s9")
    vk.OnEvent("Close", (*) => vk.Destroy())
    vk.OnEvent("Escape", (*) => vk.Destroy())

    unit := 34
    rows := [
        [["Esc","Escape",1.5],["F1","F1",1],["F2","F2",1],["F3","F3",1],["F4","F4",1],["F5","F5",1],["F6","F6",1],["F7","F7",1],["F8","F8",1],["F9","F9",1],["F10","F10",1],["F11","F11",1],["F12","F12",1]],
        [["``","``",1],["1","1",1],["2","2",1],["3","3",1],["4","4",1],["5","5",1],["6","6",1],["7","7",1],["8","8",1],["9","9",1],["0","0",1],["-","-",1],["=","=",1],["Backspace","Backspace",2]],
        [["Tab","Tab",1.5],["Q","Q",1],["W","W",1],["E","E",1],["R","R",1],["T","T",1],["Y","Y",1],["U","U",1],["I","I",1],["O","O",1],["P","P",1],["[","[",1],["]","]",1],["\","\",1]],
        [["Caps","CapsLock",1.75],["A","A",1],["S","S",1],["D","D",1],["F","F",1],["G","G",1],["H","H",1],["J","J",1],["K","K",1],["L","L",1],[";",";",1],["'","'",1],["Enter","Enter",2.25]],
        [["Shift","LShift",2.25],["Z","Z",1],["X","X",1],["C","C",1],["V","V",1],["B","B",1],["N","N",1],["M","M",1],[",",",",1],[".",".",1],["/","/",1],["Shift","RShift",2.25]],
        [["Ctrl","LCtrl",1.5],["Win","LWin",1.25],["Alt","LAlt",1.25],["Space","Space",6.25],["Alt","RAlt",1.25],["Win","RWin",1.25],["Menu","AppsKey",1.25],["Ctrl","RCtrl",1.5]]
    ]

    y := 10
    for row in rows {
        x := 10
        for keyDef in row {
            label := keyDef[1], keyName := keyDef[2], w := Round(keyDef[3] * unit) - 2
            btn := vk.Add("Button", "x" x " y" y " w" w " h" (unit - 2), label)
            btn.OnEvent("Click", VKKeyClicked.Bind(keyName, onPick, vk))
            x += Round(keyDef[3] * unit)
        }
        y += unit
    }

    ; Navigation / editing cluster, laid out separately below the main block.
    navRows := [
        [["Insert","Insert",1],["Home","Home",1],["PgUp","PgUp",1]],
        [["Delete","Delete",1],["End","End",1],["PgDn","PgDn",1]]
    ]
    y += 10
    navStartY := y
    for row in navRows {
        x := 10
        for keyDef in row {
            label := keyDef[1], keyName := keyDef[2], w := Round(keyDef[3] * unit) - 2
            btn := vk.Add("Button", "x" x " y" y " w" w " h" (unit - 2), label)
            btn.OnEvent("Click", VKKeyClicked.Bind(keyName, onPick, vk))
            x += Round(keyDef[3] * unit)
        }
        y += unit
    }

    ; Arrow cluster, to the right of the nav cluster.
    arrowX := 10 + Round(3 * unit) + 20
    btnUp := vk.Add("Button", "x" (arrowX + Round(unit)) " y" navStartY " w" (unit - 2) " h" (unit - 2), "Up")
    btnUp.OnEvent("Click", VKKeyClicked.Bind("Up", onPick, vk))
    y2 := navStartY + unit
    btnLeft := vk.Add("Button", "x" arrowX " y" y2 " w" (unit - 2) " h" (unit - 2), "Left")
    btnLeft.OnEvent("Click", VKKeyClicked.Bind("Left", onPick, vk))
    btnDown := vk.Add("Button", "x" (arrowX + Round(unit)) " y" y2 " w" (unit - 2) " h" (unit - 2), "Down")
    btnDown.OnEvent("Click", VKKeyClicked.Bind("Down", onPick, vk))
    btnRight := vk.Add("Button", "x" (arrowX + Round(2 * unit)) " y" y2 " w" (unit - 2) " h" (unit - 2), "Right")
    btnRight.OnEvent("Click", VKKeyClicked.Bind("Right", onPick, vk))

    y += unit + 15
    vk.Add("Text", "x10 y" y " w600", "Click Cancel, or the X, if you don't see the key here - not every key is listed.")
    y += 25
    btnCancel := vk.Add("Button", "x10 y" y " w120 h28", "Cancel")
    btnCancel.OnEvent("Click", (*) => vk.Destroy())

    vk.Show()
}

VKKeyClicked(keyName, onPick, vk, *) {
    code := GetKeySC(keyName)
    vk.Destroy()
    onPick(code, keyName)
}

; ---------------- Block Rules ----------------
OnAddRule(*) {
    global lvDevices, DeviceCache, CapturedCode, Rules, lblCapture
    row := lvDevices.GetNext()
    if (!row || CapturedCode = 0) {
        MsgBox("Select a device and capture a key first.", "Missing info")
        return
    }
    dev := DeviceCache[row]
    keyName := GetKeyName(Format("SC{:x}", CapturedCode))
    Rules.Push({vid: dev.vid, pid: dev.pid, handle: dev.handle, code: CapturedCode, keyname: keyName != "" ? keyName : "?"})
    SaveRules()
    RefreshRulesListView()
    CapturedCode := 0
    lblCapture.Text := "Rule added. Select a device and capture again to add another."
    MsgBox("Blocked rule added.", "Add As Blocked Rule", "Iconi")
}

OnRemoveRule(*) {
    global lvRules, Rules
    row := lvRules.GetNext()
    if (!row) {
        MsgBox("Select a rule to remove.", "No selection")
        return
    }
    Rules.RemoveAt(row)
    SaveRules()
    RefreshRulesListView()
    MsgBox("Rule removed.", "Remove Selected Rule", "Iconi")
}

RefreshRulesListView() {
    global lvRules, Rules
    lvRules.Delete()
    for r in Rules
        lvRules.Add(, r.handle, r.keyname)
}

SaveRules() {
    global RulesFile, Rules
    text := ""
    for r in Rules
        text .= r.vid "|" r.pid "|" r.code "|" r.keyname "|" r.handle "`n"
    if FileExist(RulesFile)
        FileDelete(RulesFile)
    if (text != "")
        FileAppend(text, RulesFile)
}

LoadRules() {
    global RulesFile, Rules
    Rules := []
    if (!FileExist(RulesFile))
        return
    for line in StrSplit(FileRead(RulesFile), "`n", "`r") {
        if (Trim(line) = "")
            continue
        parts := StrSplit(line, "|")
        if (parts.Length >= 5)
            Rules.Push({vid: Integer(parts[1]), pid: Integer(parts[2]), code: Integer(parts[3]), keyname: parts[4], handle: parts[5]})
    }
}

; ---------------- Start / stop blocking ----------------
OnStartBlocking(*) {
    global ActiveSubs, Rules
    StartBlocking()
    if (ActiveSubs.Length > 0)
        MsgBox("Blocking is now ON: " ActiveSubs.Length " of " Rules.Length " rule(s) applied.", "Start Blocking", "Iconi")
    else if (Rules.Length > 0)
        MsgBox("Blocking did NOT start - 0 of " Rules.Length " rule(s) could be applied. The selected device may not currently be connected.", "Start Blocking", "Iconx")
}

StartBlocking() {
    global Rules, ActiveSubs, Blocking, lblStatus, AHI
    if (!TrySetupAHI()) {
        MsgBox("Driver isn't installed/active yet. Install it and reboot first.`n`nDetail: " LastAHIError, "Not ready", "Iconx")
        return
    }
    if (Rules.Length = 0) {
        MsgBox("No block rules configured yet.", "Nothing to block")
        return
    }
    StopBlocking()
    count := 0
    for r in Rules {
        try {
            id := AHI.GetKeyboardIdFromHandle(r.handle)
            AHI.SubscribeKey(id, r.code, true, (state) => "")
            ActiveSubs.Push({id: id, code: r.code})
            count += 1
        }
    }
    Blocking := true
    if IsSet(lblStatus)
        lblStatus.Text := "Blocking active - " count " of " Rules.Length " rule(s) applied."
}

OnStopBlocking(*) {
    StopBlocking()
    if IsSet(lblStatus)
        lblStatus.Text := "Blocking stopped."
    MsgBox("Blocking is now OFF.", "Stop Blocking", "Iconi")
}

StopBlocking() {
    global ActiveSubs, AHI, Blocking
    if (AHI = "")
        return
    for s in ActiveSubs {
        try AHI.UnsubscribeKey(s.id, s.code)
    }
    ActiveSubs := []
    Blocking := false
}

; ---------------- Key capture (Remap tab) ----------------
OnCaptureSourceKey(*) {
    global lvDevices, DeviceCache, lblCaptureSource, AHI, CapturedCode, Capturing, SourceCaptureDevId
    row := lvDevices.GetNext()
    if (!row) {
        MsgBox("Select a keyboard in the list first (click Refresh if the list is empty).", "No selection")
        return
    }
    if (!TrySetupAHI()) {
        MsgBox("Driver isn't installed/active yet.`n`nDetail: " LastAHIError, "Not ready", "Iconx")
        return
    }
    dev := DeviceCache[row]
    CapturedCode := 0
    Capturing := true
    SourceCaptureDevId := dev.id
    lvDevices.Focus()
    lblCaptureSource.Text := "Press the faulty key now (on that keyboard)..."
    AHI.SubscribeKeyboard(dev.id, false, SourceCaptureCallback.Bind(dev.id))
    SetTimer(() => StopSourceCapture(dev.id), -8000)
}

SourceCaptureCallback(id, code, state) {
    global CapturedCode, Capturing, lblCaptureSource, AHI, SourceCaptureDevId
    if (!Capturing || state != 1)
        return
    CapturedCode := code
    Capturing := false
    SourceCaptureDevId := 0
    keyName := GetKeyName(Format("SC{:x}", code))
    lblCaptureSource.Text := "Captured source: " (keyName != "" ? keyName : "?") " (scan code 0x" Format("{:X}", code) ")."
    AHI.UnsubscribeKeyboard(id)
}

StopSourceCapture(id) {
    global Capturing, AHI, lblCaptureSource, SourceCaptureDevId
    if (Capturing) {
        Capturing := false
        SourceCaptureDevId := 0
        try AHI.UnsubscribeKeyboard(id)
        lblCaptureSource.Text := "No key detected within 8 seconds. Try again."
    }
}

; Uses the same device-subscription mechanism as source-key capture (proven
; to correctly catch Space etc.) rather than InputHook, which has a known
; quirk where Space doesn't reliably register as an end-key. Subscribes to
; every currently-listed device at once so it works from any keyboard.
OnCaptureTargetKey(*) {
    global lblCaptureTarget, CapturedTargetKeyName, CapturingTarget, DeviceCache, AHI, lvDevices
    if (!TrySetupAHI()) {
        MsgBox("Driver isn't installed/active yet.`n`nDetail: " LastAHIError, "Not ready", "Iconx")
        return
    }
    if (DeviceCache.Count = 0) {
        MsgBox("Click 'Refresh Keyboard List' first.", "No devices")
        return
    }
    CapturedTargetKeyName := ""
    CapturingTarget := true
    lvDevices.Focus()
    lblCaptureTarget.Text := "Press the key you want it to send instead (any keyboard)..."
    for row, dev in DeviceCache
        AHI.SubscribeKeyboard(dev.id, false, TargetCaptureCallback)
    SetTimer(StopTargetCapture, -8000)
}

TargetCaptureCallback(code, state) {
    global CapturingTarget, CapturedTargetKeyName, lblCaptureTarget, AHI, DeviceCache
    if (!CapturingTarget || state != 1)
        return
    keyName := GetKeyName(Format("SC{:x}", code))
    CapturedTargetKeyName := keyName != "" ? keyName : "?"
    CapturingTarget := false
    lblCaptureTarget.Text := "Will send: " CapturedTargetKeyName
    for row, dev in DeviceCache
        try AHI.UnsubscribeKeyboard(dev.id)
}

StopTargetCapture() {
    global CapturingTarget, AHI, DeviceCache, lblCaptureTarget
    if (CapturingTarget) {
        CapturingTarget := false
        for row, dev in DeviceCache
            try AHI.UnsubscribeKeyboard(dev.id)
        lblCaptureTarget.Text := "No key detected within 8 seconds. Try again."
    }
}

; ---------------- Remap Rules ----------------
OnAddRemapRule(*) {
    global lvDevices, DeviceCache, CapturedCode, CapturedTargetKeyName, RemapRules, lblCaptureSource, lblCaptureTarget
    row := lvDevices.GetNext()
    if (!row || CapturedCode = 0 || CapturedTargetKeyName = "") {
        MsgBox("Select a device, capture a source key, and capture a target key first.", "Missing info")
        return
    }
    dev := DeviceCache[row]
    keyName := GetKeyName(Format("SC{:x}", CapturedCode))
    RemapRules.Push({vid: dev.vid, pid: dev.pid, handle: dev.handle, code: CapturedCode, keyname: keyName != "" ? keyName : "?", targetkey: CapturedTargetKeyName})
    SaveRemapRules()
    RefreshRemapRulesListView()
    CapturedCode := 0
    CapturedTargetKeyName := ""
    lblCaptureSource.Text := "Rule added. Select a device and capture again to add another."
    lblCaptureTarget.Text := "Click here, then press any key/key combo - it can be on any keyboard."
    MsgBox("Remap rule added.", "Add As Remap Rule", "Iconi")
}

OnRemoveRemapRule(*) {
    global lvRemapRules, RemapRules
    row := lvRemapRules.GetNext()
    if (!row) {
        MsgBox("Select a rule to remove.", "No selection")
        return
    }
    RemapRules.RemoveAt(row)
    SaveRemapRules()
    RefreshRemapRulesListView()
    MsgBox("Rule removed.", "Remove Selected Rule", "Iconi")
}

RefreshRemapRulesListView() {
    global lvRemapRules, RemapRules
    lvRemapRules.Delete()
    for r in RemapRules
        lvRemapRules.Add(, r.handle, r.keyname, r.targetkey)
}

SaveRemapRules() {
    global RemapRulesFile, RemapRules
    text := ""
    for r in RemapRules
        text .= r.vid "|" r.pid "|" r.code "|" r.keyname "|" r.handle "|" r.targetkey "`n"
    if FileExist(RemapRulesFile)
        FileDelete(RemapRulesFile)
    if (text != "")
        FileAppend(text, RemapRulesFile)
}

LoadRemapRules() {
    global RemapRulesFile, RemapRules
    RemapRules := []
    if (!FileExist(RemapRulesFile))
        return
    for line in StrSplit(FileRead(RemapRulesFile), "`n", "`r") {
        if (Trim(line) = "")
            continue
        parts := StrSplit(line, "|")
        if (parts.Length >= 6)
            RemapRules.Push({vid: Integer(parts[1]), pid: Integer(parts[2]), code: Integer(parts[3]), keyname: parts[4], handle: parts[5], targetkey: parts[6]})
    }
}

; ---------------- Start / stop remapping ----------------
OnStartRemapping(*) {
    global ActiveRemapSubs, RemapRules
    StartRemapping()
    if (ActiveRemapSubs.Length > 0)
        MsgBox("Remapping is now ON: " ActiveRemapSubs.Length " of " RemapRules.Length " rule(s) applied.", "Start Remapping", "Iconi")
    else if (RemapRules.Length > 0)
        MsgBox("Remapping did NOT start - 0 of " RemapRules.Length " rule(s) could be applied. The selected device may not currently be connected.", "Start Remapping", "Iconx")
}

StartRemapping() {
    global RemapRules, ActiveRemapSubs, Remapping, lblStatus, AHI
    if (!TrySetupAHI()) {
        if (RemapRules.Length > 0)
            MsgBox("Driver isn't installed/active yet. Install it and reboot first.`n`nDetail: " LastAHIError, "Not ready", "Iconx")
        return
    }
    if (RemapRules.Length = 0) {
        return
    }
    StopRemapping()
    count := 0
    for r in RemapRules {
        try {
            id := AHI.GetKeyboardIdFromHandle(r.handle)
            AHI.SubscribeKey(id, r.code, true, RemapCallback.Bind(r.targetkey))
            ActiveRemapSubs.Push({id: id, code: r.code})
            count += 1
        }
    }
    Remapping := true
    if IsSet(lblStatus)
        lblStatus.Text := "Remapping active - " count " of " RemapRules.Length " rule(s) applied."
}

RemapCallback(targetKeyName, state) {
    if (state = 1)
        Send("{" targetKeyName " down}")
    else
        Send("{" targetKeyName " up}")
}

OnStopRemapping(*) {
    StopRemapping()
    if IsSet(lblStatus)
        lblStatus.Text := "Remapping stopped."
    MsgBox("Remapping is now OFF.", "Stop Remapping", "Iconi")
}

StopRemapping() {
    global ActiveRemapSubs, AHI, Remapping
    if (AHI = "")
        return
    for s in ActiveRemapSubs {
        try AHI.UnsubscribeKey(s.id, s.code)
    }
    ActiveRemapSubs := []
    Remapping := false
}

; ---------------- Autostart (Scheduled Task, so no UAC prompt at each login) ----------------
OnAutostartToggle(ctrl, *) {
    exePath := A_ScriptFullPath
    if (ctrl.Value) {
        RunWait('schtasks /create /tn "KeyboardGuard" /tr "\"' exePath '\" /auto" /sc onlogon /rl highest /f', , "Hide")
        MsgBox("KeyboardGuard will now start automatically after you log in.", "Run Automatically After Login", "Iconi")
    } else {
        RunWait('schtasks /delete /tn "KeyboardGuard" /f', , "Hide")
        MsgBox("Autostart after login has been turned off.", "Run Automatically After Login", "Iconi")
    }
}

IsAutostartTaskPresent() {
    exitCode := RunWait(A_ComSpec ' /c schtasks /query /tn "KeyboardGuard" >nul 2>&1', , "Hide")
    return exitCode = 0
}

; ---------------- Windows Service (protects the lock/login screen) ----------------
OnInstallService(*) {
    global Rules, RemapRules
    nssmPath := A_ScriptDir "\nssm.exe"
    if !FileExist(nssmPath) {
        MsgBox("nssm.exe not found next to this program.", "Error", "Iconx")
        return
    }
    if (!IsDriverInstalled()) {
        MsgBox("Install the Interception driver first (Step 1) and reboot.", "Driver required", "Iconx")
        return
    }
    if (Rules.Length = 0 && RemapRules.Length = 0) {
        MsgBox("Add at least one block or remap rule first.", "No rules yet")
        return
    }
    exePath := A_ScriptFullPath
    batPath := A_Temp "\kg_install_service.bat"
    batText := ""
        . '"' nssmPath '" install KeyboardGuard "' exePath '" /auto' "`r`n"
        . '"' nssmPath '" set KeyboardGuard Start SERVICE_AUTO_START' "`r`n"
        . '"' nssmPath '" set KeyboardGuard AppDirectory "' A_ScriptDir '"' "`r`n"
        . '"' nssmPath '" set KeyboardGuard DisplayName "KeyboardGuard"' "`r`n"
        . '"' nssmPath '" start KeyboardGuard' "`r`n"
    if FileExist(batPath)
        FileDelete(batPath)
    FileAppend(batText, batPath)
    try {
        RunWait('"' batPath '"', , "Hide")
    } catch as e {
        MsgBox("Service install failed: " e.Message, "Install Service", "Iconx")
        return
    }
    RefreshServiceStatus()
    MsgBox("Service install attempted - check the status line above.`n`nIt should be RUNNING now, and will keep protecting the login screen on every future boot, even before you log in.", "Install Service", "Iconi")
}

OnUninstallService(*) {
    nssmPath := A_ScriptDir "\nssm.exe"
    if !FileExist(nssmPath) {
        MsgBox("nssm.exe not found next to this program.", "Error", "Iconx")
        return
    }
    batPath := A_Temp "\kg_remove_service.bat"
    batText := ""
        . '"' nssmPath '" stop KeyboardGuard' "`r`n"
        . '"' nssmPath '" remove KeyboardGuard confirm' "`r`n"
    if FileExist(batPath)
        FileDelete(batPath)
    FileAppend(batText, batPath)
    try {
        RunWait('"' batPath '"', , "Hide")
    } catch as e {
        MsgBox("Service removal failed: " e.Message, "Uninstall Service", "Iconx")
        return
    }
    RefreshServiceStatus()
    MsgBox("Service removal attempted.", "Uninstall Service", "Iconi")
}

RefreshServiceStatus() {
    global lblServiceStatus
    if !IsSet(lblServiceStatus)
        return
    lblServiceStatus.Text := "Service status: " GetServiceState()
}

GetServiceState() {
    outFile := A_Temp "\kg_svc_state.txt"
    try {
        RunWait(A_ComSpec ' /c sc query KeyboardGuard > "' outFile '" 2>&1', , "Hide")
        text := FileExist(outFile) ? FileRead(outFile) : ""
    } catch {
        return "unknown"
    }
    if InStr(text, "does not exist") || InStr(text, "1060")
        return "NOT INSTALLED"
    if InStr(text, "RUNNING")
        return "RUNNING (protecting login screen)"
    if InStr(text, "STOPPED")
        return "installed but STOPPED"
    return "installed (unknown state)"
}

; ---------------- Tray (used in /auto silent mode) ----------------
TraySetup() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Stop All", (*) => (StopBlocking(), StopRemapping()))
    A_TrayMenu.Add("Start All", (*) => (StartBlocking(), StartRemapping()))
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    TrayTip("KeyboardGuard", "Running in background, protecting configured key(s).")
}
