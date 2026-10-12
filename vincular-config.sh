#!/usr/bin/env bash
# Faz o SQLyog do Flatpak usar uma pasta de configuração sua (ex.: um backup
# no Dropbox com o sqlyog.ini, as conexões e os favoritos).
#
# A configuração do SQLyog (o %APPDATA%\SQLyog do Windows) fica em
#   ~/.var/app/com.webyog.SQLyog/data/SQLyog
# Este script troca essa pasta por um link simbólico para a pasta escolhida e
# dá ao Flatpak permissão de leitura e escrita nela (flatpak override).
#
# Uso:
#   ./vincular-config.sh <pasta>     liga a configuração à pasta
#   ./vincular-config.sh --desfazer  volta a usar a pasta própria do Flatpak
#   ./vincular-config.sh --status    mostra para onde a configuração aponta
#
# Se já houver uma configuração real em data/SQLyog, ela é guardada em
# data/SQLyog_BKP (ou SQLyog_BKP-<data>), nunca apagada. Feche o SQLyog antes.
set -euo pipefail

APP_ID=com.webyog.SQLyog
DATA=$HOME/.var/app/$APP_ID/data
CONFIG=$DATA/SQLyog

uso() { sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }
[ $# -eq 1 ] || uso 1

command -v flatpak >/dev/null || { echo "falta o comando: flatpak" >&2; exit 1; }

if flatpak ps --columns=application 2>/dev/null | grep -qx $APP_ID; then
    echo "o SQLyog está aberto; feche-o e rode de novo" >&2
    exit 1
fi

# Guarda a pasta real (se tiver algo) em SQLyog_BKP, sem sobrescrever outro backup
guardar_atual() {
    [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] || return 0
    if [ -z "$(ls -A "$CONFIG")" ]; then
        rmdir "$CONFIG"
        return 0
    fi
    local bkp=${CONFIG}_BKP
    [ -e "$bkp" ] && bkp=${CONFIG}_BKP-$(date +%Y%m%d-%H%M%S)
    mv "$CONFIG" "$bkp"
    echo "Configuração anterior guardada em $bkp"
}

# Tira a permissão dada antes a outra pasta (a do link atual)
tirar_permissao() {
    local alvo
    alvo=$(readlink "$CONFIG" 2>/dev/null) || return 0
    flatpak override --user --nofilesystem="$alvo" $APP_ID
}

case $1 in
    -h|--help) uso ;;
    --status)
        if [ -L "$CONFIG" ]; then
            echo "$CONFIG -> $(readlink "$CONFIG")"
            [ -d "$CONFIG" ] || echo "!! a pasta de destino não existe" >&2
        else
            echo "$CONFIG (pasta própria do Flatpak)"
        fi
        echo "Permissões extras: $(flatpak override --user --show $APP_ID |
            sed -n 's/^filesystems=//p')"
        ;;
    --desfazer)
        if [ ! -L "$CONFIG" ]; then
            echo "a configuração já é a pasta própria do Flatpak: $CONFIG"
            exit 0
        fi
        tirar_permissao
        rm "$CONFIG"
        if [ -d "${CONFIG}_BKP" ]; then
            mv "${CONFIG}_BKP" "$CONFIG"
            echo "Restaurada a configuração de ${CONFIG}_BKP"
        else
            mkdir -p "$CONFIG"
            echo "O SQLyog volta a usar $CONFIG (vazia)"
        fi
        ;;
    -*) echo "opção desconhecida: $1" >&2; uso 1 ;;
    *)
        PASTA=$(realpath -m "$1")
        [ -d "$PASTA" ] || { echo "pasta não encontrada: $PASTA" >&2; exit 1; }
        [ -w "$PASTA" ] || { echo "sem permissão de escrita em $PASTA" >&2; exit 1; }
        case $PASTA/ in
            "$HOME/.var/app/$APP_ID/"*)
                echo "a pasta não pode ficar dentro de ~/.var/app/$APP_ID" >&2; exit 1 ;;
        esac
        mkdir -p "$DATA"
        tirar_permissao
        guardar_atual
        # Leitura e escrita para o Flatpak (o caminho tem que ser o mesmo
        # dentro do sandbox, por isso o link é absoluto)
        flatpak override --user --filesystem="$PASTA" $APP_ID
        ln -sfn "$PASTA" "$CONFIG"
        echo "Pronto: $CONFIG -> $PASTA"
        [ -f "$PASTA/sqlyog.ini" ] || echo "(a pasta ainda não tem sqlyog.ini: o SQLyog cria na primeira abertura)"
        ;;
esac
