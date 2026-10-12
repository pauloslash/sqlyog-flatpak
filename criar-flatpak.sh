#!/usr/bin/env bash
# Cria o Flatpak do SQLyog (Webyog) rodando a versão de Windows (64 bits)
# dentro do Wine, no mesmo modelo do com.fightcade.Fightcade do Flathub (base
# org.winehq.Wine).
#
# Este script é a fonte de tudo: ele (re)gera o manifesto, o lançador, o
# .desktop, o metainfo e os ícones, instala o setup do SQLyog num prefixo
# temporário do Wine, pega os arquivos instalados, compila e instala.
# Qualquer mudança no pacote deve ser feita AQUI e não nos arquivos gerados.
#
# O setup e o serial NÃO vêm com o código: o setup é proprietário e o serial
# é pessoal. Eles ficam em downloads/ (fora do git) e só entram no .flatpak.
#
# Uso:
#   ./criar-flatpak.sh                 mostra um menu com as opções (num terminal)
#   ./criar-flatpak.sh --completo      compila, instala (--user) e gera o .flatpak
#   ./criar-flatpak.sh --setup <arquivo.exe>
#                                      usa este setup (copiado para downloads/);
#                                      sem ele, usa o mais novo de downloads/
#   ./criar-flatpak.sh --nome <nome> --serial <serial>
#                                      registro do SQLyog (guardado em
#                                      downloads/registro.txt para as próximas vezes)
#   ./criar-flatpak.sh --sem-registro  compila sem o registro (versão de avaliação)
#   ./criar-flatpak.sh --so-gerar      só gera os arquivos do projeto (sem compilar)
#   ./criar-flatpak.sh --sem-instalar  compila mas não instala
#   ./criar-flatpak.sh --sem-bundle    não gera o arquivo .flatpak
#   ./criar-flatpak.sh --publicar      completo e publica no GitHub: o release do
#                                      código (tag flatpak, só o código) e o
#                                      SQLyog-<versão>-full.flatpak em rascunho privado
#   ./criar-flatpak.sh --publicar-codigo
#                                      só recria o release do código (sem compilar)
#   ./criar-flatpak.sh --instalar [arquivo]
#                                      só instala um .flatpak já gerado (padrão: o
#                                      SQLyog-<versão>-full.flatpak mais novo da pasta)
#
# A pasta de configuração (conexões, histórico, favoritos) fica em
# ~/.var/app/com.webyog.SQLyog/data/SQLyog; para usar outra pasta (ex.: um
# backup no Dropbox), veja ./vincular-config.sh.
#
# Precisa no sistema: flatpak, curl, 7z, file, python3 e o remote flathub
# (para --publicar também git e gh logado; para --instalar, só o flatpak).
# O resto (org.flatpak.Builder, SDK, base Wine) é instalado pelo script.
set -euo pipefail

APP_ID=com.webyog.SQLyog
WINE_BASE_VERSION=stable-25.08
RUNTIME_VERSION=25.08
# Chave do registro onde o SQLyog guarda o nome e o serial
CHAVE_REGISTRO='HKEY_CURRENT_USER\Software\{d58cb4b1-47f3-45cb-a209-f298d0c3f756}'

DIR=$(cd "$(dirname "$0")" && pwd)
ORIGEM=$PWD  # caminhos relativos passados nos argumentos
cd "$DIR"

GERAR_SO=0 INSTALAR=1 BUNDLE=1 PUBLICAR=0 SO_CODIGO=0 SEM_REGISTRO=0
SETUP_ARG="" NOME_ARG="" SERIAL_ARG=""

