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
        if !FileExist("Lib\x64\interception.dll")
            FileInstall("Lib\x64\interception.dll", "Lib\x64\interception.dll", 1)
        if !FileExist("install-interception.exe")
            FileInstall("install-interception.exe", "install-interception.exe", 1)
        if !FileExist("nssm.exe")
            FileInstall("nssm.exe", "nssm.exe", 1)
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
CapturedTargetKeyName := ""
CapturingTarget := false
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

TryStartInAutoMode() {
    global AHI
    if (AHI != "")
        return
    if (TrySetupAHI()) {
        StartBlocking()
        StartRemapping()
        SetTimer(TryStartInAutoMode, 0)
    }
}

; ---------------- GUI ----------------
MainGui := Gui("", "KeyboardGuard")
MainGui.SetFont("s10")
MainGui.OnEvent("Close", (*) => ExitApp())

MainGui.Add("GroupBox", "x15 y15 w560 h110", "Step 1 - Interception Driver")
lblDriver := MainGui.Add("Text", "x30 y40 w530", "Checking driver status...")
btnInstallDriver := MainGui.Add("Button", "x30 y75 w170", "Install Driver")
btnInstallDriver.OnEvent("Click", OnInstallDriver)
btnUninstallDriver := MainGui.Add("Button", "x210 y75 w170", "Uninstall Driver")
btnUninstallDriver.OnEvent("Click", OnUninstallDriver)
btnReboot := MainGui.Add("Button", "x390 y75 w170", "Reboot Now")
btnReboot.OnEvent("Click", OnReboot)

MainGui.Add("GroupBox", "x15 y135 w560 h115", "Step 2 - Choose Keyboard")
btnRefresh := MainGui.Add("Button", "x30 y160 w170", "Refresh Keyboard List")
btnRefresh.OnEvent("Click", OnRefreshKeyboards)
lvDevices := MainGui.Add("ListView", "x210 y157 w350 h85", ["ID", "VID", "PID", "Handle"])
lvDevices.ModifyCol(1, 30)
lvDevices.ModifyCol(2, 70)
lvDevices.ModifyCol(3, 70)
lvDevices.ModifyCol(4, 165)

tabY := 260
tabH := 330
tab := MainGui.Add("Tab3", "x15 y" tabY " w560 h" tabH, ["Block a Key", "Remap a Key"])

; ---- Tab 1: Block a Key ----
tab.UseTab(1)
btnCapture := MainGui.Add("Button", "xs+15 ys+15 w170", "Capture Key From Selected")
btnCapture.OnEvent("Click", OnCaptureKey)
lblCapture := MainGui.Add("Text", "x+10 yp+5 w350", "Select a device above, click Capture, then press the key.")

btnAddRule := MainGui.Add("Button", "xs+15 y+15 w170", "Add As Blocked Rule")
btnAddRule.OnEvent("Click", OnAddRule)

lvRules := MainGui.Add("ListView", "xs+15 y+15 w530 h110", ["Device", "Key Blocked"])
lvRules.ModifyCol(1, 430)
lvRules.ModifyCol(2, 100)
btnRemoveRule := MainGui.Add("Button", "xs+15 y+10 w170", "Remove Selected Rule")
btnRemoveRule.OnEvent("Click", OnRemoveRule)
btnStart := MainGui.Add("Button", "x+10 w170", "Start Blocking")
btnStart.OnEvent("Click", OnStartBlocking)
btnStop := MainGui.Add("Button", "x+10 w170", "Stop Blocking")
btnStop.OnEvent("Click", OnStopBlocking)

; ---- Tab 2: Remap a Key ----
tab.UseTab(2)
btnCaptureSource := MainGui.Add("Button", "xs+15 ys+15 w170", "Capture Source Key")
btnCaptureSource.OnEvent("Click", OnCaptureSourceKey)
lblCaptureSource := MainGui.Add("Text", "x+10 yp+5 w350", "Select a device above, click here, then press the faulty key.")

btnCaptureTarget := MainGui.Add("Button", "xs+15 y+12 w170", "Capture Key To Send Instead")
btnCaptureTarget.OnEvent("Click", OnCaptureTargetKey)
lblCaptureTarget := MainGui.Add("Text", "x+10 yp+5 w350", "Click here, then press any key/key combo - it can be on any keyboard.")

btnAddRemapRule := MainGui.Add("Button", "xs+15 y+15 w170", "Add As Remap Rule")
btnAddRemapRule.OnEvent("Click", OnAddRemapRule)

lvRemapRules := MainGui.Add("ListView", "xs+15 y+15 w530 h80", ["Device", "From", "To"])
lvRemapRules.ModifyCol(1, 330)
lvRemapRules.ModifyCol(2, 100)
lvRemapRules.ModifyCol(3, 100)
btnRemoveRemapRule := MainGui.Add("Button", "xs+15 y+10 w170", "Remove Selected Rule")
btnRemoveRemapRule.OnEvent("Click", OnRemoveRemapRule)
btnStartRemap := MainGui.Add("Button", "x+10 w170", "Start Remapping")
btnStartRemap.OnEvent("Click", OnStartRemapping)
btnStopRemap := MainGui.Add("Button", "x+10 w170", "Stop Remapping")
btnStopRemap.OnEvent("Click", OnStopRemapping)

