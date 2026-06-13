import hashlib
import subprocess
import sys
import uuid

SERVER = "https://inazuma-license.onrender.com"

_CREATE_NO_WINDOW = 0x08000000


def _silent_startupinfo() -> subprocess.STARTUPINFO:
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 0  # SW_HIDE
    return si


def wmic(query: str) -> str:
    try:
        out = subprocess.check_output(
            "wmic " + query, shell=True,
            stderr=subprocess.DEVNULL, timeout=5,
            creationflags=_CREATE_NO_WINDOW,
            startupinfo=_silent_startupinfo(),
        ).decode(errors="ignore")
        lines = [l.strip() for l in out.splitlines() if l.strip()]
        return lines[1] if len(lines) > 1 else ""
    except Exception:
        return ""


def get_hwid() -> str:
    mac  = hex(uuid.getnode())
    cpu  = wmic("cpu get ProcessorId")
    disk = wmic("diskdrive get SerialNumber")
    raw  = f"{mac}|{cpu}|{disk}"
    return hashlib.sha256(raw.encode()).hexdigest()[:24].upper()


def copy_to_clipboard(text: str) -> bool:
    """Copy text to the Windows clipboard via clip.exe (stdlib only)."""
    try:
        subprocess.run(
            "clip", input=text.encode("utf-16le"),
            shell=True, check=True, timeout=5,
            creationflags=_CREATE_NO_WINDOW,
            startupinfo=_silent_startupinfo(),
        )
        return True
    except Exception:
        return False


def main():
    hwid = get_hwid()

    print()
    print("  ============================================")
    print("   Inazuma Mango -- Access Check")
    print("  ============================================")
    print()
    print(f"   HWID: {hwid}")
    print()

    copied = copy_to_clipboard(hwid)
    if copied:
        print("   [OK] Your HWID was copied to the clipboard!")
        print("        Paste it with Ctrl+V wherever you need.")
    else:
        print("   [!] Could not copy automatically.")
        print("       Select the code above and copy it manually.")
    print()
    print("  Checking license on the server...")
    print()

    # Use urllib (stdlib) to avoid depending on requests
    import json
    import urllib.parse
    import urllib.request

    url = f"{SERVER}/check?hwid={urllib.parse.quote(hwid)}"

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "InazumaHWID/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print("  [ERROR] Could not contact the server.")
        print(f"  Details: {e}")
        print()
        print(f"  URL tested: {url}")
        print()
        return

    allowed = data.get("allowed", False)
    print()
    if allowed:
        print("  ============================================")
        print("   Access Granted")
        name = data.get("user", "")
        if name:
            print(f"   Welcome, {name}!")
        print("  ============================================")
    else:
        print("  ============================================")
        print("   Access Blocked")
        print()
        print("   Your HWID is not authorized.")
        print()
        print(f"   {hwid}")
        print()
        if copy_to_clipboard(hwid):
            print("   [OK] HWID copied to the clipboard.")
            print("        Paste it with Ctrl+V and send it to the administrator.")
        else:
            print("   Send the code above to the administrator.")
        print("  ============================================")
    print()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        traceback.print_exc()
