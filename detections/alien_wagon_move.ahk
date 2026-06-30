#Requires AutoHotkey v2.0
#SingleInstance Force
#Include Gdip_All.ahk
#Include OCR.ahk

; ─────────────────────────────────────────────────────────────────────────────
;  alien_wagon_move.ahk  —  chamado pelo alien_invasion.py
;
;  Lê alien_wagon_move.ini para:
;    [Config]
;    ColorHex=0xCDE3FE   ; cor do wagon (igual ao nó #8 do FlowWhiteboard)
;    Tolerance=0         ; tolerância da cor
;    SignalFile=         ; caminho do alien_wagon_done.ini (padrão: mesmo dir)
;
;  Fluxo do Alien Invasion Wagon:
;    1. Aperta F
;    2. Segura Space × 3s
;    3. Detecção: PixelSearch sem zoom → a cada 5 misses: gira Left 200ms
;    4. Centraliza câmera X (com giro permitido)
;    5. Segura W + Space × 3.5s
;    6. Aperta F novamente
;    7. Zoom out total
;    8. Escreve alien_wagon_done.ini e ExitApp (sinal de sucesso)
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
global specialMarkerW       := 10
global specialMarkerH       := 10
global statusOverlayGui     := ""
global statusOverlayText    := ""
global StatusLastText       := ""
global StatusOverlaySuppressed := false
global _lastColorX          := 0
global _lastColorY          := 0
global _lastColorTick       := 0

; ── Lê configuração ───────────────────────────────────────────────────────────
_CfgFile := A_ScriptDir "\alien_wagon_move.ini"

_ColorHex   := Trim(IniRead(_CfgFile, "Config", "ColorHex",   "0xCDE3FE"))
_Tolerance  := Integer(Trim(IniRead(_CfgFile, "Config", "Tolerance",  "0")))
_SignalFile := Trim(IniRead(_CfgFile, "Config", "SignalFile", ""))
if (_SignalFile = "")
    _SignalFile := A_ScriptDir "\alien_wagon_done.ini"

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
    statusOverlayGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20", "Alien Wagon Move Status")
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

    w := specialMarkerW, h := specialMarkerH
    tx := x - w // 2
    ty := y - h // 2

    specialMarkerTgtX := tx
    specialMarkerTgtY := ty

    ; ── Já existe: só atualiza o alvo — a transição suave é feita pelo timer ──
    if (specialMarkerGui != "") {
        SetTimer(_AnimateSpecialMarker, 15)
        return
    }

    ; ── Primeira aparição: cria já na posição final, sem animação ─────────────
    specialMarkerGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20")
    specialMarkerGui.BackColor := "2563EB"   ; pontinho azul

    specialMarkerGui.Show("x" tx " y" ty " w" w " h" h " NoActivate")

    ; recorte circular (pontinho)
    try {
        hRgn := DllCall("CreateEllipticRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1, "Ptr")
        DllCall("SetWindowRgn", "Ptr", specialMarkerGui.Hwnd, "Ptr", hRgn, "Int", true)
    }

    WinSetTransparent(235, "ahk_id " specialMarkerGui.Hwnd)

    specialMarkerCurX := tx
    specialMarkerCurY := ty
}


; ─────────────────────────────────────────────────────────────────────────────
;  _AnimateSpecialMarker — transição suave (ease-out) entre a posição atual
;  e a posição alvo do pontinho azul de detecção. Roda a ~66fps até chegar
;  perto do destino, então para o timer sozinho.
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
;  SpecialFindTargetColor  (busca em ROI + fallback full-screen)
;  Busca a cor do wagon. Se houver uma posição recente conhecida, tenta
;  primeiro numa pequena região ao redor dela (mais rápido e mais estável
;  contra antialiasing/dithering — evita "perder e achar" entre frames).
;  Se não achar na ROI, cai para o PixelSearch full-screen (RGB + BGR).
; ─────────────────────────────────────────────────────────────────────────────
SpecialFindTargetColor(node, &fx, &fy, fastOnly := true) {
    global _lastColorX, _lastColorY, _lastColorTick

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

        ; ── ROI ao redor da última posição conhecida (até 600ms de validade) ──
        ; Roblox não "teleporta" a cor entre frames; checar perto de onde
        ; estava é muito mais rápido e evita falso-negativo por ruído pontual.
        roiMargin := 60
        if (_lastColorTick != 0 && A_TickCount - _lastColorTick <= 600) {
            rx1 := Max(x1, _lastColorX - roiMargin)
            ry1 := Max(y1, _lastColorY - roiMargin)
            rx2 := Min(x2, _lastColorX + roiMargin)
            ry2 := Min(y2, _lastColorY + roiMargin)
            try {
                if PixelSearch(&fx, &fy, rx1, ry1, rx2, ry2, colorRGB, tol) {
                    _lastColorX := fx, _lastColorY := fy, _lastColorTick := A_TickCount
                    return true
                }
            } catch {
            }
            try {
                if PixelSearch(&fx, &fy, rx1, ry1, rx2, ry2, colorBGR, tol) {
                    _lastColorX := fx, _lastColorY := fy, _lastColorTick := A_TickCount
                    return true
                }
            } catch {
            }
        }

        ; ── Fallback: full-screen (RGB + BGR) ──────────────────────────────────
        try {
            if PixelSearch(&fx, &fy, x1, y1, x2, y2, colorRGB, tol) {
                _lastColorX := fx, _lastColorY := fy, _lastColorTick := A_TickCount
                return true
            }
        } catch {
        }
        try {
            if PixelSearch(&fx, &fy, x1, y1, x2, y2, colorBGR, tol) {
                _lastColorX := fx, _lastColorY := fy, _lastColorTick := A_TickCount
                return true
            }
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
                    _lastColorX := fx, _lastColorY := fy, _lastColorTick := A_TickCount
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
;  SpecialCheckColorVisible  (verificação pura — SEM busca, SEM giro de câmera)
;
;  Usada exclusivamente DENTRO do ciclo (passo 6). Apenas checa se a cor do
;  wagon está visível no frame atual do cliente Roblox via PixelSearch
;  (RGB + BGR). Não usa ROI/última posição, não faz slow-scan, não gira a
;  câmera e não chama nenhuma função de busca — só verificação direta.
;  Se a cor não estiver na tela, retorna false e o ciclo deve sair (break).
; ─────────────────────────────────────────────────────────────────────────────
SpecialCheckColorVisible(node, &fx, &fy) {
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

; Segura duas teclas simultaneamente pelo tempo indicado (ms)
SpecialHoldTwoKeys(key1, key2, ms) {
    SpecialCheckStop(false)
    SendEvent("{" key1 " down}{" key2 " down}")
    Sleep(ms)
    SendEvent("{" key1 " up}{" key2 " up}")
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
;  SpecialSearchUntilFoundNoZoom — busca progressiva com rotação incremental,
;  SEM zoom out (o zoom só ocorre no passo 7, após o ciclo).
;
;  Estratégia:
;    • Tenta fast PixelSearch (RGB + BGR) em cada iteração
;    • Se 5 misses seguidos → gira Left 200ms e continua (sem zoom)
;    • Marker mostra coordenadas ao encontrar
; ─────────────────────────────────────────────────────────────────────────────
SpecialSearchUntilFoundNoZoom(node, &outX, &outY) {
    missCount          := 0
    checksBeforeRotate := 5
    rotateMs           := 200
    searchStart        := A_TickCount
    searchTimeoutMs    := 120000   ; 2 min → reporta erro e encerra

    Loop {
        if SpecialCheckStop(false)
            return false

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
            SetStatus("Wagon: " checksBeforeRotate " misses — girando esquerda (sem zoom)...")
            HideSpecialMarker()
            ToolTip()
            SpecialCheckStop(false)
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
;  SpecialCenterColorWithCamera
;
;  Alinha a câmera sobre a cor do wagon apenas em X.
;    X → pulsa Left/Right até errX ≤ centerTolX
;  Retorna um objeto: { ok: true/false, dir: "Right"|"Left"|"none", ms: <int> }
;    dir = direção horizontal dominante (para uso externo, se necessário)
;    ms  = tempo total acumulado de pulsos nessa direção
; ─────────────────────────────────────────────────────────────────────────────
SpecialCenterColorWithCamera(node) {
    centerTolX    := 15
    maxAttempts   := 80
    centerPulseMs := 50

    totalRightMs := 0
    totalLeftMs  := 0

    Loop maxAttempts {
        if SpecialCheckStop(false)
            return { ok: false, dir: "none", ms: 0 }

        if !SpecialFindTargetColor(node, &fx, &fy, true) {
            SetStatus("Wagon: perdeu cor durante centralização — rebuscando (sem zoom)...")
            if !SpecialSearchUntilFoundNoZoom(node, &fx, &fy)
                return { ok: false, dir: "none", ms: 0 }
        }

        ShowSpecialMarker(fx, fy)
        if !GetRobloxClientRect(&cx, &cy, &cw, &ch)
            cx := 0, cy := 0, cw := A_ScreenWidth, ch := A_ScreenHeight

        targetX := cx + cw / 2
        errX    := fx - targetX

        if (Abs(errX) <= centerTolX) {
            if (totalRightMs > 0 || totalLeftMs > 0) {
                dominantDir := (totalRightMs >= totalLeftMs) ? "Right" : "Left"
                dominantMs  := Max(totalRightMs, totalLeftMs)
            } else {
                dominantDir := "none"
                dominantMs  := 0
            }
            SetStatus("Wagon: centralizado X. errX=" Round(errX) " dir=" dominantDir)
            return { ok: true, dir: dominantDir, ms: dominantMs }
        }

        ; ── Corrige X ────────────────────────────────────────────────────────
        keyX := (errX > 0) ? "Right" : "Left"
        SetStatus("Wagon: centralizando X errX=" Round(errX) ", tap " keyX ".")
        SpecialTapKey(keyX, centerPulseMs)
        if (keyX = "Right")
            totalRightMs += centerPulseMs
        else
            totalLeftMs  += centerPulseMs
        Sleep(60)
    }

    ; Timeout
    if (totalRightMs >= totalLeftMs && totalRightMs > 0)
        dominantDir := "Right"
    else if (totalLeftMs > totalRightMs)
        dominantDir := "Left"
    else
        dominantDir := "none"
    dominantMs := Max(totalRightMs, totalLeftMs)
    SetStatus("Wagon: timeout centralização X — dir=" dominantDir " — prosseguindo.")
    return { ok: false, dir: dominantDir, ms: dominantMs }
}

; ─────────────────────────────────────────────────────────────────────────────
;  SpecialMovementFlow — Alien Invasion
;
;  Fluxo:
;    1. Aperta F
;    2. Segura Space × 3s
;    3. Detecção: PixelSearch sem zoom → a cada 5 misses: gira Left 200ms
;    4. Centraliza câmera X (com giro permitido)
;    5. Segura W + Space × 3.5s
;    6. Aperta F novamente
;    7. Zoom out total
;    8. Sinal de sucesso
;    7. Zoom out total (sem centralização)
;    8. Aperta F novamente (final)
;    9. Escreve alien_wagon_done.ini e ExitApp (sinal de sucesso)
; ─────────────────────────────────────────────────────────────────────────────

; Centraliza câmera em X e Y dentro do ciclo, usando apenas verificação
; (SpecialCheckColorVisible — SEM busca, SEM giro de procura). Se a cor não
; estiver visível na tela atual, falha imediatamente: não há razão para girar
; procurando, pois o ciclo já assume que a cor pode ter saído de vista de fato.
; maxCorrections = tentativas de correção por giro (Left/Right) antes
;                   de desistir e seguir — limitado para evitar giro excessivo.
; Retorna true se centralizou (ou esgotou as correções), false se a cor não
; está visível na tela.
SpecialCycleCenter(node, maxCorrections := 5) {
    centerTolX    := 15
    centerPulseMs := 50

    fx := 0, fy := 0
    if !SpecialCheckColorVisible(node, &fx, &fy) {
        SetStatus("Alien Wagon: cor não visível na tela — encerrando ciclo.")
        return false
    }

    Loop maxCorrections {
        if SpecialCheckStop(false)
            return false
        if !SpecialCheckColorVisible(node, &fx, &fy) {
            SetStatus("Alien Wagon: cor não visível na tela — encerrando ciclo.")
            return false
        }
        ShowSpecialMarker(fx, fy)
        if !GetRobloxClientRect(&cx, &cy, &cw, &ch)
            cx := 0, cy := 0, cw := A_ScreenWidth, ch := A_ScreenHeight

        targetX := cx + cw / 2
        errX    := fx - targetX

        if (Abs(errX) <= centerTolX) {
            SetStatus("Alien Wagon: centralizado X (rápido). errX=" Round(errX))
            return true
        }

        ; Corrige X
        keyX := (errX > 0) ? "Right" : "Left"
        SetStatus("Alien Wagon: centralizando (rápido) X errX=" Round(errX) ", tap " keyX ".")
        SpecialTapKey(keyX, centerPulseMs)
        Sleep(60)
    }
    SetStatus("Alien Wagon: limite de correções X atingido — prosseguindo.")
    return true
}

SpecialMovementFlow(node) {
    global Running
    if !Running
        return false

    ActivateRoblox()
    SpecialCheckStop()

    ; ── 1. Aperta F ──────────────────────────────────────────────────────────
    SetStatus("Alien Wagon: pressionando F...")
    SpecialTapKey("f", 60)
    Sleep(200)
    SpecialCheckStop()

    ; ── 2. Segura Space × 3s ─────────────────────────────────────────────────
    SetStatus("Alien Wagon: segurando Space × 3s...")
    SpecialHoldKey("Space", 3000)
    Sleep(150)
    SpecialCheckStop()

    ; ── 3. Zoom out manual (antes da detecção) ───────────────────────────────
    SetStatus("Alien Wagon: zoom out manual...")
    SpecialFullZoomOut(30, 15)
    Sleep(100)
    SpecialCheckStop()

    ; ── 4. Busca cor (sem zoom, gira a cada 5 misses) ─────────────────────────
    SetStatus("Alien Wagon: procurando cor até encontrar (sem zoom)...")
    if !SpecialSearchUntilFoundNoZoom(node, &fx, &fy)
        return false
    SpecialCheckStop()

    ; ── 5. Centraliza câmera X (com giro permitido) ──────────────────────────
    SetStatus("Alien Wagon: centralizando câmera X...")
    SpecialCenterColorWithCamera(node)
    Sleep(120)
    SpecialCheckStop()

    ; ── 6. Segura W + Space × 3.5s ───────────────────────────────────────────
    SetStatus("Alien Wagon: segurando W+Space × 3.5s...")
    SpecialHoldTwoKeys("w", "Space", 3500)
    Sleep(150)
    ReleaseSpecialKeys()
    SpecialCheckStop()

    ; ── 7. Aperta F novamente ─────────────────────────────────────────────────
    SetStatus("Alien Wagon: pressionando F (final)...")
    SpecialTapKey("f", 60)
    Sleep(200)
    SpecialCheckStop()

    ; ── 8. Zoom out total ─────────────────────────────────────────────────────
    SetStatus("Alien Wagon: zoom out final...")
    SpecialFullZoomOut(30, 15)
    Sleep(100)
    ReleaseSpecialKeys()

    ; ── 9. Sinal de sucesso ───────────────────────────────────────────────────
    SetStatus("Alien Wagon: concluído — sinal enviado.")
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
        fallback := A_Temp "\alien_wagon_done.ini"
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

SetStatus("Alien Wagon Move: iniciando...")

ok := false
try {
    ok := SpecialMovementFlow(_node)
} catch as _err {
    ReleaseSpecialKeys()
    HideSpecialMarker()
    Running := false
    SetStatus("Alien Wagon Move: ERRO — " _err.Message)
    Sleep(800)
    WriteSignalAndExit("error", _err.Message)
}

ReleaseSpecialKeys()
HideSpecialMarker()
Running := false

if ok {
    SetStatus("Alien Wagon Move: concluído!")
    Sleep(500)
    WriteSignalAndExit("ok", "movement_complete")
} else {
    SetStatus("Alien Wagon Move: falhou (stopped ou cor não encontrada).")
    Sleep(800)
    WriteSignalAndExit("error", "movement_failed")
}
