# SQLyog em Flatpak

Empacota a versão de Windows (64 bits) do [SQLyog](https://webyog.com/product/sqlyog/)
para Linux, rodando no Wine, no mesmo modelo do
[com.fightcade.Fightcade](https://github.com/flathub/com.fightcade.Fightcade):
base `org.winehq.Wine` (stable-25.08) e 32 bits herdados como extensões.

**Este repositório tem só o código.** O SQLyog é proprietário e não é
distribuído aqui: você fornece o seu setup (e o seu serial, se tiver) e o
script gera o `.flatpak` na sua máquina.

## Gerar na sua máquina

**Tudo é gerado por `criar-flatpak.sh`.** Ele instala o setup num prefixo
temporário do Wine, pega a pasta instalada, gera o manifesto, o lançador, o
.desktop, o metainfo e os ícones, e compila. Para mudar o pacote, mude o
script e rode-o de novo; os arquivos gerados são sobrescritos.

Precisa no sistema: `flatpak` (com o remote flathub), `curl`, `7z`, `file` e
`python3`, além de internet (para `--publicar`, também `git` e o `gh` logado).

```sh
# primeira vez: o setup e o registro (guardados em downloads/, fora do git)
./criar-flatpak.sh --setup "SQLyog 13.1.1.24_Setup_x64.exe" --nome "<nome>" --serial "<serial>"

./criar-flatpak.sh                   # menu (na primeira vez pede setup, nome e serial antes)
./criar-flatpak.sh --completo        # compila, instala (--user) e gera o .flatpak
./criar-flatpak.sh --so-gerar        # só gera os arquivos
./criar-flatpak.sh --sem-instalar    # compila sem instalar
./criar-flatpak.sh --sem-bundle      # não gera o .flatpak
./criar-flatpak.sh --sem-registro    # sem o serial (versão de avaliação)
./criar-flatpak.sh --publicar        # completo + publica no GitHub (opção 5 do menu)
./criar-flatpak.sh --publicar-codigo # só o release do código (opção 6)
./criar-flatpak.sh --instalar        # só instala o SQLyog-<versão>-full.flatpak mais novo da pasta (opção 7)
flatpak run com.webyog.SQLyog
```

Sem argumentos, na primeira vez (ex.: em outro PC, logo depois do `git
clone`), o script pede o caminho do setup (pode arrastar o arquivo para o
terminal), o nome e o serial, e só depois mostra o menu. Nas próximas vezes o
menu abre direto, com "Tudo disponível" e o setup e o nome em uso; a opção 8
troca o setup (para gerar outra versão) ou o registro (Enter mantém o atual).

Tudo fica em `downloads/` (fora do git): o setup copiado, o nome dele em
`setup.txt` (o escolhido por último; sem ele, vale o de versão mais alta) e
o nome/serial em `registro.txt`. Com argumentos, `--setup` e
`--nome`/`--serial` fazem o mesmo; sem o `registro.txt`, o script pergunta (num
terminal) e, em branco, compila sem registro e o arquivo sai sem o `-full`
no nome.

Para instalar em outro PC, copie o `SQLyog-<versão>-full.flatpak` junto com o
`criar-flatpak.sh` e rode `./criar-flatpak.sh --instalar` lá (precisa só do
`flatpak`; o Flathub é adicionado se faltar). Os dados do app em
`~/.var/app/...` não são tocados. O script fecha o SQLyog antes de instalar,
se estiver aberto.

## Pasta de configuração (conexões, favoritos, histórico)

O `%APPDATA%\SQLyog` do Windows (o `sqlyog.ini` com as conexões, os
favoritos, as tags e a sessão salva) fica em
`~/.var/app/com.webyog.SQLyog/data/SQLyog`.

Para usar uma pasta sua (ex.: um backup no Dropbox), use o `vincular-config.sh`:
ele troca essa pasta por um link simbólico para a sua e dá ao Flatpak
permissão de leitura e escrita nela (`flatpak override --filesystem`).

```sh
./vincular-config.sh ~/Dropbox/Backup/Programas/SQLyog
./vincular-config.sh --status      # para onde aponta e as permissões
./vincular-config.sh --desfazer    # volta à pasta própria do Flatpak
```

Uma configuração que já existisse em `data/SQLyog` é guardada em
`data/SQLyog_BKP` (nunca apagada) e volta com `--desfazer`. Se a pasta
vinculada sumir ou perder a permissão, o SQLyog avisa e não abre, em vez de
começar com a configuração vazia.

O `sqlyog.ini` guarda caminhos do Windows; os de arquivos do Linux aparecem
como `Z:\home\...` (o `/` é o drive `Z:`). O app tem acesso à home inteira
(`--filesystem=home`), para abrir e salvar scripts, backups e exportações.

## Publicar no GitHub

`--publicar` (opção 5 do menu) faz o completo e publica em dois releases:

- `flatpak`: release do código (o "latest", título "SQLyog Flatpak"),
  apontando para o commit atual, **sem anexo**: sem o setup não há app;
- `flatpak-full-<versão>`: rascunho privado com o `SQLyog-<versão>-full.flatpak`,
  que contém o SQLyog e o serial (só quem tem acesso de escrita ao
  repositório vê).

O release do código é recriado a cada publicação (o anterior é apagado, com a
tag). Os rascunhos ficam um por versão: publicar de novo a mesma versão
substitui o rascunho dela, e os de outras versões continuam lá (apague à mão
os que não quiser mais, com `gh release delete flatpak-full-<versão>`).
`--publicar-codigo` (opção 6) recria só o release
do código, sem compilar e sem tocar no rascunho. Exige tudo commitado e o
commit atual no GitHub (push), e confere isso antes de compilar.

## Como funciona

- **Instalação:** o setup (NSIS) roda em silêncio (`/S /D=C:\SQLyog`) no Wine
  da própria base `org.winehq.Wine`, num prefixo temporário em
  `downloads/.prefixo`. A pasta instalada vai para `downloads/instalado` (sem
  o `uninst.exe`) e é refeita só quando o setup muda (pelo SHA-256). No
  Flatpak ela fica em `/app/sqlyog`, só leitura; o SQLyog não grava na
  própria pasta.
- **Versão:** a do nome do setup (`13.1.1.24`); se o nome não tiver, a do
  `SQLyog.exe`.
- **Registro:** o SQLyog guarda o nome e o serial em
  `HKCU\Software\{d58cb4b1-47f3-45cb-a209-f298d0c3f756}` (`Name` e `InE`), com o
  código de cada caractere dobrado (ex.: `dev` = `c8,ca,ec`). O script gera
  o `downloads/registro.reg`, que vai para `/app/share/sqlyog` e o lançador
  importa no prefixo. O serial nunca vai para o git.
- **Prefixo do Wine:** em `~/.var/app/com.webyog.SQLyog/data/wineprefix`,
  atualizado (`wineboot -u`) quando a versão do Wine muda. As fontes e o
  registro são reaplicados quando os `.reg` do pacote mudam. O SQLyog é só 64
  bits, mas o Wine da base precisa da parte de 32 bits para iniciar, por
  isso `Compat.i386`/`GL32` e `--allow=multiarch`. O Wine Mono e o Gecko não
  são usados (`mscoree`/`mshtml` desligados).
- **Fontes:** o SQLyog é Win32/GDI. Ele usa `MS Shell Dlg` (Tahoma, que o
  Wine tem), `Courier New` (editor, grid e histórico) e, nas telas em HTML
  (htmlayout), `Verdana`, `Arial`, `Trebuchet MS` e `Times New Roman`. São
  as core fonts da Microsoft, baixadas dos instaladores originais (os mesmos
  do `winetricks corefonts`, conferidos pelo SHA-256), extraídas no build e
  copiadas para o `C:\windows\Fonts` do prefixo. Por causa da licença delas,
  só vão no `.flatpak` gerado na sua máquina (e no rascunho privado).
- **Primeira abertura:** com uma configuração nova, o lançador cria um
  `sqlyog.ini` com `Language=en`, senão o SQLyog pergunta o idioma (só tem
  inglês).
- **Depuração:** `flatpak run com.webyog.SQLyog winecfg|regedit|winetricks ...|shell`;
  `WINEDEBUG=...` é repassado. O túnel SSH usa o `plink.exe` do próprio
  SQLyog; chaves privadas são indicadas com o caminho `Z:\home\...`.

## Detalhes do build

- Usa o `org.flatpak.Builder` (Flatpak). Ele procura a instalação `--user` em
  `~/.var/app/org.flatpak.Builder/data/flatpak`, então o script cria ali
  symlinks para `~/.local/share/flatpak`.
- `--disable-rofiles-fuse` é necessário neste sistema.
- O Builder só compila; a instalação é feita pelo `flatpak` do host a partir
  do remote local `sqlyog-local` (o `repo/`). Instalando de dentro do Builder
  (`--install`), o .desktop exportado ficava com `Exec=/app/bin/flatpak ...`
  e o app não aparecia no menu.
- O Builder recebe `--filesystem=<pasta do script>`, senão não enxerga pastas
  fora da home (ex.: `/tmp`).
