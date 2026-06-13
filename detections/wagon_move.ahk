#Requires AutoHotkey v2.0
#SingleInstance Force
#Include Gdip_All.ahk
#Include OCR.ahk

; ─────────────────────────────────────────────────────────────────────────────
;  wagon_move.ahk  —  chamado pelo escort.py
;
;  Lê wagon_move.ini para:
;    [Config]
;    ColorHex=0xCDE3FE   ; cor do wagon (igual ao nó #8 do FlowWhiteboard)
;    Tolerance=0         ; tolerância da cor
;    SignalFile=         ; caminho do wagon_done.ini (padrão: mesmo dir)
;
;  Fluxo SIMPLIFICADO (idêntico ao SpecialMovementFlow do FlowWhiteboard):
;    1. Zoom out total
;    2. PixelSearch loop (cor) → a cada 5 misses: zoom out + gira Left 200ms
;       → overlay "DETECTED" aparece NA TELA sobre o pixel encontrado
;    3. Centraliza câmera (pulsa Left/Right até errX ≤ 15px)
;    4. W × 3 s → W up → stop
;    5. W × 350 ms → W up → stop
;    6. Escreve wagon_done.ini e ExitApp
; ─────────────────────────────────────────────────────────────────────────────

Persistent()
SetWinDelay(-1)
CoordMode("Mouse",  "Screen")
CoordMode("Pixel",  "Screen")
CoordMode("ToolTip","Screen")
DetectHiddenWindows(true)
SendMode("Event")
SetKeyDelay(20, 20)
SetMouseDelay(10)

try DllCall("User32\SetProcessDpiAwarenessContext", "Ptr", -4, "Int")
catch {
    try DllCall("User32\SetProcessDPIAware")
}

; Gdip é necessário para o OCR.ahk funcionar internamente
global __gdipToken := Gdip_Startup()
OnExit(_WagonOnExit)
_WagonOnExit(*) {
    try Gdip_Shutdown(__gdipToken)
}

; ── globals (nomes idênticos ao FlowWhiteboard para reuso direto) ─────────────
global Running              := false
global specialMarkerGui     := ""
global specialMarkerCurX    := 0
global specialMarkerCurY    := 0
global specialMarkerTgtX    := 0
global specialMarkerTgtY    := 0
global specialMarkerW       := 86
global specialMarkerH       := 24
global statusOverlayGui     := ""
global statusOverlayText    := ""
global StatusLastText       := ""
global StatusOverlaySuppressed := false

; ── Lê configuração ───────────────────────────────────────────────────────────
_CfgFile := A_ScriptDir "\wagon_move.ini"

_ColorHex   := Trim(IniRead(_CfgFile, "Config", "ColorHex",   "0xCDE3FE"))
_Tolerance  := Integer(Trim(IniRead(_CfgFile, "Config", "Tolerance",  "0")))
_SignalFile := Trim(IniRead(_CfgFile, "Config", "SignalFile", ""))
if (_SignalFile = "")
    _SignalFile := A_ScriptDir "\wagon_done.ini"

; Monta um objeto-nó mínimo igual ao NodeData do FlowWhiteboard
_node := {
    colorHex:  _ColorHex,
    tolerance: _Tolerance,
    id:        0
}

; ─────────────────────────────────────────────────────────────────────────────
;  STATUS OVERLAY  (fora do Roblox — cópia exata do FlowWhiteboard)
; ─────────────────────────────────────────────────────────────────────────────
CreateStatusOverlayGui() {
    global statusOverlayGui, statusOverlayText
    statusOverlayGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20", "Wagon Move Status")
    statusOverlayGui.BackColor := "202020"
    statusOverlayGui.MarginX := 6
    statusOverlayGui.MarginY := 2
    statusOverlayGui.SetFont("s8 cFFFFFF", "Segoe UI")
    statusOverlayText := statusOverlayGui.AddText("w430 h22 +0x200", "")
    statusOverlayGui.Hide()
}

ShowStatusOverlay(text := "") {
    global statusOverlayGui, statusOverlayText, StatusOverlaySuppressed, Running, StatusLastText
    if (!Running || StatusOverlaySuppressed)
        return
    if (text = "")
        text := StatusLastText
    if (text = "")
        return
    try {
        statusOverlayText.Value := StrLen(text) > 120 ? SubStr(text, 1, 117) "..." : text
        PositionStatusOverlay()
    }
}

PositionStatusOverlay() {
    global statusOverlayGui
    w := 444, h := 26
    x := 8, y := 8
    ; Fica acima do Roblox — exatamente igual ao FlowWhiteboard
    if GetRobloxClientRect(&rx, &ry, &rw, &rh) {
        x := rx
        y := ry - h - 6
        if (y < 0)
            y := ry + rh + 6
        if (y + h > A_ScreenHeight)
            y := Max(0, ry - h - 6)
        if (x + w > A_ScreenWidth)
            x := Max(0, A_ScreenWidth - w - 4)
    }
    try statusOverlayGui.Show("x" Round(x) " y" Round(y) " w" w " h" h " NoActivate")
}

HideStatusOverlay() {
    global statusOverlayGui
    ToolTip()
    try statusOverlayGui.Hide()
}

; SetStatus — nome idêntico ao FlowWhiteboard
SetStatus(text) {
    global StatusLastText, Running
    StatusLastText := text
    ToolTip()
    if Running
        ShowStatusOverlay(text)
    else
        HideStatusOverlay()
}

; ─────────────────────────────────────────────────────────────────────────────
;  BeginScreenRead / EndScreenRead  (cópia exata do FlowWhiteboard)
;  Esconde o overlay 20ms antes de qualquer PixelSearch/OCR
; ─────────────────────────────────────────────────────────────────────────────
BeginScreenRead() {
    global StatusOverlaySuppressed
    StatusOverlaySuppressed := true
    HideStatusOverlay()
    Sleep(20)
}

EndScreenRead() {
    global StatusOverlaySuppressed, Running, StatusLastText
    StatusOverlaySuppressed := false
    if (Running && StatusLastText != "")
        ShowStatusOverlay(StatusLastText)
}

ShowSpecialMarker(x, y) {
    global specialMarkerGui, specialMarkerCurX, specialMarkerCurY
    global specialMarkerTgtX, specialMarkerTgtY, specialMarkerW, specialMarkerH

    w := specialMarkerW, h := specialMarkerH, accent := 4
    tx := x - w // 2
    ty := y + 14

    specialMarkerTgtX := tx
    specialMarkerTgtY := ty

    ; ── Já existe: só atualiza o alvo — a transição suave é feita pelo timer ──
    if (specialMarkerGui != "") {
        SetTimer(_AnimateSpecialMarker, 15)
        return
    }

    ; ── Primeira aparição: cria já na posição final, sem animação ─────────────
    specialMarkerGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20")
    specialMarkerGui.BackColor := "17191D"
    specialMarkerGui.MarginX := 0
    specialMarkerGui.MarginY := 0

    ; barra de destaque verde à esquerda
    accentCtrl := specialMarkerGui.AddText("x0 y0 w" accent " h" h)
    accentCtrl.Opt("Background4ADE80")

    ; label centralizado verticalmente
    specialMarkerGui.SetFont("s8 cE5FFF0 Bold", "Segoe UI")
    specialMarkerGui.AddText("x" accent " y0 w" (w - accent) " h" h " +Center 0x200", "DETECTED")

    specialMarkerGui.Show("x" tx " y" ty " w" w " h" h " NoActivate")

    ; cantos arredondados
    try {
        hRgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1, "Int", 8, "Int", 8, "Ptr")
        DllCall("SetWindowRgn", "Ptr", specialMarkerGui.Hwnd, "Ptr", hRgn, "Int", true)
    }

    WinSetTransparent(235, "ahk_id " specialMarkerGui.Hwnd)

    specialMarkerCurX := tx
    specialMarkerCurY := ty
}

