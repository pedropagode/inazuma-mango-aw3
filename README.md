# Inazuma Mango AW3

Macro/automação para Roblox (estratégia inicial: **Escort**). Compartilha o
mesmo servidor de licença (HWID) do InazumaMango original — só mudam o
binário (`InazumaMangoAW3.exe`) e o repositório de releases/assets
(`pedropagode/inazuma-mango-aw3`).

## Estrutura do projeto

```
/ (raiz)
├── run.py                  # stub leve, compilado em run.exe (PyInstaller)
├── _launcher.py            # entry point real, compilado dentro do .exe (Nuitka)
├── _deps.py                # checagem/instalação automática de dependências
├── app_paths.py            # resolução robusta do diretório do .exe
├── splash.py               # janela de loading / erro / "Access Blocked"
├── gui.py                  # interface principal (PyQt6)
├── Main.py                 # orquestra start/stop e o main_loop das strategies
├── update_api.py           # checagem/aplicação de updates via GitHub Releases
├── ahk_manager.py          # gerencia o AutoRamTrim.ahk (RAM trim)
├── get_hwid.py             # utilitário: mostra/copia o HWID e checa licença
├── get_hwid.bat            # wrapper .bat para get_hwid.py / --hwid do exe
├── gui_patch_autoramtrim.py# patch legado (NÃO usar junto com ahk_manager)
├── build_exe_nuitka.bat    # build de release (.exe único via Nuitka)
├── AutoRamTrim.ahk          *** precisa ser adicionado ***
├── updater.ahk              *** precisa ser adicionado ***
├── icon.ico                 *** precisa ser adicionado ***
├── ram_trim_config.ini      *** precisa ser adicionado ***
├── fonts/
│   ├── LeagueSpartan-Regular.ttf   *** precisa ser adicionado ***
│   └── LeagueSpartan-Bold.ttf      *** precisa ser adicionado ***
├── Images/                  *** precisa ser adicionado (assets do macro) ***
├── tesseract/               *** precisa ser adicionado (OCR engine) ***
└── core/
    ├── state.py
    ├── config.py
    ├── helpers.py
    ├── actions.py
    ├── detections.py
    ├── escort.py
    ├── InputHandler.py
    ├── webhook.py
    ├── Gdip_All.ahk
    ├── OCR.ahk
    ├── wagon_move.ahk
    ├── wagon_move.ini
    └── wagon_done.ini
```

### Itens marcados com `*** precisa ser adicionado ***`

Esses arquivos são **referenciados pelo código** (build script, ahk_manager,
update_api, gui) mas não foram fornecidos como texto/binário até agora —
copie-os do projeto InazumaMango original (ou recrie-os) antes de buildar:

- `AutoRamTrim.ahk` / `ram_trim_config.ini` — usados por `ahk_manager.py`
- `updater.ahk` — usado por `update_api.apply_update_and_restart()`
- `icon.ico`, `Images/`, `fonts/*.ttf`, `tesseract/` — assets visuais/OCR

## Dependências (instalação automática)

Todas as bibliotecas Python necessárias estão listadas em `_deps.py`
(`REQUIRED_PACKAGES`):

```
opencv-python-headless, numpy, mss, dxcam, pyautogui, pyperclip, requests,
Pillow, pywin32, pygetwindow, pyrect, pynput, mouse, keyboard, psutil,
pydirectinput, pytesseract, PyQt6 (+ pyqt6-qt6, pyqt6-sip)
```

Fluxo de verificação (igual ao InazumaMango original, mas agora cobrindo
**todas** as libs, não só as builds):

1. `run.exe` roda `python _launcher.py --check-only`.
2. `--check-only` chama `_deps.ensure_dependencies()`:
   - importa cada módulo da lista; se faltar, instala via
     `pip install --upgrade --quiet <pacote>`;
   - `dxcam` é tratado como opcional (há fallback `mss` em `detections.py`).
3. Se tudo OK (ou instalado com sucesso) → `run.exe` lança `_launcher.py`
   via `pythonw` (sem console).
4. Dentro de `_launcher.py`, antes da checagem de licença, roda-se uma
   segunda checagem rápida em processo (rede de segurança caso alguém rode
   `_launcher.py` direto, sem passar por `run.exe`).

## Licenciamento (HWID)

`_launcher.py` e `get_hwid.py` usam o mesmo servidor:

```
LICENSE_SERVER = "https://inazuma-license.onrender.com"
```

O HWID é `sha256(MAC | ProcessorId | DiskSerial)[:24]`. Como o cálculo é
baseado no hardware da máquina (e não no app), **uma licença liberada para o
InazumaMango original já funciona aqui** — não é necessário cadastro
separado no servidor.

## Auto-update

`update_api.py` já está configurado para este repositório:

```python
GITHUB_OWNER = "pedropagode"
GITHUB_REPO  = "inazuma-mango-aw3"
EXE_NAME     = "InazumaMangoAW3.exe"
```

- `check_for_update()` consulta `GET /repos/{owner}/{repo}/releases/latest`
  e compara `__version__` (`update_api.py`) com a tag da release.
- Se houver versão mais nova, `_launcher.py` mostra o aviso no splash e o
  próprio `gui.py` pode chamar `update_api.full_update()`, que:
  1. sincroniza `Images/` e demais `SYNC_PATHS` (bidirecional);
  2. lança `updater.ahk` (delete → download → run) para substituir o `.exe`.

**Lembre-se de criar uma GitHub Release com tag `vX.Y.Z` e o asset
`InazumaMangoAW3.exe`** a cada build — sem isso `check_for_update()` nunca
detecta atualização.

## Build (release)

```bat
build_exe_nuitka.bat
```

- Faz bump de versão em `update_api.py` (`__version__`).
- Instala/atualiza todas as dependências (mesma lista de `_deps.py`).
- Auto-descobre todos os `.py` da raiz e de `core/` e gera
  `--include-module` automaticamente.
- Compila `_launcher.py` → `InazumaMangoAW3.exe` (onefile), embutindo
  `Images/`, fontes, `AutoRamTrim.ahk` e `ram_trim_config.ini`.

> `run.py`/`run.exe` (PyInstaller) é o pipeline separado e leve usado para
> checagem de dependências + lançamento sem console; mantenha os dois
> binários na mesma pasta na distribuição final.

## Diferenças vs. InazumaMango original

| Item | Original | AW3 |
|---|---|---|
| `.exe` | `InazumaMango.exe` | `InazumaMangoAW3.exe` |
| Repo (updates/assets) | (outro) | `pedropagode/inazuma-mango-aw3` |
| Servidor de licença/HWID | mesmo | mesmo |
| Checagem de dependências | parcial (apenas no build) | completa, em runtime (`_deps.py`) |
| Strategies registradas | Escort + outras | Escort (inicial) |
