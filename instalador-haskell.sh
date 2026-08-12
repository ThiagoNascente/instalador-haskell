#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# INSTALAÇÃO PADRONIZADA DE HASKELL VIA GHCUP
# Ubuntu 22.04 / 24.04
#
# Uso:
#   sudo ./instalar-haskell.sh aluno
# ============================================================

TARGET_USER="${1:-aluno}"

# ============================================================
# FUNÇÕES AUXILIARES
# ============================================================

section() {
    echo
    echo "========================================="
    echo "$1"
    echo "========================================="
    echo
}

die() {
    echo "ERRO: $*" >&2
    exit 1
}

# ============================================================
# 1. VERIFICAÇÕES INICIAIS
# ============================================================

[[ $EUID -eq 0 ]] || \
    die "execute como administrador: sudo $0 $TARGET_USER"

id "$TARGET_USER" >/dev/null 2>&1 || \
    die "o usuário '$TARGET_USER' não existe."

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || \
    die "diretório HOME inválido para '$TARGET_USER': '$TARGET_HOME'"

[[ "$TARGET_USER" != "root" ]] || \
    die "o usuário de destino não pode ser root."

source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] || \
    die "este script foi preparado para Ubuntu."

case "${VERSION_ID:-}" in

    22.04|24.04)
        echo "Ubuntu $VERSION_ID detectado."
        ;;

    *)
        die "versão Ubuntu ${VERSION_ID:-desconhecida} não suportada. Use 22.04 ou 24.04."
        ;;

esac

echo
echo "Usuário Haskell : $TARGET_USER"
echo "Home            : $TARGET_HOME"
echo "Grupo           : $TARGET_GROUP"

# ============================================================
# 2. VERIFICAR / SANEAR REPOSITÓRIOS APT
# ============================================================

section "Verificando repositórios APT"

# ------------------------------------------------------------
# 2.1 Backup das configurações atuais do APT
# ------------------------------------------------------------

APT_BACKUP="/var/backups/haskell-apt-$(date +%Y%m%d-%H%M%S).tar.gz"

mkdir -p /var/backups

APT_BACKUP_ITEMS=("sources.list.d")

if [[ -f /etc/apt/sources.list ]]; then
    APT_BACKUP_ITEMS+=("sources.list")
fi

if tar \
    -C /etc/apt \
    -czf "$APT_BACKUP" \
    "${APT_BACKUP_ITEMS[@]}" \
    2>/dev/null
then

    echo "Backup das fontes APT criado em:"
    echo
    echo "  $APT_BACKUP"

else

    echo "AVISO: não foi possível criar o backup das fontes APT."
    rm -f "$APT_BACKUP"

fi

echo

# ============================================================
# 2.2 Função para desabilitar repositórios problemáticos
# ============================================================