; ─────────────────────────────────────────────────────────────────────────────
;  _AnimateSpecialMarker — transição suave (ease-out) entre a posição atual
;  e a posição alvo do marcador "DETECTED". Roda a ~66fps até chegar perto
;  do destino, então para o timer sozinho.
; ─────────────────────────────────────────────────────────────────────────────
_AnimateSpecialMarker() {
    global specialMarkerGui, specialMarkerCurX, specialMarkerCurY
    global specialMarkerTgtX, specialMarkerTgtY, specialMarkerW, specialMarkerH

    if (specialMarkerGui = "") {
        SetTimer(_AnimateSpecialMarker, 0)
        return
    }

    dx := specialMarkerTgtX - specialMarkerCurX
    dy := specialMarkerTgtY - specialMarkerCurY

    if (Abs(dx) <= 1 && Abs(dy) <= 1) {
        specialMarkerCurX := specialMarkerTgtX
        specialMarkerCurY := specialMarkerTgtY
        try specialMarkerGui.Show("x" Round(specialMarkerCurX) " y" Round(specialMarkerCurY) " w" specialMarkerW " h" specialMarkerH " NoActivate")
        SetTimer(_AnimateSpecialMarker, 0)
        return
    }

    ; ease-out: percorre 35% da distância restante a cada frame
    specialMarkerCurX += dx * 0.35
    specialMarkerCurY += dy * 0.35

    try specialMarkerGui.Show("x" Round(specialMarkerCurX) " y" Round(specialMarkerCurY) " w" specialMarkerW " h" specialMarkerH " NoActivate")
}

