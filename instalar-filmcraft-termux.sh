#!/data/data/com.termux/files/usr/bin/bash
# FilmCraft local launcher for Termux / Termux:X11.
# The release ZIP is downloaded automatically when it is not already present.
# The app is a static web app; it is not a native X11 executable.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

APP_VERSION="0.8.0"
ZIP_NAME="filmcraft-web-${APP_VERSION}-webgl-fallback.zip"
TOP_DIR="filmcraft-web-${APP_VERSION}"
MODE="auto"
ZIP_ARG=""

usage() {
  cat <<'HELP'
Uso:
  bash instalar-filmcraft-termux.sh [--auto|--x11|--android] [caminho/filmcraft-web-0.8.0-webgl-fallback.zip]

--auto     Usa um navegador X11 se já estiver disponível; senão, o navegador Android.
--x11      Exige Termux:X11 e Chromium/Firefox disponíveis no ambiente gráfico.
--android  Abre o endereço local no navegador normal do Android.

Renderer:
  FILMCRAFT_RENDERER=webgl (padrão) ou FILMCRAFT_RENDERER=cpu
Porta:
  FILMCRAFT_PORT=8765 (padrão)

Se nenhum ZIP for informado/encontrado, o pacote v0.8.0 com fallback WebGL2 é baixado automaticamente.
O servidor só escuta em localhost. Ctrl+C encerra o servidor.
HELP
}

fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--auto" || "${1:-}" == "--x11" || "${1:-}" == "--android" ]]; then
  MODE="${1#--}"
  shift
