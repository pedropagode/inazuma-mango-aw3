#Requires AutoHotkey v2.0
#SingleInstance Force

; ── Boot ──────────────────────────────────────────────────────────────────────
; Schedule the first run using the saved interval, then let AutoRamTrim()
; reschedule itself every cycle so GUI changes to CD minutes take effect.
ScheduleTimer()
return

; ── Read interval from config and (re)schedule the timer ──────────────────────
ScheduleTimer() {
    global
    iniFile   := A_ScriptDir . "\ram_trim_config.ini"
    rawVal    := IniRead(iniFile, "Settings", "IntervalMinutes", 6)
    intervalMs := Integer(rawVal) * 60000
    if (intervalMs < 120000)
        intervalMs := 120000
    if (intervalMs > 900000)
        intervalMs := 900000
    ; Delete any existing timer before creating a new one with the updated period.
    ; Without this, SetTimer only changes the period on the NEXT fire — the
    ; current countdown keeps running with the old value.
    SetTimer(AutoRamTrim, 0)
    SetTimer(AutoRamTrim, intervalMs)
}

; ── Trim cycle ─────────────────────────────────────────────────────────────────
AutoRamTrim() {
    ; Re-read config every cycle so GUI changes to CD minutes take effect
    ; without requiring an AHK restart.
    ScheduleTimer()

    ; ── SESSION ISOLATION ────────────────────────────────────────────────────
    ; Only trim Roblox processes that belong to the SAME Windows session as
    ; this script. Prevents touching other users' Roblox in RDP/multi-user
    ; environments (mirrors the session-aware fixes in lobby.py).
    myPid := DllCall("GetCurrentProcessId", "UInt")
    mySession := 0
    DllCall("ProcessIdToSessionId", "UInt", myPid, "UInt*", &mySession)

    robloxList := WinGetList("ahk_exe RobloxPlayerBeta.exe")
    if (robloxList.Length = 0)
        return

    totalSavedBytes := 0

    for hwnd in robloxList {
        pid := WinGetPID("ahk_id " . hwnd)

        ; Verifica se o processo pertence à mesma sessão Windows
        procSession := 0
        DllCall("ProcessIdToSessionId", "UInt", pid, "UInt*", &procSession)
        if (procSession != mySession)
            continue   ; outro usuário RDP — ignora

        hProcess := DllCall("OpenProcess", "UInt", 0x1F0FFF, "Int", 0, "UInt", pid, "Ptr")
        if (!hProcess)
            continue

        ; Read WorkingSetSize BEFORE trim
        ; PROCESS_MEMORY_COUNTERS (72 bytes, 64-bit): WorkingSetSize at offset 16
        pmc := Buffer(72, 0)
        NumPut("UInt", 72, pmc, 0)
        DllCall("psapi.dll\GetProcessMemoryInfo", "Ptr", hProcess, "Ptr", pmc, "UInt", 72)
        wssBefore := NumGet(pmc, 16, "UInt64")

        DllCall("psapi.dll\EmptyWorkingSet", "Ptr", hProcess)

        ; Read WorkingSetSize AFTER trim
        pmc2 := Buffer(72, 0)
        NumPut("UInt", 72, pmc2, 0)
        DllCall("psapi.dll\GetProcessMemoryInfo", "Ptr", hProcess, "Ptr", pmc2, "UInt", 72)
        wssAfter := NumGet(pmc2, 16, "UInt64")

        DllCall("CloseHandle", "Ptr", hProcess)

        saved := wssBefore - wssAfter
        if (saved > 0)
            totalSavedBytes += saved
    }

    ; Convert to MB and write result file for the GUI to read
    savedMB    := totalSavedBytes / 1048576.0
    resultFile := A_ScriptDir . "\ram_trim_result.ini"
    IniWrite(savedMB, resultFile, "Result", "SavedMB")
}