HideSpecialMarker() {
    global specialMarkerGui
    SetTimer(_AnimateSpecialMarker, 0)
    try specialMarkerGui.Destroy()
    specialMarkerGui := ""
}

; ─────────────────────────────────────────────────────────────────────────────
;  HELPERS DE JANELA  (cópia exata do FlowWhiteboard)
; ─────────────────────────────────────────────────────────────────────────────
GetRobloxHwnd() {
    hwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
    if (!hwnd)
        hwnd := WinExist("Roblox")
    return hwnd ? hwnd : 0
}

ActivateRoblox() {
    hwnd := GetRobloxHwnd()
    if (!hwnd)
        throw Error("Roblox window not found.")
    WinActivate("ahk_id " hwnd)
    Sleep(250)
}

GetRobloxClientRect(&x, &y, &w, &h) {
    hwnd := GetRobloxHwnd()
    if (!hwnd)
        return false
    rect := Buffer(16, 0)
    pt   := Buffer(8,  0)
    try {
        if !DllCall("GetClientRect",  "Ptr", hwnd, "Ptr", rect, "Int")
            throw Error("GetClientRect failed")
        if !DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", pt,   "Int")
            throw Error("ClientToScreen failed")
        x := NumGet(pt,    0, "Int")
        y := NumGet(pt,    4, "Int")
        w := NumGet(rect,  8, "Int") - NumGet(rect, 0, "Int")
        h := NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int")
        return (w > 0 && h > 0)
    } catch {
        try {
            WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)
            return (w > 0 && h > 0)
        } catch {
            try {
                WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
                return (w > 0 && h > 0)
            } catch {
                return false
            }
        }
    }
}

RGBtoBGR(rgb) {
    r := (rgb >> 16) & 255
    g := (rgb >> 8)  & 255
    b := rgb & 255
    return (b << 16) | (g << 8) | r
}

; ─────────────────────────────────────────────────────────────────────────────
;  NormalizeHex  (cópia exata do FlowWhiteboard)
; ─────────────────────────────────────────────────────────────────────────────
NormalizeHex(hex, withPrefix := true) {
    h := Trim(hex)
    h := RegExReplace(h, "i)^#",  "")
    h := RegExReplace(h, "i)^0x", "")
    h := RegExReplace(h, "\s",    "")
    if !RegExMatch(h, "i)^[0-9a-f]{6}$")
        return ""
    h := StrUpper(h)
    return withPrefix ? "0x" h : h
}

; ─────────────────────────────────────────────────────────────────────────────
;  SpecialColorNear  (cópia exata)
; ─────────────────────────────────────────────────────────────────────────────
SpecialColorNear(c1, c2, tol) {
    r1 := (c1 >> 16) & 255, g1 := (c1 >> 8) & 255, b1 := c1 & 255
    r2 := (c2 >> 16) & 255, g2 := (c2 >> 8) & 255, b2 := c2 & 255
    return (Abs(r1-r2) <= tol && Abs(g1-g2) <= tol && Abs(b1-b2) <= tol)
}

