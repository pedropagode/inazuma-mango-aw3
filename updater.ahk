; updater.ahk — Inazuma Mango auto-updater (AHK v2)
; ─────────────────────────────────────────────────────────────────────────────
; Recebe o caminho do .exe atual como primeiro parametro.
; Fluxo:
;   1. Espera o processo principal fechar
;   2. Baixa InazumaMango.exe (release mais recente) via PowerShell
;      (AHK Download() nao segue redirects 302 do GitHub → S3)
;   3. Valida o tamanho do arquivo baixado antes de substituir o atual
;   4. Baixa AutoRamTrim.ahk (release mais recente)
;   5. Relança o InazumaMango.exe
; ─────────────────────────────────────────────────────────────────────────────

#Requires AutoHotkey v2.0

REPO_OWNER := "pedropagode"
REPO_REPO  := "inazuma-mango-aw3"
BASE_URL   := "https://github.com/" . REPO_OWNER . "/" . REPO_REPO . "/releases/latest/download/"
RAW_BASE   := "https://github.com/" . REPO_OWNER . "/" . REPO_REPO . "/archive/refs/heads/main.zip"

EXE_NAME   := "InazumaMangoAW3.exe"
AHK_NAME   := "AutoRamTrim.ahk"

; Recebe o caminho do exe como arg ou detecta pelo script location
exePath := A_Args.Length > 0 ? A_Args[1] : A_ScriptDir . "\" . EXE_NAME
exeDir  := RegExReplace(exePath, "\\[^\\]+$", "")

; Garante que o diretorio termina sem barra
if SubStr(exeDir, -1) = "\"
    exeDir := SubStr(exeDir, 1, -1)

exeUrl  := BASE_URL . EXE_NAME
ahkUrl  := BASE_URL . AHK_NAME
exeDest := exeDir . "\" . EXE_NAME
ahkDest := exeDir . "\" . AHK_NAME

; ── 1. Aguarda o processo principal encerrar (até 30s) ───────────────────────
exeBase := RegExReplace(EXE_NAME, "\.exe$", "")
Loop 60 {
    if !ProcessExist(exeBase)
        break
    Sleep(500)
}

; Pausa extra para liberar file handles do SO
Sleep(1500)

; ── Funcao: baixa via PowerShell (segue redirects 302 do GitHub → S3) ────────
; AHK Download() falha silenciosamente em redirects — grava HTML do redirect
; em vez do binario. PowerShell WebClient.DownloadFile segue redirects.
DownloadViaPowerShell(url, dest) {
    ; Escapa aspas simples no destino para o comando PowerShell
    destEsc := StrReplace(dest, "'", "''")
    urlEsc  := StrReplace(url,  "'", "''")
    q   := Chr(34)
    cmd := "PowerShell -NoProfile -ExecutionPolicy Bypass -Command "
         . q . "(New-Object Net.WebClient).DownloadFile('"
         . urlEsc . "', '" . destEsc . "')" . q
    RunWait(cmd, , "Hide")
}

; ── 2. Baixa o novo InazumaMango.exe para arquivo temporario primeiro ─────────
; Baixa para .tmp antes de deletar o original — se o download falhar,
; o exe atual nao e perdido.
exeTmp := exeDest . ".tmp"

try {
    if FileExist(exeTmp)
        FileDelete(exeTmp)
    DownloadViaPowerShell(exeUrl, exeTmp)
} catch as e {
    MsgBox("Falha ao baixar " . EXE_NAME . "`n" . e.Message, "Inazuma Updater", 16)
    ExitApp(1)
}

; Valida o arquivo baixado — rejeita se menor que 1 MB (HTML de erro, redirect
; nao seguido ou download incompleto produzem arquivos minusculos)
MIN_EXE_BYTES := 1048576  ; 1 MB
if !FileExist(exeTmp) {
    MsgBox("Download falhou: arquivo nao foi criado.`nURL: " . exeUrl, "Inazuma Updater", 16)
    ExitApp(1)
}
tmpSize := FileGetSize(exeTmp)
if (tmpSize < MIN_EXE_BYTES) {
    try FileDelete(exeTmp)
    MsgBox(
        "Download corrompido (" . tmpSize . " bytes).`n"
        . "Esperado pelo menos 1 MB.`n`n"
        . "Verifique sua conexao e tente novamente.",
        "Inazuma Updater", 16
    )
    ExitApp(1)
}

; Substituicao atomica com retry — o Windows pode demorar alguns segundos
; para liberar o file handle do exe apos o processo encerrar (erro 5 = ACCESS_DENIED).
replaceOk := false
replaceErr := ""
Loop 20 {
    try {
        if FileExist(exeDest)
            FileDelete(exeDest)
        FileMove(exeTmp, exeDest)
        replaceOk := true
        break
    } catch as e {
        replaceErr := e.Message
        Sleep(500)
    }
}
if !replaceOk {
    MsgBox("Falha ao substituir " . EXE_NAME . "`n" . replaceErr, "Inazuma Updater", 16)
    ExitApp(1)
}

; ── 3. Baixa AutoRamTrim.ahk ─────────────────────────────────────────────────
try {
    ahkTmp := ahkDest . ".tmp"
    if FileExist(ahkTmp)
        FileDelete(ahkTmp)
    DownloadViaPowerShell(ahkUrl, ahkTmp)
    if FileExist(ahkTmp) && FileGetSize(ahkTmp) > 0 {
        if FileExist(ahkDest)
            FileDelete(ahkDest)
        FileMove(ahkTmp, ahkDest)
    } else {
        try FileDelete(ahkTmp)
    }
} catch {
    ; Falha no AutoRamTrim nao deve bloquear o update do exe principal
}

; ── 4. Relança o exe atualizado ──────────────────────────────────────────────
try {
    Run(exeDest)
} catch as e {
    MsgBox("Update concluido mas falha ao relancar.`n" . e.Message
           . "`nAbra manualmente: " . exeDest, "Inazuma Updater", 48)
}

ExitApp(0)