disable_repository_pattern() {

    local pattern="$1"
    local reason="$2"
    local file
    local tmp
    local disabled

    # --------------------------------------------------------
    # Formato tradicional:
    #
    # /etc/apt/sources.list
    # /etc/apt/sources.list.d/*.list
    # --------------------------------------------------------

    for file in \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/*.list
    do

        [[ -f "$file" ]] || continue

        if grep -Fq "$pattern" "$file"; then

            tmp="$(mktemp)"

            # IMPORTANTE:
            # Condição mantida em uma única linha para funcionar
            # corretamente com mawk (padrão do Ubuntu).

            awk \
                -v key="$pattern" \
                -v reason="$reason" '
                {
                    if ($0 !~ /^[[:space:]]*#/ && index($0, key) > 0) {
                        print "# Desabilitado por instalar-haskell.sh"
                        print "# Motivo: " reason
                        print "# " $0
                    } else {
                        print $0
                    }
                }
            ' "$file" > "$tmp"

            if ! cmp -s "$file" "$tmp"; then

                cat "$tmp" > "$file"

                echo "Repositório desabilitado:"
                echo
                echo "  Arquivo: $file"
                echo "  Padrão : $pattern"
                echo "  Motivo : $reason"
                echo

            fi

            rm -f "$tmp"

        fi

    done

    # --------------------------------------------------------
    # Formato Deb822:
    #
    # /etc/apt/sources.list.d/*.sources
    # --------------------------------------------------------

    for file in /etc/apt/sources.list.d/*.sources
    do

        [[ -f "$file" ]] || continue

        if grep -Fq "$pattern" "$file"; then

            disabled="${file}.disabled-by-haskell-installer"

            if [[ ! -e "$disabled" ]]; then

                mv "$file" "$disabled"

                echo "Repositório Deb822 desabilitado:"
                echo
                echo "  $file"
                echo
                echo "Motivo:"
                echo "  $reason"
                echo

            fi

        fi

    done
}

# ============================================================
# 2.3 Verificar se determinado repositório está ativo
# ============================================================

has_repository_pattern() {

    local pattern="$1"
    local file

    for file in \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/*.list
    do

        [[ -f "$file" ]] || continue

        if grep -E \
            '^[[:space:]]*deb([[:space:]]|\[)' \
            "$file" \
            2>/dev/null \
            | grep -Fq "$pattern"
        then

            return 0

        fi

    done

    for file in /etc/apt/sources.list.d/*.sources
    do

        [[ -f "$file" ]] || continue

        if grep -Fq "$pattern" "$file"; then
            return 0
        fi

    done

    return 1
}

# ============================================================
# 2.4 Desabilitar PPA antigo WebUpd8 Java
# ============================================================

echo "==> Procurando PPA antigo webupd8team/java..."

if grep -Rqs \
    "webupd8team/java" \
    /etc/apt/sources.list \
    /etc/apt/sources.list.d/ \
    2>/dev/null
then

    disable_repository_pattern \
        "webupd8team/java" \
        "PPA antigo/incompatível com Ubuntu 22.04/24.04"

else

    echo "Nenhum webupd8team/java encontrado."

fi

echo

# ============================================================
# 2.5 Atualizar chave dos repositórios Google
# ============================================================

refresh_google_key() {

    local url
    local dest
    local tmp

    url="https://dl.google.com/linux/linux_signing_key.pub"
    dest="/etc/apt/trusted.gpg.d/google.asc"

    tmp="$(mktemp)"

    echo "==> Atualizando chave pública do Google..."

    if command -v curl >/dev/null 2>&1; then

        if ! curl \
            --proto '=https' \
            --tlsv1.2 \
            -fsSL \
            "$url" \
            -o "$tmp"
        then

            rm -f "$tmp"
            return 1

        fi

    elif command -v wget >/dev/null 2>&1; then

        if ! wget \
            -qO "$tmp" \
            "$url"
        then

            rm -f "$tmp"
            return 1

        fi

    else

        rm -f "$tmp"
        return 1

    fi

    if [[ ! -s "$tmp" ]]; then

        rm -f "$tmp"
        return 1

    fi

    install \
        -o root \
        -g root \
        -m 0644 \
        "$tmp" \
        "$dest"

    rm -f "$tmp"

    echo "Chave do Google atualizada:"
    echo
    echo "  $dest"

    return 0
}

# ------------------------------------------------------------
# Só atualizar se existir repositório Google
# ------------------------------------------------------------

if has_repository_pattern "dl.google.com/linux"; then

    refresh_google_key || \
        echo "AVISO: não foi possível atualizar preventivamente a chave do Google."

else

    echo "Nenhum repositório Google ativo encontrado."

fi

echo

# ============================================================
# 2.6 Executar apt update e capturar erros
# ============================================================

APT_LOG="$(mktemp)"

trap 'rm -f "$APT_LOG"' EXIT

apt_update_logged() {

    : > "$APT_LOG"

    LC_ALL=C apt-get update 2>&1 \
        | tee "$APT_LOG"
}

echo "==> Executando apt-get update..."
echo

if ! apt_update_logged; then

    echo
    echo "APT apresentou erros."
    echo "Tentando corrigir casos conhecidos..."
    echo

    repaired=0

    # --------------------------------------------------------
    # Detectar repositórios que não possuem arquivo Release
    # --------------------------------------------------------

    mapfile -t bad_release_urls < <(

        grep -E \
            "The repository 'https?://[^']+ .*Release'.*(does not have|no longer has) a Release file" \
            "$APT_LOG" \
        | grep -oE \
            "https?://[^[:space:]']+" \
        | sort -u \
        || true

    )

    for bad_url in "${bad_release_urls[@]}"
    do

        [[ -n "$bad_url" ]] || continue

        pattern="${bad_url#http://}"
        pattern="${pattern#https://}"

        echo "Repositório sem arquivo Release detectado:"
        echo
        echo "  $bad_url"
        echo

        disable_repository_pattern \
            "$pattern" \
            "APT informou que o repositório não possui arquivo Release"

        repaired=1

    done

    # --------------------------------------------------------
    # Detectar problema NO_PUBKEY do Google
    # --------------------------------------------------------

    if grep -q "NO_PUBKEY" "$APT_LOG" &&
       grep -q "dl.google.com" "$APT_LOG"
    then

        echo "Problema de chave GPG do Google detectado."
        echo

        if refresh_google_key; then

            repaired=1

        else

            echo "Não foi possível renovar a chave do Google."
            echo "Desabilitando temporariamente o repositório."
            echo

            disable_repository_pattern \
                "dl.google.com/linux" \
                "Falha de assinatura GPG (NO_PUBKEY)"

            repaired=1

        fi

    fi

    # --------------------------------------------------------
    # Erro desconhecido
    # --------------------------------------------------------

    if [[ "$repaired" -eq 0 ]]; then

        echo
        echo "ERRO: o APT falhou por um motivo que este script"
        echo "não sabe corrigir automaticamente com segurança."

        if [[ -f "$APT_BACKUP" ]]; then

            echo
            echo "Backup das fontes:"
            echo
            echo "  $APT_BACKUP"

        fi

        exit 1

    fi

    # --------------------------------------------------------
    # Segunda tentativa
    # --------------------------------------------------------

    echo
    echo "==> Tentando apt-get update novamente..."
    echo

    if ! apt_update_logged; then

        echo
        echo "ERRO: ainda existem problemas nos repositórios APT."
        echo
        echo "A instalação foi interrompida para não modificar"
        echo "o sistema enquanto o APT está inconsistente."

        if [[ -f "$APT_BACKUP" ]]; then

            echo
            echo "Backup das fontes:"
            echo
            echo "  $APT_BACKUP"

        fi

        exit 1

    fi

fi

rm -f "$APT_LOG"

trap - EXIT

section "APT verificado com sucesso"

# ============================================================
# 3. REMOVER HASKELL ANTIGO INSTALADO PELO APT
# ============================================================

echo "==> Procurando instalações antigas de Haskell via APT..."

old_pkgs=()

for pkg in \
    ghc \
    cabal-install \
    haskell-platform \
    haskell-stack
do

    if dpkg-query \
        -W \
        -f='${Status}' \
        "$pkg" \
        2>/dev/null \
        | grep -q '^install ok installed$'
    then

        old_pkgs+=("$pkg")

    fi

done

if ((${#old_pkgs[@]})); then

    echo
    echo "Pacotes antigos encontrados:"
    echo

    printf '  %s\n' "${old_pkgs[@]}"

    echo
    echo "Removendo..."

    apt-get purge -y "${old_pkgs[@]}"

else

    echo "Nenhuma instalação antiga de Haskell via APT encontrada."

fi

# ============================================================
# 4. INSTALAR DEPENDÊNCIAS
# ============================================================

section "Instalando dependências do GHCup"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    ca-certificates \
    curl \
    libffi-dev \
    libgmp-dev \
    libncurses-dev \
    libnuma-dev \
    pkg-config \
    xz-utils

# ============================================================
# 5. INSTALAR HASKELL PARA O USUÁRIO ALVO
# ============================================================

section "Instalando Haskell para '$TARGET_USER'"

# ------------------------------------------------------------
# IMPORTANTE:
#
# O administrador pode executar o script de qualquer pasta:
#
# /home/suporte/Downloads
# /tmp
# pendrive
# etc.
#
# Antes de executar comandos como "aluno", mudamos para
# /home/aluno.
#
# Isso evita erros como:
#
# /home/suporte/Downloads/dist-newstyle/cache/config:
# permission denied
# ------------------------------------------------------------

(
    cd "$TARGET_HOME"

    runuser -u "$TARGET_USER" -- env \
        HOME="$TARGET_HOME" \
        USER="$TARGET_USER" \
        LOGNAME="$TARGET_USER" \
        SHELL=/bin/bash \
        bash -s <<'USER_SCRIPT'

set -Eeuo pipefail

# ============================================================
# Garantir diretório correto
# ============================================================

cd "$HOME"

section_user() {

    echo
    echo "-----------------------------------------"
    echo "$1"
    echo "-----------------------------------------"

}

section_user "Ambiente do usuário"

echo "Usuário : $(whoami)"
echo "HOME    : $HOME"
echo "PWD     : $(pwd)"

# ============================================================
# 5.1 GHCup
# ============================================================

section_user "GHCup"

if [[ ! -x "$HOME/.ghcup/bin/ghcup" ]]; then

    echo "Instalando GHCup..."

    curl \
        --proto '=https' \
        --tlsv1.2 \
        -sSf \
        https://get-ghcup.haskell.org \
    | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
      BOOTSTRAP_HASKELL_MINIMAL=1 \
      sh

else

    echo "GHCup já está instalado."
    echo "Tentando atualizar..."

    "$HOME/.ghcup/bin/ghcup" upgrade || {

        echo
        echo "AVISO: não foi possível atualizar o GHCup."
        echo "Continuando com a versão existente."

    }

fi

# ------------------------------------------------------------
# Verificar ambiente criado pelo GHCup
# ------------------------------------------------------------

if [[ ! -f "$HOME/.ghcup/env" ]]; then

    echo
    echo "ERRO: arquivo do ambiente do GHCup não encontrado:"
    echo
    echo "  $HOME/.ghcup/env"

    exit 1

fi

# ============================================================
# 5.2 Configurar PATH
# ============================================================

section_user "Configurando PATH"

GHCUP_ENV_LINE='[ -f "$HOME/.ghcup/env" ] && source "$HOME/.ghcup/env"'

touch \
    "$HOME/.bashrc" \
    "$HOME/.profile"

# ------------------------------------------------------------
# .bashrc
# ------------------------------------------------------------

if ! grep -Fq '.ghcup/env' "$HOME/.bashrc"; then

    {
        echo
        echo "# GHCup"
        echo "$GHCUP_ENV_LINE"
    } >> "$HOME/.bashrc"

fi

# ------------------------------------------------------------
# .profile
# ------------------------------------------------------------

if ! grep -Fq '.ghcup/env' "$HOME/.profile"; then

    {
        echo
        echo "# GHCup"
        echo "$GHCUP_ENV_LINE"
    } >> "$HOME/.profile"

fi

# ------------------------------------------------------------
# Carregar nesta execução
# ------------------------------------------------------------

source "$HOME/.ghcup/env"

# ============================================================
# 5.3 GHC
# ============================================================

section_user "Instalando GHC recomendado"

ghcup install ghc recommended
ghcup set ghc recommended

# ============================================================
# 5.4 Cabal
# ============================================================

section_user "Instalando Cabal recomendado"

ghcup install cabal recommended
ghcup set cabal recommended

# ============================================================
# 5.5 Haskell Language Server
# ============================================================

section_user "Instalando Haskell Language Server"

ghcup install hls recommended
ghcup set hls recommended

# ============================================================
# 5.6 Atualizar índice do Cabal
# ============================================================

section_user "Atualizando índice do Cabal"

# Uma falha aqui não invalida a instalação inteira.

if ! cabal update; then

    echo
    echo "AVISO: não foi possível atualizar o índice do Cabal."
    echo
    echo "GHC, Cabal e HLS já foram instalados."
    echo "O usuário poderá executar posteriormente:"
    echo
    echo "  cabal update"

fi

# ============================================================
# 5.7 Verificações finais
# ============================================================

section_user "Versões instaladas"

echo
echo "GHCup:"
ghcup --version | head -n 1

echo
echo "GHC:"
ghc --version

echo
echo "Cabal:"
cabal --version | head -n 1

echo
echo "Haskell Language Server:"

if command -v haskell-language-server-wrapper >/dev/null 2>&1; then

    haskell-language-server-wrapper \
        --version \
        2>/dev/null \
        | head -n 1 \
        || true

else

    echo "Wrapper do HLS não encontrado no PATH."

fi

echo
echo "Executáveis encontrados:"
echo

printf '  ghcup: %s\n' "$(command -v ghcup)"
printf '  ghc:   %s\n' "$(command -v ghc)"
printf '  ghci:  %s\n' "$(command -v ghci)"
printf '  cabal: %s\n' "$(command -v cabal)"

USER_SCRIPT

)

# ============================================================
# 6. GARANTIR PROPRIEDADE DOS ARQUIVOS
# ============================================================

chown \
    "$TARGET_USER:$TARGET_GROUP" \
    "$TARGET_HOME/.bashrc" \
    "$TARGET_HOME/.profile"

# ============================================================
# 7. FINAL
# ============================================================

section "INSTALAÇÃO CONCLUÍDA"

echo "Usuário Haskell:"
echo
echo "  $TARGET_USER"

echo
echo "Instalação do GHCup:"
echo
echo "  $TARGET_HOME/.ghcup"

echo
echo "O usuário '$TARGET_USER' NÃO precisa de sudo"
echo "para utilizar Haskell."

echo
echo "Entre em uma nova sessão ou abra um novo terminal"
echo "como '$TARGET_USER' e execute:"
echo
echo "  ghcup --version"
echo "  ghc --version"
echo "  cabal --version"
echo "  ghci"

echo
echo "Se a conta '$TARGET_USER' já estava aberta durante"
echo "a instalação, execute:"
echo
echo "  exec bash"

if [[ -f "$APT_BACKUP" ]]; then

    echo
    echo "Backup das fontes APT desta execução:"
    echo
    echo "  $APT_BACKUP"

fi

echo