; ─────────────────────────────────────────────────────────────────────────────
;  SpecialFindTargetColor  (cópia exata do FlowWhiteboard)
;  Busca a cor do wagon em todo o cliente Roblox via PixelSearch
; ─────────────────────────────────────────────────────────────────────────────
SpecialFindTargetColor(node, &fx, &fy, fastOnly := true) {
    HideSpecialMarker()
    BeginScreenRead()
    try {
        if !GetRobloxClientRect(&x, &y, &w, &h) {
            x := 0, y := 0, w := A_ScreenWidth, h := A_ScreenHeight
        }
        x1 := Round(x), y1 := Round(y), x2 := Round(x + w - 1), y2 := Round(y + h - 1)

        hex := NormalizeHex(node.colorHex, false)
        if (hex = "")
            return false
        tol      := Round(Number(node.tolerance))
        colorRGB := Integer("0x" hex)
        colorBGR := RGBtoBGR(colorRGB)

        try {
            if PixelSearch(&fx, &fy, x1, y1, x2, y2, colorRGB, tol)
                return true
        } catch {
        }
        try {
            if PixelSearch(&fx, &fy, x1, y1, x2, y2, colorBGR, tol)
                return true
        } catch {
        }

        if fastOnly
            return false

        ; Slow fallback — varredura por step
        step := 4
        yy := y1
        while (yy <= y2) {
            xx := x1
            while (xx <= x2) {
                try c := PixelGetColor(xx, yy, "RGB")
                catch {
                    xx += step
                    continue
                }
                if SpecialColorNear(c, colorRGB, tol) {
                    fx := xx, fy := yy
                    return true
                }
                xx += step
            }
            yy += step
        }
        return false
    } finally {
        EndScreenRead()
    }
}

; ─────────────────────────────────────────────────────────────────────────────
;  SpecialCheckStop  (cópia exata — verifica Running global)
; ─────────────────────────────────────────────────────────────────────────────
SpecialCheckStop(throwOnStop := true) {
    global Running
    if !Running {
        ReleaseSpecialKeys()
        if throwOnStop
            throw Error("Stopped by user.")
        return true
    }
    return false
}

; ─────────────────────────────────────────────────────────────────────────────
;  Helpers de tecla  (cópia exata)
; ─────────────────────────────────────────────────────────────────────────────
ReleaseSpecialKeys() {
    for key in ["w", "a", "s", "d", "Left", "Right", "Up", "Down", "Space", "RButton"]
        try SendEvent("{" key " up}")
}

SpecialTapKey(key, ms := 60) {
    SpecialCheckStop(false)
    SendEvent("{" key " down}")
    Sleep(ms)
    SendEvent("{" key " up}")
}

SpecialHoldKey(key, ms) {
    SpecialCheckStop(false)
    SendEvent("{" key " down}")
    Sleep(ms)
    SendEvent("{" key " up}")
}

SpecialFullZoomOut(ticks := 30, delayMs := 15) {
    ActivateRoblox()
    Loop ticks {
        if SpecialCheckStop(false)
            return false
        SendEvent("{WheelDown}")
        Sleep(delayMs)
    }
    return true
}