absoluto() {  # caminho relativo à pasta de onde o script foi chamado
    case $1 in /*) echo "$1" ;; *) echo "$ORIGEM/$1" ;; esac
}

# Fecha o SQLyog antes de instalar (senão a versão nova só vale depois de reabrir)
fechar_app() {
    flatpak ps --columns=application 2>/dev/null | grep -qx $APP_ID || return 0
    echo ">> Fechando o SQLyog"
    flatpak kill $APP_ID 2>/dev/null
    for _ in $(seq 20); do
        flatpak ps --columns=application 2>/dev/null | grep -qx $APP_ID || return 0
        sleep 0.5
    done
    echo "!! o SQLyog não fechou; feche-o e rode de novo" >&2
    exit 1
}

# Só instala um .flatpak já gerado (--instalar). Serve para outro PC: copie o
# .flatpak e este script e rode lá; precisa só do flatpak (o runtime e a base
# do Wine vêm do Flathub). Os dados do app em ~/.var/app não são tocados.
instalar_bundle() {  # instalar_bundle [arquivo]
    command -v flatpak >/dev/null || { echo "falta o comando: flatpak" >&2; exit 1; }
    local arq=${1:-}
    if [ -z "$arq" ]; then
        arq=$(find . -maxdepth 1 -name 'SQLyog-*-full.flatpak' -printf '%f\n' | sort -V | tail -1)
        [ -n "$arq" ] || { echo "nenhum SQLyog-*-full.flatpak em $DIR" >&2; exit 1; }
    fi
    [ -f "$arq" ] || { echo "arquivo não encontrado: $arq" >&2; exit 1; }
    flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    fechar_app
    echo ">> Instalando $(basename "$arq")"
    flatpak --user install -y --noninteractive --reinstall "$arq"
    echo
    echo "Pronto: SQLyog $(flatpak list --user --app --columns=application,version |
        awk -v id="$APP_ID" '$1 == id {print $2}') instalado"
    echo "  rodar: flatpak run $APP_ID (ou pelo menu de aplicativos)"
    echo "  usar outra pasta de configuração: ./vincular-config.sh <pasta>"
    exit 0
}
if [ "${1:-}" = --instalar ]; then
    instalar_bundle "${2:+$(absoluto "$2")}"
fi

# Sem argumentos, num terminal: menu. Fora de um terminal: faz o completo.
if [ $# -eq 0 ] && [ -t 0 ]; then
    cat <<'MENU'

  SQLyog - criar Flatpak
  ======================

  1) Completo
     Instala o setup de downloads/ num prefixo temporário, compila, instala
     neste PC e gera o arquivo .flatpak para instalar em outros PCs.

  2) Compilar e instalar
     Igual ao completo, mas sem gerar o arquivo .flatpak (mais rápido).
     Use para atualizar ou testar mudanças neste PC.

  3) Só gerar o arquivo .flatpak
     Compila e gera o .flatpak sem instalar neste PC. Use para levar o
     app para outro computador.

  4) Só gerar os arquivos do projeto
     Gera manifesto, lançador, .desktop, metainfo e ícones sem compilar.
     Use para conferir o que muda antes de compilar.

  5) Publicar no GitHub
     Igual ao completo e depois publica: o release do código (só o
     código, sem o SQLyog, substitui o anterior) e o .flatpak -full em
     rascunho privado (substitui só o rascunho da mesma versão; os de
     outras versões ficam).
     Precisa do gh logado e de tudo commitado e enviado (push).

  6) Publicar só o código no GitHub
     Recria o release do código apontando para o commit atual, sem
     compilar. O rascunho com o -full não é apagado.

  7) Só instalar um .flatpak já gerado
     Instala o SQLyog-<versão>-full.flatpak mais novo desta pasta, sem
     compilar. Use em outro PC (precisa só do flatpak).

  0) Sair

MENU
    read -rp "  Escolha uma opção [1]: " opcao
    case ${opcao:-1} in
        1) ;;
        2) BUNDLE=0 ;;
        3) INSTALAR=0 ;;
        4) GERAR_SO=1 ;;
        5) PUBLICAR=1 ;;
        6) PUBLICAR=1 SO_CODIGO=1 ;;
        7) instalar_bundle ;;
        0) exit 0 ;;
        *) echo "opção inválida: $opcao" >&2; exit 1 ;;
    esac
    echo
fi

while [ $# -gt 0 ]; do
    case $1 in
        --completo) ;;
        --setup) SETUP_ARG=$(absoluto "${2:?--setup precisa do arquivo}"); shift ;;
        --nome) NOME_ARG=${2?--nome precisa do nome}; shift ;;
        --serial) SERIAL_ARG=${2:?--serial precisa do serial}; shift ;;
        --sem-registro) SEM_REGISTRO=1 ;;
        --so-gerar) GERAR_SO=1 ;;
        --sem-instalar) INSTALAR=0 ;;
        --sem-bundle) BUNDLE=0 ;;
        --publicar) PUBLICAR=1 ;;
        --publicar-codigo) PUBLICAR=1 SO_CODIGO=1 ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "opção desconhecida: $1" >&2; exit 1 ;;
    esac
    shift
done

[ $PUBLICAR = 1 ] && GERAR_SO=0 BUNDLE=1

for c in flatpak curl 7z python3 file; do
    command -v "$c" >/dev/null || { echo "falta o comando: $c" >&2; exit 1; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Publicação no GitHub. São dois releases:
#   - flatpak: o código (o "latest"), sem anexo: sem o setup não há app. Tag
#     fixa, apagada e recriada a cada publicação;
#   - flatpak-full-<versão>: rascunho privado com o -full, que contém o
#     SQLyog (proprietário) e o serial. Um por versão: só o da mesma versão
#     é substituído; os de outras versões ficam.
# ---------------------------------------------------------------------------
if [ $PUBLICAR = 1 ]; then
    for c in git gh; do
        command -v "$c" >/dev/null || { echo "falta o comando: $c" >&2; exit 1; }
    done
    gh auth status >/dev/null 2>&1 || { echo "o gh não está logado (gh auth login)" >&2; exit 1; }
    if [ -n "$(git status --porcelain)" ]; then
        echo "há mudanças não commitadas; faça commit e push antes de publicar" >&2; exit 1
    fi
    git fetch -q origin
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}' 2>/dev/null)" ]; then
        echo "o commit atual não está no GitHub; faça push (ou pull) antes de publicar" >&2; exit 1
    fi
    COMMIT=$(git rev-parse HEAD)
    REPO_GH=$(gh repo view --json nameWithOwner -q .nameWithOwner)
fi

tipo_release() {  # tipo_release <tag>: codigo, full ou outro
    case $1 in
        flatpak) echo codigo ;;
        flatpak-full-*) echo full ;;
        *) echo outro ;;
    esac
}
# apagar_releases <tipo> [tag]: apaga os releases do tipo (de qualquer
# versão) ou, com a tag, só o daquela tag
apagar_releases() {
    echo ">> Apagando os releases antigos ($1${2:+: $2})"
    gh release list --limit 1000 --json tagName,isDraft -q '.[] | "\(.tagName) \(.isDraft)"' |
        while read -r tag rascunho; do
            [ "$(tipo_release "$tag")" = "$1" ] || continue
            [ -z "${2:-}" ] || [ "$tag" = "$2" ] || continue
            echo "   $tag"
            if [ "$rascunho" = true ]; then  # rascunho não tem tag
                gh release delete "$tag" --yes </dev/null
            else
                gh release delete "$tag" --yes --cleanup-tag </dev/null
                git tag -d "$tag" >/dev/null 2>&1 || true
            fi
        done
}
publicar_codigo() {
    apagar_releases codigo
    sed -e "s|@COMMIT@|${COMMIT:0:7}|g" -e "s|@REPO@|$REPO_GH|g" > "$TMP/notas-codigo.md" <<'NOTAS'
Flatpak do [SQLyog](https://webyog.com/product/sqlyog/) rodando a versão de Windows (64 bits) no Wine, no mesmo modelo do [com.fightcade.Fightcade](https://github.com/flathub/com.fightcade.Fightcade) do Flathub.

Este release tem **só o código** (commit @COMMIT@): o SQLyog é proprietário e não é distribuído aqui. Para gerar o seu `.flatpak`, use o seu próprio setup (e o seu serial, se tiver):

```sh
git clone https://github.com/@REPO@.git
cd sqlyog-flatpak
./criar-flatpak.sh --setup "SQLyog-<versão>_Setup_x64.exe" --nome "<nome>" --serial "<serial>"
```

Veja o README para os detalhes.
NOTAS
    echo ">> Publicando o release do código (flatpak)"
    gh release create flatpak --target "$COMMIT" --latest \
        --title "SQLyog Flatpak" --notes-file "$TMP/notas-codigo.md"
}
if [ $SO_CODIGO = 1 ]; then
    publicar_codigo
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Setup do SQLyog (fornecido pelo usuário) e registro
# ---------------------------------------------------------------------------
mkdir -p downloads
if [ -n "$SETUP_ARG" ]; then
    [ -f "$SETUP_ARG" ] || { echo "setup não encontrado: $SETUP_ARG" >&2; exit 1; }
    file -b "$SETUP_ARG" | grep -q 'Nullsoft Installer' ||
        { echo "não parece um setup do SQLyog (instalador NSIS): $SETUP_ARG" >&2; exit 1; }
    cmp -s "$SETUP_ARG" "downloads/$(basename "$SETUP_ARG")" ||
        cp "$SETUP_ARG" downloads/
    SETUP=downloads/$(basename "$SETUP_ARG")
else
    SETUP=$(find downloads -maxdepth 1 -iname 'SQLyog*Setup*x64*.exe' -printf '%p\n' | sort -V | tail -1)
    [ -n "$SETUP" ] || { echo "nenhum setup do SQLyog em downloads/; use --setup <arquivo.exe>" >&2; exit 1; }
fi
echo ">> Setup: $SETUP"
SETUP_SHA=$(sha256sum "$SETUP" | cut -d' ' -f1)

# Registro: nome e serial ficam em downloads/registro.txt (fora do git)
REGISTRO_TXT=downloads/registro.txt
if [ -n "$NOME_ARG$SERIAL_ARG" ]; then
    [ -n "$NOME_ARG" ] && [ -n "$SERIAL_ARG" ] ||
        { echo "--nome e --serial precisam vir juntos" >&2; exit 1; }
    printf 'nome=%s\nserial=%s\n' "$NOME_ARG" "$SERIAL_ARG" > "$REGISTRO_TXT"
    chmod 600 "$REGISTRO_TXT"
elif [ ! -f "$REGISTRO_TXT" ] && [ $SEM_REGISTRO = 0 ] && [ $GERAR_SO = 0 ] && [ -t 0 ]; then
    echo "   Registro do SQLyog (Enter em branco: sem registro, versão de avaliação)"
    read -rp "   Nome de registro: " NOME_ARG
    if [ -n "$NOME_ARG" ]; then
        read -rp "   Serial: " SERIAL_ARG
        printf 'nome=%s\nserial=%s\n' "$NOME_ARG" "$SERIAL_ARG" > "$REGISTRO_TXT"
        chmod 600 "$REGISTRO_TXT"
    fi
fi
REGISTRO_REG=""
if [ $SEM_REGISTRO = 0 ] && [ -f "$REGISTRO_TXT" ]; then
    # O SQLyog guarda cada caractere do nome e do serial com o código dobrado
    # (ex.: "dev" = c8,ca,ec) em HKCU\Software\{d58cb4b1-...}
    REGISTRO_REG=downloads/registro.reg
    python3 -I - "$REGISTRO_TXT" "$CHAVE_REGISTRO" > "$REGISTRO_REG" <<'EOF'
import sys
campos = dict(l.rstrip('\n').split('=', 1) for l in open(sys.argv[1]) if '=' in l)
def cod(txt):
    if not txt or not txt.isascii():
        sys.exit(f'registro inválido (só ASCII): {txt!r}')
    return ','.join(f'{ord(c) * 2:02x}' for c in txt)
print('REGEDIT4\n')
print(f'[{sys.argv[2]}]')
print(f'"Name"=hex:{cod(campos["nome"])}')
print(f'"InE"=hex:{cod(campos["serial"].strip())}')
print('"x64"=dword:00000001')
EOF
    echo "   registrado em nome de \"$(sed -n 's/^nome=//p' "$REGISTRO_TXT")\""
else
    echo "   sem registro (versão de avaliação)"
fi

# ---------------------------------------------------------------------------
# 2. Instala o setup num prefixo temporário do Wine (o Wine da própria base do
#    Flatpak) e pega a pasta instalada. Refeito só quando o setup muda.
# ---------------------------------------------------------------------------
INSTALADO=downloads/instalado
if [ "$(cat "$INSTALADO/.setup-sha256" 2>/dev/null)" != "$SETUP_SHA" ]; then
    echo ">> Instalando o setup no Wine (prefixo temporário)"
    flatpak install -y --noninteractive --user flathub org.winehq.Wine//$WINE_BASE_VERSION
    PFX=$DIR/downloads/.prefixo
    rm -rf "$PFX" "$INSTALADO"
    mkdir -p "$PFX"
    cp "$SETUP" "$PFX/setup.exe"
    # NSIS: /S silencioso; /D= pasta de destino (tem que ser o último argumento)
    flatpak run --filesystem="$DIR" --env=WINEPREFIX="$PFX/pfx" --env=WINEARCH=win64 \
        --env=WINEDEBUG=-all --env=DISPLAY=:invalid \
        --env=WINEDLLOVERRIDES='winemenubuilder.exe=d;mscoree=d;mshtml=d' \
        --command=sh org.winehq.Wine//$WINE_BASE_VERSION -c \
        'wineboot -i && wine "$1" /S "/D=C:\SQLyog"; wineserver -w' sh "$PFX/setup.exe" >/dev/null 2>&1
    [ -f "$PFX/pfx/drive_c/SQLyog/SQLyog.exe" ] ||
        { echo "!! o setup não instalou o SQLyog.exe (prefixo em $PFX)" >&2; exit 1; }
    # uninst.exe: o desinstalador do Windows, inútil aqui
    rm -f "$PFX/pfx/drive_c/SQLyog/uninst.exe"
    mv "$PFX/pfx/drive_c/SQLyog" "$INSTALADO"
    echo "$SETUP_SHA" > "$INSTALADO/.setup-sha256"
    rm -rf "$PFX"
fi

# Versão: a do nome do setup (13.1.1.24), senão a do SQLyog.exe (13.1.1)
VERSAO=$(basename "$SETUP" | grep -oE '[0-9]+(\.[0-9]+){2,}' | head -1 || true)
[ -n "$VERSAO" ] || VERSAO=$(python3 -I - "$INSTALADO/SQLyog.exe" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'\xbd\x04\xef\xfe')  # VS_FIXEDFILEINFO
ms, ls = struct.unpack_from('<II', d, i + 8)
print(f'{ms >> 16}.{ms & 0xffff}.{ls >> 16}.{ls & 0xffff}')
EOF
)
echo "   versão $VERSAO"

# ---------------------------------------------------------------------------
# 3. Ícones: extraídos do próprio SQLyog.exe (grupo 1: 16 a 128 px, 32 bits)
# ---------------------------------------------------------------------------
echo ">> Extraindo ícones do SQLyog.exe"
7z x -y -o"$TMP/rsrc" "$INSTALADO/SQLyog.exe" '.rsrc/*/GROUP_ICON/1' '.rsrc/*/ICON/*' >/dev/null
rm -rf icons && mkdir -p icons
python3 -I - "$TMP/rsrc/.rsrc" icons $APP_ID <<'EOF'
# Converte os ícones do grupo 1 (BMP 32 bits) para PNG, sem dependências
import glob, os, struct, sys, zlib
rsrc, saida, app = sys.argv[1:]
grupo = open(glob.glob(f'{rsrc}/*/GROUP_ICON/1')[0], 'rb').read()
for k in range(struct.unpack_from('<H', grupo, 4)[0]):
    ident = struct.unpack_from('<H', grupo, 6 + 14*k + 12)[0]
    ico = open(glob.glob(f'{rsrc}/*/ICON/{ident}.ico')[0], 'rb').read()
    dib = ico[struct.unpack_from('<I', ico, 18)[0]:]
    if dib[:4] == b'\x89PNG':
        png = dib
        lado = struct.unpack_from('>I', png, 16)[0]
    else:
        lado, alt2, _, bpp = struct.unpack_from('<iiHH', dib, 4)
        if bpp != 32:
            continue
        cab = struct.unpack_from('<I', dib, 0)[0]
        linhas = [dib[cab + 4*lado*y: cab + 4*lado*(y+1)] for y in range(lado)][::-1]
        cru = b''.join(b'\0' + b''.join(l[i+2::-1][:3] + l[i+3:i+4] for i in range(0, len(l), 4))
                       for l in linhas)
        bloco = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
        png = (b'\x89PNG\r\n\x1a\n' + bloco(b'IHDR', struct.pack('>IIBBBBB', lado, lado, 8, 6, 0, 0, 0))
               + bloco(b'IDAT', zlib.compress(cru, 9)) + bloco(b'IEND', b''))
    open(os.path.join(saida, f'{app}-{lado}.png'), 'wb').write(png)
EOF
ls icons

# ---------------------------------------------------------------------------
# 4. Fontes: o SQLyog (Win32/GDI) usa MS Shell Dlg (Tahoma, que o Wine tem),
#    Courier New (editor e grid) e, nas telas em HTML (htmlayout), Verdana,
#    Arial, Trebuchet MS e Times New Roman. São as "core fonts" da Microsoft,
#    dos instaladores originais (os mesmos do winetricks corefonts).
# ---------------------------------------------------------------------------
COREFONTS=downloads/corefonts
declare -A COREFONTS_SHA=(
    [arial32]=85297a4d146e9c87ac6f74822734bdee5f4b2a722d7eaa584b7f2cbf76f478f6
    [courie32]=bb511d861655dde879ae552eb86b134d6fae67cb58502e6ff73ec5d9151f3384
    [times32]=db56595ec6ef5d3de5c24994f001f03b2a13e37cee27bc25c58f6f43e8f807ab
    [trebuc32]=5a690d9bb8510be1b8b4fe49f1f2319651fe51bbe54775ddddd8ef0bd07fdac9
    [verdan32]=c1cb61255e363166794e47664e2f21af8e3a26cb6346eb8d2ae2fa85dd5aad96
)
mkdir -p "$COREFONTS"
for f in "${!COREFONTS_SHA[@]}"; do
    exe=$COREFONTS/$f.exe
    if ! { [ -f "$exe" ] && echo "${COREFONTS_SHA[$f]}  $exe" | sha256sum -c --status; }; then
        echo ">> Baixando a fonte $f.exe (core fonts da Microsoft)"
        curl -fL --progress-bar -o "$exe.part" "https://github.com/pushcx/corefonts/raw/master/$f.exe"
        echo "${COREFONTS_SHA[$f]}  $exe.part" | sha256sum -c --status ||
            { echo "!! SHA-256 de $f.exe não confere" >&2; exit 1; }
        mv "$exe.part" "$exe"
    fi
    7z e -y -o"$TMP/fontes" "$exe" '*.ttf' '*.TTF' >/dev/null
done
FONTES_SRCS=""
for f in "$TMP"/fontes/*; do
    nome=$(basename "$f" | tr 'A-Z' 'a-z')
    cmp -s "$f" "$COREFONTS/$nome" || cp "$f" "$COREFONTS/$nome"
    FONTES_SRCS+="      - type: file"$'\n'"        path: $COREFONTS/$nome"$'\n'"        dest: fontes"$'\n'
done

# ---------------------------------------------------------------------------
# 5. Lançador
# ---------------------------------------------------------------------------
mkdir -p scripts
cat > scripts/sqlyog.sh <<'EOF'
#!/bin/sh
# Gerado por criar-flatpak.sh: não edite à mão.
# Lançador do SQLyog no Wine. O programa fica em /app/sqlyog (só leitura); a
# configuração do usuário (o %APPDATA%\SQLyog do Windows: sqlyog.ini com as
# conexões, histórico, favoritos) fica em ~/.var/app/com.webyog.SQLyog/data/SQLyog,
# que pode ser um link para outra pasta (vincular-config.sh).
DATA=${XDG_DATA_HOME:-$HOME/.var/app/com.webyog.SQLyog/data}
CONFIG=$DATA/SQLyog

export WINEPREFIX=$DATA/wineprefix
export WINEARCH=win64
export WINEDEBUG=${WINEDEBUG:--all}
# winemenubuilder criaria atalhos/associações de arquivo inúteis no sandbox;
# mscoree/mshtml (Wine Mono/Gecko) não são usados pelo SQLyog
export WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree=d;mshtml=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"

erro() {
    echo "$1" >&2
    command -v zenity >/dev/null && zenity --error --title=SQLyog --text="$1" 2>/dev/null
    exit 1
}

# Mostra uma barra de progresso enquanto o comando roda
com_progresso() {
    texto=$1; shift
    "$@" >/dev/null 2>&1 &
    pid=$!
    if command -v zenity >/dev/null; then
        while kill -0 $pid 2>/dev/null; do echo "#$texto"; sleep 1; done |
            zenity --progress --pulsate --auto-close --no-cancel \
                --title=SQLyog --text="$texto" 2>/dev/null &
    fi
    echo "$texto"
    wait $pid
}

# --- Pasta de configuração ---
# Se for um link para uma pasta que o sandbox não enxerga, o SQLyog
# começaria do zero: avisa em vez de abrir.
if [ -L "$CONFIG" ] && [ ! -d "$CONFIG" ]; then
    erro "A pasta de configuração do SQLyog aponta para
$(readlink "$CONFIG"),
que não existe ou não tem permissão de acesso.

Rode de novo: ./vincular-config.sh \"$(readlink "$CONFIG")\""
fi
mkdir -p "$CONFIG"
# Configuração nova: o SQLyog só tem inglês, mas pergunta o idioma na
# primeira abertura se o sqlyog.ini não disser
[ -e "$CONFIG/sqlyog.ini" ] || printf '[UserInterface]\r\nLanguage=en\r\n' > "$CONFIG/sqlyog.ini"

# --- Prefixo do Wine: cria ou atualiza quando a versão do Wine muda ---
# DISPLAY inválido evita janelas do wineboot; o wineserver -w é obrigatório,
# senão o SQLyog reaproveita o explorer.exe sem display e não cria janelas.
# As marcas ficam dentro do prefixo: apagar o prefixo refaz tudo.
WINE_VERSAO=$(wine --version)
if [ "$(cat "$WINEPREFIX/.sy-wine-versao" 2>/dev/null)" != "$WINE_VERSAO" ]; then
    mkdir -p "$WINEPREFIX"
    com_progresso "Preparando o Wine ($WINE_VERSAO), pode levar um minuto..." \
        sh -c 'DISPLAY=:invalid wineboot -u && wineserver -w' &&
        [ -f "$WINEPREFIX/system.reg" ] ||
        erro "Não foi possível preparar o Wine em $WINEPREFIX."
    echo "$WINE_VERSAO" > "$WINEPREFIX/.sy-wine-versao"
fi

# --- Fontes (core fonts da Microsoft) e registro do SQLyog ---
# O Wine carrega as fontes do C:\windows\Fonts do prefixo. O sqlyog.reg tem o
# idioma (gravado pelo instalador) e, no pacote registrado, o nome e o serial.
CONFIG_VERSAO="1 $(cat /app/share/sqlyog/*.reg | md5sum | cut -c1-8)"
if [ "$(cat "$WINEPREFIX/.sy-config" 2>/dev/null)" != "$CONFIG_VERSAO" ]; then
    echo "Instalando as fontes e o registro no prefixo"
    mkdir -p "$WINEPREFIX/drive_c/windows/Fonts"
    cp -f /app/share/sqlyog/fontes/*.ttf "$WINEPREFIX/drive_c/windows/Fonts/"
    for reg in /app/share/sqlyog/*.reg; do
        wine regedit "$reg" || exit 1
    done
    wineserver -w && echo "$CONFIG_VERSAO" > "$WINEPREFIX/.sy-config"
fi

# --- %APPDATA%\SQLyog -> pasta de configuração ---
ROAMING=$WINEPREFIX/drive_c/users/$USER/AppData/Roaming
mkdir -p "$ROAMING"
if [ -d "$ROAMING/SQLyog" ] && [ ! -L "$ROAMING/SQLyog" ]; then
    # Criada pelo SQLyog antes do link: junta na pasta de configuração
    cp -a --update=none "$ROAMING/SQLyog/." "$CONFIG/" && rm -rf "$ROAMING/SQLyog"
fi
[ "$(readlink "$ROAMING/SQLyog")" = "$CONFIG" ] || ln -sfn "$CONFIG" "$ROAMING/SQLyog"

case $1 in
    winecfg|regedit|taskmgr|explorer) exec wine "$@" ;;
    winetricks) shift; exec winetricks "$@" ;;
    shell) exec /bin/sh ;;
esac

cd /app/sqlyog || exit 1
wine /app/sqlyog/SQLyog.exe "$@"
# Espera todos os processos do Wine terminarem para o sandbox não ser
# encerrado no meio (ex.: o SQLyog salvando a sessão ao fechar)
wineserver -w
EOF
chmod +x scripts/sqlyog.sh

# Idioma escolhido no instalador (1033 = inglês, o único que o SQLyog tem)
cat > scripts/sqlyog.reg <<'EOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\SQLyog]
"Language"="1033"
EOF

# ---------------------------------------------------------------------------
# 6. .desktop e metainfo
# ---------------------------------------------------------------------------
cat > $APP_ID.desktop <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=SQLyog
Comment=Cliente gráfico de MySQL e MariaDB
Keywords=mysql;mariadb;sql;database;banco de dados;webyog;
Exec=sqlyog
Icon=$APP_ID
Terminal=false
Categories=Development;Database;
StartupWMClass=sqlyog.exe
EOF

cat > $APP_ID.metainfo.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$APP_ID</id>
  <name>SQLyog</name>
  <summary>Cliente gráfico de MySQL e MariaDB</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>LicenseRef-proprietary</project_license>
  <developer id="com.webyog">
    <name>Webyog</name>
  </developer>
  <description>
    <p>
      SQLyog é uma ferramenta de administração de MySQL e MariaDB. Este pacote
      roda a versão de Windows através do Wine.
    </p>
  </description>
  <launchable type="desktop-id">$APP_ID.desktop</launchable>
  <url type="homepage">https://webyog.com/product/sqlyog/</url>
  <content_rating type="oars-1.1"/>
  <releases>
    <release version="$VERSAO" date="$(date +%F)"/>
  </releases>
</component>
EOF

# ---------------------------------------------------------------------------
# 7. Manifesto
# ---------------------------------------------------------------------------
ICONES_CMDS="" ICONES_SRCS=""
for f in icons/*.png; do
    tam=${f##*-}; tam=${tam%.png}
    ICONES_CMDS+="      - install -Dm644 $(basename "$f") /app/share/icons/hicolor/${tam}x${tam}/apps/$APP_ID.png"$'\n'
    ICONES_SRCS+="      - type: file"$'\n'"        path: $f"$'\n'
done
REGISTRO_CMDS="" REGISTRO_SRCS=""
if [ -n "$REGISTRO_REG" ]; then
    REGISTRO_CMDS="      - install -Dm644 registro.reg /app/share/sqlyog/registro.reg"$'\n'
    REGISTRO_SRCS="      - type: file"$'\n'"        path: $REGISTRO_REG"$'\n'
fi

cat > $APP_ID.yml <<EOF
# Gerado por criar-flatpak.sh: não edite à mão.
app-id: $APP_ID
base: org.winehq.Wine
base-version: $WINE_BASE_VERSION
runtime: org.freedesktop.Platform
runtime-version: '$RUNTIME_VERSION'
sdk: org.freedesktop.Sdk
command: sqlyog
tags:
  - proprietary

# O SQLyog é só 64 bits, mas o Wine da base precisa da parte de 32 bits para
# iniciar (wineboot, regedit). Wine Mono/Gecko não são usados.
inherit-extensions:
  - org.freedesktop.Platform.Compat.i386
  - org.freedesktop.Platform.GL32

finish-args:
  - --share=ipc
  - --socket=x11
  - --share=network
  - --allow=multiarch
  - --env=LD_LIBRARY_PATH=/app/lib:/app/lib32
  # Abrir/salvar scripts .sql, backups e exportações em qualquer pasta
  - --filesystem=home
  - --talk-name=org.freedesktop.Notifications

modules:
  - name: sqlyog
    buildsystem: simple
    build-commands:
      - mkdir -p /app/sqlyog
      - cp -a sqlyog/. /app/sqlyog/
      - rm -f /app/sqlyog/.setup-sha256
      - install -Dm755 sqlyog.sh /app/bin/sqlyog
      - install -Dm644 sqlyog.reg /app/share/sqlyog/sqlyog.reg
${REGISTRO_CMDS}      - install -Dm644 -t /app/share/sqlyog/fontes fontes/*.ttf
      - install -Dm644 $APP_ID.desktop /app/share/applications/$APP_ID.desktop
      - install -Dm644 $APP_ID.metainfo.xml /app/share/metainfo/$APP_ID.metainfo.xml
${ICONES_CMDS}    sources:
      - type: dir
        path: $INSTALADO
        dest: sqlyog
      - type: file
        path: scripts/sqlyog.sh
      - type: file
        path: scripts/sqlyog.reg
${REGISTRO_SRCS}${FONTES_SRCS}      - type: file
        path: $APP_ID.desktop
      - type: file
        path: $APP_ID.metainfo.xml
${ICONES_SRCS}
EOF

echo ">> Arquivos gerados para a versão $VERSAO"
[ $GERAR_SO = 1 ] && exit 0

# ---------------------------------------------------------------------------
# 8. Compila (org.flatpak.Builder), instala e gera o bundle
# ---------------------------------------------------------------------------
echo ">> Instalando dependências de build (se faltarem)"
flatpak install -y --noninteractive --user flathub \
    org.flatpak.Builder \
    org.freedesktop.Sdk//$RUNTIME_VERSION \
    org.freedesktop.Platform//$RUNTIME_VERSION \
    org.freedesktop.Platform.Compat.i386//$RUNTIME_VERSION \
    org.freedesktop.Platform.GL32.default//$RUNTIME_VERSION \
    org.winehq.Wine//$WINE_BASE_VERSION

REPO=repo
ARQ=SQLyog-$VERSAO-full.flatpak
[ -n "$REGISTRO_REG" ] || ARQ=SQLyog-$VERSAO.flatpak

# Sem --install: instalando de dentro do sandbox do Builder, o .desktop
# exportado ganha Exec=/app/bin/flatpak (caminho do Builder) e some do menu
BUILDER_ARGS=(--force-clean --user --repo=$REPO --disable-rofiles-fuse)

echo ">> Compilando"
# O Builder repassa o XDG_DATA_HOME do sandbox dele para o "flatpak" do host,
# que aí procura a instalação --user (SDK, base Wine) em
# ~/.var/app/org.flatpak.Builder/data/flatpak. Esse caminho precisa ser um
# diretório (o bwrap monta a instalação real em cima dele dentro do sandbox),
# então ele recebe symlinks para cada entrada da instalação real.
USER_FLATPAK=${XDG_DATA_HOME:-$HOME/.local/share}/flatpak
BUILDER_FLATPAK=$HOME/.var/app/org.flatpak.Builder/data/flatpak
[ -L "$BUILDER_FLATPAK" ] && rm "$BUILDER_FLATPAK"
mkdir -p "$BUILDER_FLATPAK"
for item in "$USER_FLATPAK"/* "$USER_FLATPAK"/.changed; do
    [ -e "$item" ] || continue
    dest=$BUILDER_FLATPAK/$(basename "$item")
    [ -L "$dest" ] && continue
    rm -rf "$dest"
    ln -s "$item" "$dest"
done
# O repo criado pelo ostree exige 3% do disco livre e o export falha com
# "min-free-space-percent would be exceeded". Usa o mesmo limite fixo da
# instalação --user do flatpak (500MB).
flatpak run --filesystem="$DIR" --cwd="$DIR" --command=ostree org.flatpak.Builder \
    init --repo=$REPO --mode=archive-z2
flatpak run --filesystem="$DIR" --cwd="$DIR" --command=ostree org.flatpak.Builder \
    config --repo=$REPO set core.min-free-space-size 500MB
# --filesystem: o sandbox do Builder não enxerga pastas fora da home (ex.: /tmp)
flatpak run --filesystem="$DIR" --cwd="$DIR" --command=flatpak-builder org.flatpak.Builder \
    "${BUILDER_ARGS[@]}" build-dir $APP_ID.yml

if [ $INSTALAR = 1 ]; then
    fechar_app
    echo ">> Instalando (--user) a partir do repo local"
    flatpak --user remote-add --if-not-exists --no-gpg-verify sqlyog-local "$DIR/repo"
    flatpak --user install -y --noninteractive --reinstall sqlyog-local $APP_ID
fi

if [ $BUNDLE = 1 ]; then
    echo ">> Gerando $ARQ"
    flatpak build-bundle $REPO "$ARQ" $APP_ID \
        --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo
fi

if [ $PUBLICAR = 1 ]; then
    SHA=$(sha256sum "$ARQ" | cut -d' ' -f1)
    # Só o rascunho desta versão: os de outras versões continuam disponíveis
    apagar_releases full "flatpak-full-$VERSAO"
    # Contém o SQLyog (proprietário) e o serial: só em rascunho (visível para
    # quem tem acesso de escrita ao repositório)
    sed -e "s|@VERSAO@|$VERSAO|g" -e "s|@COMMIT@|${COMMIT:0:7}|g" -e "s|@SHA@|$SHA|g" \
        -e "s|@ARQ@|$ARQ|g" -e "s|@REPO@|$REPO_GH|g" > "$TMP/notas-full.md" <<'NOTAS'
**Rascunho privado: não publicar.** Contém o SQLyog (proprietário) já registrado; rascunhos só ficam visíveis para quem tem acesso de escrita ao repositório.

`@ARQ@`, gerado pelo `criar-flatpak.sh` do commit @COMMIT@ (SQLyog @VERSAO@).
SHA-256: `@SHA@`

Baixar (precisa estar logado no `gh`):

```sh
gh release download flatpak-full-@VERSAO@ -R @REPO@ -p '*.flatpak'
./criar-flatpak.sh --instalar
```
NOTAS
    echo ">> Publicando o .flatpak em rascunho (flatpak-full-$VERSAO)"
    gh release create "flatpak-full-$VERSAO" --draft --target "$COMMIT" \
        --title "$ARQ (privado)" --notes-file "$TMP/notas-full.md"
    # O upload às vezes trava (ex.: a internet cai); com limite de tempo e até
    # 3 tentativas (--clobber substitui o envio incompleto)
    for n in 1 2 3; do
        timeout 420 gh release upload "flatpak-full-$VERSAO" "$ARQ" --clobber && break
        echo "!! envio de $ARQ falhou (tentativa $n de 3)" >&2
        [ $n = 3 ] && exit 1
    done
    publicar_codigo
fi

echo
echo "Pronto: SQLyog $VERSAO"
[ $INSTALAR = 1 ] && echo "  rodar: flatpak run $APP_ID (ou pelo menu de aplicativos)"
[ $BUNDLE = 1 ] && echo "  arquivo: $DIR/$ARQ"
echo "  usar outra pasta de configuração: ./vincular-config.sh <pasta>"