tab.UseTab()

; Everything below is positioned using absolute Y derived from the tab's own
; bottom edge (tabY + tabH), NOT relative "y+N" flow - relative flow after a
; Tab3 control measures from wherever the last tab-page control happened to
; land, which can be well inside the tab's visible rectangle and overlap it.
belowTabY := tabY + tabH + 15

chkAutostart := MainGui.Add("Checkbox", "x15 y" belowTabY, "Run automatically after I log in (background, tray icon)")
chkAutostart.OnEvent("Click", OnAutostartToggle)

svcBoxY := belowTabY + 25
MainGui.Add("GroupBox", "x15 y" svcBoxY " w560 h95", "Step 3 - Protect The Lock/Login Screen Too (Windows Service)")
lblServiceInfo := MainGui.Add("Text", "x30 y" (svcBoxY + 22) " w530", "Runs from boot, before you log in, so blocked/remapped keys work even on the password screen. Needs Step 1 driver + at least one rule above.")
lblServiceStatus := MainGui.Add("Text", "x30 y" (svcBoxY + 44) " w530", "Service status: checking...")
btnInstallService := MainGui.Add("Button", "x30 y" (svcBoxY + 62) " w170", "Install As Service")
btnInstallService.OnEvent("Click", OnInstallService)
btnUninstallService := MainGui.Add("Button", "x210 y" (svcBoxY + 62) " w170", "Uninstall Service")
btnUninstallService.OnEvent("Click", OnUninstallService)

statusY := svcBoxY + 110
lblStatus := MainGui.Add("Text", "x15 y" statusY " w560", "Ready.")
windowH := statusY + 30

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
                LastAHIError := "AutoHotInterception() init failed: " e.Message
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
    global lvDevices, DeviceCache, lblCapture, AHI, CapturedCode, Capturing
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
    lblCapture.Text := "Press the key you want to block now (on that keyboard)..."
    AHI.SubscribeKeyboard(dev.id, false, CaptureCallback.Bind(dev.id))
    SetTimer(() => StopCapture(dev.id), -8000)
}

CaptureCallback(id, code, state) {
    global CapturedCode, Capturing, lblCapture, AHI
    if (!Capturing || state != 1)
        return
    CapturedCode := code
    Capturing := false
    keyName := GetKeyName(Format("SC{:x}", code))
    lblCapture.Text := "Captured: " (keyName != "" ? keyName : "?") " (scan code 0x" Format("{:X}", code) "). Click 'Add As Blocked Rule' to save it."
    AHI.UnsubscribeKeyboard(id)
}

StopCapture(id) {
    global Capturing, AHI, lblCapture
    if (Capturing) {
        Capturing := false
        try AHI.UnsubscribeKeyboard(id)
        lblCapture.Text := "No key detected within 8 seconds. Try again."
    }
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
    global lvDevices, DeviceCache, lblCaptureSource, AHI, CapturedCode, Capturing
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
    lblCaptureSource.Text := "Press the faulty key now (on that keyboard)..."
    AHI.SubscribeKeyboard(dev.id, false, SourceCaptureCallback.Bind(dev.id))
    SetTimer(() => StopSourceCapture(dev.id), -8000)
}

SourceCaptureCallback(id, code, state) {
    global CapturedCode, Capturing, lblCaptureSource, AHI
    if (!Capturing || state != 1)
        return
    CapturedCode := code
    Capturing := false
    keyName := GetKeyName(Format("SC{:x}", code))
    lblCaptureSource.Text := "Captured source: " (keyName != "" ? keyName : "?") " (scan code 0x" Format("{:X}", code) ")."
    AHI.UnsubscribeKeyboard(id)
}

StopSourceCapture(id) {
    global Capturing, AHI, lblCaptureSource
    if (Capturing) {
        Capturing := false
        try AHI.UnsubscribeKeyboard(id)
        lblCaptureSource.Text := "No key detected within 8 seconds. Try again."
    }
}

OnCaptureTargetKey(*) {
    global lblCaptureTarget, CapturedTargetKeyName, CapturingTarget
    CapturedTargetKeyName := ""
    CapturingTarget := true
    lblCaptureTarget.Text := "Press the key/combo you want it to send instead..."
    ih := InputHook("L0 T8")
    ih.KeyOpt("{All}", "E")
    ih.Start()
    ih.Wait()
    CapturingTarget := false
    if (ih.EndReason = "EndKey" && ih.EndKey != "") {
        CapturedTargetKeyName := ih.EndKey
        lblCaptureTarget.Text := "Will send: " CapturedTargetKeyName
    } else {
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