; ─────────────────────────────────────────────────────────────────────────────
;  SpecialSearchUntilFound  — busca progressiva com rotação incremental
;
;  Estratégia:
;    • Tenta fast PixelSearch (RGB + BGR) em cada iteração
;    • Se 3 misses seguidos → slow-scan (step=3) como confirmação extra
;    • Se 5 misses seguidos → zoom out + rotação esquerda com duração crescente
;      (100ms base + 80ms por ciclo de rotação, cap 600ms)
;    • Marker mostra fase "search" e coordenadas ao encontrar
; ─────────────────────────────────────────────────────────────────────────────
SpecialSearchUntilFound(node, &outX, &outY) {
    missCount          := 0
    checksBeforeRotate := 5
    rotateMs           := 200
    searchStart        := A_TickCount
    searchTimeoutMs    := 120000   ; 2 min → reporta erro e encerra

    Loop {
        if SpecialCheckStop(false)
            return false

        ; ── timeout 2 min ─────────────────────────────────────────────────────
        if (A_TickCount - searchStart >= searchTimeoutMs) {
            SetStatus("Wagon: timeout 2 min — cor nao encontrada.")
            Sleep(300)
            try ReleaseSpecialKeys()
            try HideSpecialMarker()
            Running := false
            WriteSignalAndExit("error", "timeout_search_color_not_found")
        }

        if SpecialFindTargetColor(node, &outX, &outY, true) {
            ShowSpecialMarker(outX, outY)
            SetStatus("Wagon: cor encontrada em " outX "," outY ".")
            return true
        }

        missCount += 1
        SetStatus("Wagon: cor nao visivel. Miss " missCount "/" checksBeforeRotate ".")

        if (missCount >= checksBeforeRotate) {
            SetStatus("Wagon: " checksBeforeRotate " misses — zoom out + girando esquerda...")
            HideSpecialMarker()
            ToolTip()
            SpecialFullZoomOut(30, 15)
            SpecialCheckStop(false)
            SetStatus("Wagon: girando esquerda...")
            ActivateRoblox()
            Sleep(60)
            SendEvent("{Left down}")
            Sleep(rotateMs)
            SendEvent("{Left up}")
            Sleep(180)
            missCount := 0
        } else {
            Sleep(90)
        }
    }
}

; ─────────────────────────────────────────────────────────────────────────────
SpecialCenterColorWithCamera(node) {
    centerTolX    := 15
    maxAttempts   := 40
    centerPulseMs := 50

    Loop maxAttempts {
        if SpecialCheckStop(false)
            return false

        if !SpecialFindTargetColor(node, &fx, &fy, true) {
            SetStatus("Wagon: perdeu cor durante centralização — rebuscando...")
            if !SpecialSearchUntilFound(node, &fx, &fy)
                return false
        }

        ShowSpecialMarker(fx, fy)
        if !GetRobloxClientRect(&cx, &cy, &cw, &ch) {
            cx := 0, cy := 0, cw := A_ScreenWidth, ch := A_ScreenHeight
        }
        targetX := cx + cw / 2
        errX := fx - targetX
        if (Abs(errX) <= centerTolX) {
            SetStatus("Wagon: centralizado. errX=" Round(errX))
            return true
        }

        key := (errX > 0) ? "Right" : "Left"
        SetStatus("Wagon: centralizando errX=" Round(errX) ", tap " key " 50ms.")
        SpecialTapKey(key, centerPulseMs)
        Sleep(90)
    }
    SetStatus("Wagon: timeout centralização — prosseguindo mesmo assim.")
    return false
}