fi
if (( $# > 1 )); then usage >&2; fail "Informe no máximo um caminho para o ZIP."; fi
ZIP_ARG="${1:-}"

if ! command -v python3 >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
  if command -v pkg >/dev/null 2>&1; then
    printf 'Instalando dependências necessárias no Termux (Python e unzip)...\n'
    pkg install -y python unzip || fail "Não consegui instalar Python/unzip. Rode: pkg install python unzip"
  else
    fail "Faltam Python e/ou unzip. No Termux, rode: pkg install python unzip"
  fi
fi
command -v python3 >/dev/null 2>&1 || fail "Python não encontrado. Instale com: pkg install python"
command -v unzip >/dev/null 2>&1 || fail "unzip não encontrado. Instale com: pkg install unzip"

if [[ -n "$ZIP_ARG" ]]; then
  ZIP_PATH="$ZIP_ARG"
else
  ZIP_PATH=""
  for candidate in "$SCRIPT_DIR/$ZIP_NAME" "$HOME/$ZIP_NAME" "$HOME/storage/downloads/$ZIP_NAME"; do
    if [[ -f "$candidate" ]]; then ZIP_PATH="$candidate"; break; fi
  done
fi
if [[ -z "$ZIP_PATH" ]]; then
  ZIP_PATH="$HOME/.cache/filmcraft-termux/$ZIP_NAME"
  mkdir -p "$(dirname -- "$ZIP_PATH")"
  if [[ ! -s "$ZIP_PATH" ]]; then
    printf 'Baixando FilmCraft v%s automaticamente...\n' "$APP_VERSION"
    python3 - "$ZIP_PATH" "https://raw.githubusercontent.com/anonymous3210/FilmCraft-Localhost/main/${ZIP_NAME}" <<'PY'
import os, shutil, sys, urllib.request, zipfile

destination, url = sys.argv[1:]
tmp = destination + ".part"
try:
    request = urllib.request.Request(url, headers={"User-Agent": "FilmCraft-Termux-Installer/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response, open(tmp, "wb") as output:
        shutil.copyfileobj(response, output)
    if os.path.getsize(tmp) < 1024 or not zipfile.is_zipfile(tmp):
        raise RuntimeError("o download não parece ser um ZIP válido")
    os.replace(tmp, destination)
except Exception as error:
    try:
        os.remove(tmp)
    except FileNotFoundError:
        pass
    raise SystemExit(f"Falha ao baixar o ZIP: {error}\nVerifique sua conexão e tente novamente.")
PY
  else
    printf 'Usando ZIP já baixado: %s\n' "$ZIP_PATH"
  fi
fi
[[ -n "$ZIP_PATH" && -f "$ZIP_PATH" ]] || fail "Não foi possível obter $ZIP_NAME. Tente novamente com internet ativa."

ZIP_LIST="$(unzip -Z1 "$ZIP_PATH")" || fail "Não consegui ler o ZIP: $ZIP_PATH"
if ! grep -Fxq "$TOP_DIR/index.html" <<<"$ZIP_LIST"; then
  fail "O ZIP não contém $TOP_DIR/index.html."
fi
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  case "$entry" in
    "$TOP_DIR"|"$TOP_DIR/"|"$TOP_DIR"/*) ;;
    *) fail "Caminho inesperado dentro do ZIP: $entry" ;;
  esac
  case "/${entry%/}/" in
    */../*|*/./*|*//* ) fail "Caminho inseguro dentro do ZIP: $entry" ;;
  esac
done <<<"$ZIP_LIST"

DATA_DIR="$HOME/.local/share/filmcraft-termux"
APP_DIR="$DATA_DIR/$TOP_DIR"
LOG_DIR="$HOME/.cache/filmcraft-termux"
mkdir -p "$DATA_DIR" "$LOG_DIR"
[[ ! -L "$APP_DIR" ]] || fail "O destino de extração é um link simbólico: $APP_DIR"
unzip -oq "$ZIP_PATH" -d "$DATA_DIR"
for required in index.html filmcraft_web.js filmcraft_web_bg.wasm audio-worklet.js favicon.png; do
  [[ -f "$APP_DIR/$required" ]] || fail "Arquivo ausente após extrair: $required"
done

PORT="${FILMCRAFT_PORT:-8765}"
[[ "$PORT" =~ ^[0-9]+$ ]] || fail "FILMCRAFT_PORT precisa ser um número."
PORT=$((10#$PORT))
(( PORT >= 1024 && PORT <= 65535 )) || fail "Use uma porta entre 1024 e 65535."
BASE_URL="http://localhost:${PORT}/"

port_is_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

server_already_serves_filmcraft() {
  python3 - "$BASE_URL" <<'PY'
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=2) as response:
        body = response.read(8192).decode("utf-8", "replace")
    sys.exit(0 if "<title>FilmCraft</title>" in body else 1)
except Exception:
    sys.exit(1)
PY
}

SERVER_PID=""
SERVER_STARTED=0
REUSE_SERVER=0
if ! port_is_free "$PORT"; then
  if server_already_serves_filmcraft; then
    REUSE_SERVER=1
  elif [[ -n "${FILMCRAFT_PORT:-}" ]]; then
    fail "A porta $PORT já está ocupada. Escolha outra: FILMCRAFT_PORT=8766."
  else
    found=0
    for ((candidate=PORT+1; candidate<=PORT+30 && candidate<=65535; candidate++)); do
      PORT=$candidate
      BASE_URL="http://localhost:${PORT}/"
      if port_is_free "$PORT"; then found=1; break; fi
      if server_already_serves_filmcraft; then REUSE_SERVER=1; found=1; break; fi
    done
    (( found == 1 )) || fail "Não encontrei uma porta livre entre 8765 e 8795. Defina FILMCRAFT_PORT."
    printf 'A porta inicial está ocupada; usando %s.\n' "$PORT"
  fi
fi
if (( REUSE_SERVER == 1 )); then
  printf 'Já existe FilmCraft em %s; vou reutilizar esse servidor.\n' "$BASE_URL"
else
  SERVER_LOG="$LOG_DIR/server.log"
  python3 - "$APP_DIR" "$PORT" >"$SERVER_LOG" 2>&1 <<'PY' &
import os, sys, mimetypes
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

mimetypes.add_type("application/wasm", ".wasm", strict=True)
mimetypes.add_type("text/javascript", ".js", strict=True)

class FilmCraftHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        path = urlsplit(self.path).path
        if path.endswith(".wasm") or path.endswith("filmcraft_web.js"):
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        else:
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

handler = partial(FilmCraftHandler, directory=sys.argv[1])
server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), handler)
server.serve_forever()
PY
  SERVER_PID=$!
  SERVER_STARTED=1
  ready=0
  for ((attempt=0; attempt<30; attempt++)); do
    if server_already_serves_filmcraft; then ready=1; break; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
    sleep 0.25
  done
  (( ready == 1 )) || { cat "$SERVER_LOG" >&2; fail "O servidor local não iniciou."; }
fi

# Fail early if a browser would receive the WASM with the wrong MIME type.
python3 - "$BASE_URL" <<'PY'
import sys
from urllib.request import Request, urlopen
base = sys.argv[1]
checks = {
    "": "text/html",
    "filmcraft_web.js?v=check": "text/javascript",
    "filmcraft_web_bg.wasm?v=check": "application/wasm",
    "audio-worklet.js": "text/javascript",
    "favicon.png": "image/png",
}
for path, expected in checks.items():
    request = Request(base + path, method="HEAD")
    with urlopen(request, timeout=10) as response:
        actual = response.headers.get_content_type()
        if response.status != 200 or actual != expected:
            raise SystemExit(f"Resposta inesperada para /{path}: HTTP {response.status}, {actual}; esperado {expected}")
print("Página, JavaScript, WebAssembly, áudio e favicon validados.")
PY

RENDERER="${FILMCRAFT_RENDERER:-webgl}"
case "$RENDERER" in
  webgl) APP_URL="${BASE_URL}?webgl" ;;
  cpu) APP_URL="${BASE_URL}?cpu" ;;
  *) fail "FILMCRAFT_RENDERER deve ser webgl ou cpu." ;;
esac

X11_BROWSER=()
if [[ -n "${FILMCRAFT_X11_BROWSER:-}" ]]; then
  read -r -a X11_BROWSER <<<"$FILMCRAFT_X11_BROWSER"
else
  for browser in chromium chromium-browser firefox firefox-esr; do
    if command -v "$browser" >/dev/null 2>&1; then
      X11_BROWSER=("$(command -v "$browser")")
      break
    fi
  done
fi

SERVER_LOG="$LOG_DIR/server.log"
BROWSER_PID=""
X11_PID=""
X11_STARTED=0
cleanup() {
  if [[ -n "$BROWSER_PID" ]]; then kill "$BROWSER_PID" 2>/dev/null || true; fi
  if (( X11_STARTED == 1 )) && [[ -n "$X11_PID" ]]; then kill "$X11_PID" 2>/dev/null || true; fi
  if (( SERVER_STARTED == 1 )) && [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

open_android_browser() {
  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "$APP_URL" >/dev/null 2>&1 || true
  elif command -v am >/dev/null 2>&1; then
    am start -a android.intent.action.VIEW -d "$APP_URL" >/dev/null 2>&1 || true
  else
    printf 'Abra manualmente no navegador Android: %s\n' "$APP_URL"
  fi
}

can_use_x11=0
if (( ${#X11_BROWSER[@]} > 0 )); then
  if [[ -n "${DISPLAY:-}" ]] || command -v termux-x11 >/dev/null 2>&1; then
    can_use_x11=1
  fi
fi

if [[ "$MODE" == "x11" || ( "$MODE" == "auto" && $can_use_x11 == 1 ) ]]; then
  if (( ${#X11_BROWSER[@]} == 0 )); then
    if [[ "$MODE" == "x11" ]]; then
      fail "Não achei Chromium/Firefox no PATH. Ative x11-repo e instale um navegador X11, por exemplo: pkg install x11-repo && pkg install chromium"
    fi
    printf 'Sem Chromium/Firefox para X11; abrindo no navegador Android.\n'
    open_android_browser
  else
    if [[ -z "${DISPLAY:-}" ]]; then
      command -v termux-x11 >/dev/null 2>&1 || fail "Termux:X11 não está instalado. Veja https://github.com/termux/termux-x11"
      DISPLAY="${FILMCRAFT_DISPLAY:-:1}"
      export DISPLAY
      termux-x11 "$DISPLAY" >>"$LOG_DIR/x11.log" 2>&1 &
      X11_PID=$!
      X11_STARTED=1
      sleep 2
    fi
    printf 'Abrindo FilmCraft no navegador X11 (%s): %s\n' "$DISPLAY" "$APP_URL"
    "${X11_BROWSER[@]}" --new-window "$APP_URL" >>"$LOG_DIR/browser.log" 2>&1 &
    BROWSER_PID=$!
  fi
elif [[ "$MODE" == "android" || "$MODE" == "auto" ]]; then
  printf 'Abrindo FilmCraft no navegador Android: %s\n' "$APP_URL"
  open_android_browser
else
  fail "Modo inválido: $MODE"
fi

printf '\nServidor local ativo em %s\n' "$BASE_URL"
printf 'Mantenha este Termux aberto. Ctrl+C encerra o servidor.\n'
printf 'Log do servidor: %s\n' "$SERVER_LOG"
while [[ -z "$SERVER_PID" ]] || kill -0 "$SERVER_PID" 2>/dev/null; do
  sleep 2
done
fail "O servidor local foi encerrado inesperadamente."