; ─────────────────────────────────────────────────────────────────────────────
SpecialMovementFlow(node) {
    global Running
    if !Running
        return false

    ActivateRoblox()
    SpecialCheckStop()

    ; ── 1. Zoom out total ─────────────────────────────────────────────────────
    SetStatus("Special: zoom out total...")
    SpecialFullZoomOut(30, 15)
    Sleep(100)
    SpecialCheckStop()

    ; ── 2. Busca cor do wagon ─────────────────────────────────────────────────
    SetStatus("Special: procurando cor até encontrar...")
    if !SpecialSearchUntilFound(node, &fx, &fy)
        return false
    SpecialCheckStop()

    ; ── 3. Centraliza câmera ──────────────────────────────────────────────────
    SetStatus("Special: centralizando câmera...")
    SpecialCenterColorWithCamera(node)
    SpecialCheckStop()

    ; ── 4. W × 3 s ───────────────────────────────────────────────────────────
    SetStatus("Special: andando para frente (W × 3s)...")
    SpecialHoldKey("w", 3000)
    Sleep(120)
    SpecialCheckStop()

    ; ── 5. S × 50ms (walk back) ──────────────────────────────────────────────
    SetStatus("Special: recuando (S × 50ms)...")
    SpecialHoldKey("s", 50)
    Sleep(80)
    SpecialCheckStop()

    ; ── 6. Zoom out antes de re-centralizar ──────────────────────────────────
    SetStatus("Special: zoom out antes de re-centralizar...")
    SpecialFullZoomOut(30, 15)
    Sleep(100)
    SpecialCheckStop()

    ; ── 7. Aguarda 0.5s ──────────────────────────────────────────────────────
    SetStatus("Special: aguardando 0.5s...")
    Sleep(500)
    SpecialCheckStop()

    ; ── 8. Re-busca cor ───────────────────────────────────────────────────────
    SetStatus("Special: re-buscando cor após caminhada...")
    if !SpecialSearchUntilFound(node, &fx2, &fy2)
        return false
    SpecialCheckStop()

    ; ── 9. Re-centraliza antes do pulo ───────────────────────────────────────
    SetStatus("Special: re-centralizando antes do pulo...")
    SpecialCenterColorWithCamera(node)
    SpecialCheckStop()

    ; ── 10. Double jump ──────────────────────────────────────────────────────
    SetStatus("Special: double jump...")
    SpecialTapKey("Space", 60)
    Sleep(250)
    SpecialTapKey("Space", 60)
    Sleep(50)
    SpecialCheckStop()

    ; ── 11. W × 350ms + stop ─────────────────────────────────────────────────
    SetStatus("Special: andando para frente (W × 350ms)...")
    SpecialHoldKey("w", 350)
    Sleep(120)
    ReleaseSpecialKeys()

    SetStatus("Special: concluído com sucesso!")
    return true
}

; ─────────────────────────────────────────────────────────────────────────────
;  WriteSignalAndExit
; ─────────────────────────────────────────────────────────────────────────────
WriteSignalAndExit(status, detail := "") {
    global _SignalFile
    HideSpecialMarker()
    HideStatusOverlay()

    ; Escreve o arquivo inteiro de uma vez (atômico) para evitar race condition:
    ; IniWrite faz 3 escritas separadas — o Python detecta o arquivo após a
    ; primeira e lê conteúdo incompleto. FileAppend escreve tudo de uma vez.
    _content := "[Result]`nstatus=" status "`ndetail=" detail "`ntick=" A_TickCount "`n"

    _written := false
    try {
        if FileExist(_SignalFile)
            FileDelete(_SignalFile)
        FileAppend(_content, _SignalFile, "UTF-8")
        _written := true
    }
    if !_written {
        fallback := A_Temp "\wagon_done.ini"
        try {
            if FileExist(fallback)
                FileDelete(fallback)
            FileAppend(_content, fallback, "UTF-8")
        }
    }
    ExitApp(status = "ok" ? 0 : 1)
}

; ─────────────────────────────────────────────────────────────────────────────
;  PONTO DE ENTRADA
; ─────────────────────────────────────────────────────────────────────────────
CreateStatusOverlayGui()

if !GetRobloxHwnd() {
    WriteSignalAndExit("error", "Roblox nao encontrado. Abra o Roblox primeiro.")
}

; CRÍTICO: Running := true antes de qualquer chamada ao flow.
; O FlowWhiteboard faz isso em RunSpecialFunctionNode antes de chamar
; SpecialMovementFlow. Sem isso, SpecialCheckStop() aborta tudo imediatamente.
Running := true

SetStatus("Wagon Move: iniciando...")

ok := false
try {
    ok := SpecialMovementFlow(_node)
} catch as _err {
    ReleaseSpecialKeys()
    HideSpecialMarker()
    Running := false
    SetStatus("Wagon Move: ERRO — " _err.Message)
    Sleep(800)
    WriteSignalAndExit("error", _err.Message)
}

ReleaseSpecialKeys()
HideSpecialMarker()
Running := false

if ok {
    SetStatus("Wagon Move: concluído!")
    Sleep(500)
    WriteSignalAndExit("ok", "movement_complete")
} else {
    SetStatus("Wagon Move: falhou (stopped ou cor não encontrada).")
    Sleep(800)
    WriteSignalAndExit("error", "movement_failed")
}
