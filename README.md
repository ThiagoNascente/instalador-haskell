1. criar arquivo

```bash
nano instalar-haskell.sh
```

2. copiar script

```bash
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Instalação de Haskell via GHCup
# Ubuntu 22.04 / 24.04
#
# Uso:
#   sudo ./instalar-haskell.sh aluno
# ============================================================

TARGET_USER="${1:-aluno}"

# ------------------------------------------------------------
# 1. Verificar privilégios
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "ERRO: execute este script como administrador:"
    echo
    echo "  sudo $0 $TARGET_USER"
    echo
    exit 1
fi

# ------------------------------------------------------------
# 2. Verificar usuário
# ------------------------------------------------------------

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "ERRO: o usuário '$TARGET_USER' não existe."
    exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo "ERRO: diretório home inválido para '$TARGET_USER'."
    exit 1
fi

# ------------------------------------------------------------
# 3. Verificar Ubuntu
# ------------------------------------------------------------

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "ERRO: este script foi preparado para Ubuntu."
    exit 1
fi

case "${VERSION_ID:-}" in
    22.04|24.04)
        echo "Ubuntu $VERSION_ID detectado."
        ;;
    *)
        echo "AVISO: Ubuntu ${VERSION_ID:-desconhecido}."
        echo "Este script foi preparado para Ubuntu 22.04 e 24.04."
        ;;
esac

echo
echo "Usuário Haskell : $TARGET_USER"
echo "Home            : $TARGET_HOME"
echo

# ============================================================
# 4. SANEAR REPOSITÓRIOS APT
# ============================================================

echo "========================================="
echo "Verificando repositórios do Ubuntu"
echo "========================================="
echo

# ------------------------------------------------------------
# 4.1 Backup das configurações do APT
# ------------------------------------------------------------

APT_BACKUP="/var/backups/haskell-apt-$(date +%Y%m%d-%H%M%S).tar.gz"

mkdir -p /var/backups

APT_ITEMS=("sources.list.d")

if [[ -f /etc/apt/sources.list ]]; then
    APT_ITEMS+=("sources.list")
fi

if tar \
    -C /etc/apt \
    -czf "$APT_BACKUP" \
    "${APT_ITEMS[@]}" 2>/dev/null; then

    echo "Backup dos repositórios criado em:"
    echo "  $APT_BACKUP"
else
    echo "AVISO: não foi possível criar o backup dos repositórios."
    rm -f "$APT_BACKUP"
fi

echo

# ------------------------------------------------------------
# Função: desabilitar linhas de repositório .list
# ------------------------------------------------------------

disable_matching_repository() {

    local pattern="$1"
    local reason="$2"
    local file
    local tmp

    # Formato tradicional .list
    for file in \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/*.list
    do
        [[ -f "$file" ]] || continue

        if grep -Fq "$pattern" "$file"; then

            echo "Desabilitando repositório:"
            echo "  $pattern"
            echo "Motivo:"
            echo "  $reason"
            echo "Arquivo:"
            echo "  $file"

            tmp="$(mktemp)"

            awk \
                -v key="$pattern" \
                -v reason="$reason" '
                {
                    if ($0 !~ /^[[:space:]]*#/ &&
                        index($0, key) > 0) {

                        print "# Desabilitado por instalar-haskell.sh"
                        print "# Motivo: " reason
                        print "# " $0

                    } else {
                        print
                    }
                }
            ' "$file" > "$tmp"

            cat "$tmp" > "$file"
            rm -f "$tmp"

            echo
        fi
    done

    # Formato Deb822 (.sources)
    #
    # Normalmente cada PPA possui seu próprio arquivo.
    # Neste caso o arquivo inteiro é desabilitado.
    for file in /etc/apt/sources.list.d/*.sources
    do
        [[ -f "$file" ]] || continue

        if grep -Fq "$pattern" "$file"; then

            echo "Desabilitando repositório Deb822:"
            echo "  $file"

            mv \
                "$file" \
                "${file}.disabled-by-haskell-installer"

            echo
        fi
    done
}

# ------------------------------------------------------------
# 4.2 Remover preventivamente PPA antigo do WebUpd8 Java
# ------------------------------------------------------------

echo "==> Procurando PPA antigo webupd8team/java..."

if grep -Rqs \
    "webupd8team/java" \
    /etc/apt/sources.list \
    /etc/apt/sources.list.d/ 2>/dev/null; then

    disable_matching_repository \
        "webupd8team/java" \
        "PPA antigo/incompatível com versões atuais do Ubuntu"

else
    echo "Nenhum PPA webupd8team/java encontrado."
fi

echo

# ------------------------------------------------------------
# 4.3 Atualizar chave oficial dos repositórios Google
# ------------------------------------------------------------

refresh_google_key() {

    local KEY_URL
    local KEY_FILE

    KEY_URL="https://dl.google.com/linux/linux_signing_key.pub"
    KEY_FILE="/etc/apt/trusted.gpg.d/google.asc"

    echo "==> Atualizando chave de assinatura do Google..."

    # curl
    if command -v curl >/dev/null 2>&1; then

        if curl \
            --proto '=https' \
            --tlsv1.2 \
            -fsSL \
            "$KEY_URL" \
            -o "$KEY_FILE"; then

            chmod 0644 "$KEY_FILE"
            echo "Chave do Google atualizada."
            return 0
        fi

    # wget
    elif command -v wget >/dev/null 2>&1; then

        if wget \
            -qO "$KEY_FILE" \
            "$KEY_URL"; then

            chmod 0644 "$KEY_FILE"
            echo "Chave do Google atualizada."
            return 0
        fi

    # Python 3 como fallback
    elif command -v python3 >/dev/null 2>&1; then

        if python3 - "$KEY_URL" "$KEY_FILE" <<'PYTHON'
import sys
import urllib.request

url = sys.argv[1]
destino = sys.argv[2]

with urllib.request.urlopen(url, timeout=30) as resposta:
    dados = resposta.read()

with open(destino, "wb") as arquivo:
    arquivo.write(dados)
PYTHON
        then
            chmod 0644 "$KEY_FILE"
            echo "Chave do Google atualizada."
            return 0
        fi
    fi

    echo "AVISO: não foi possível atualizar a chave do Google."
    return 1
}

# Só mexer nisso se existir repositório Google configurado.

if grep -Rqs \
    "dl.google.com/linux" \
    /etc/apt/sources.list \
    /etc/apt/sources.list.d/ 2>/dev/null; then

    refresh_google_key || true

else
    echo "Nenhum repositório Google encontrado."
fi

echo

# ------------------------------------------------------------
# 4.4 Executar apt update
# ------------------------------------------------------------

echo "==> Testando repositórios com apt update..."

APT_LOG="$(mktemp)"

if LC_ALL=C apt-get update 2>&1 | tee "$APT_LOG"; then

    echo
    echo "APT funcionando corretamente."

else

    echo
    echo "========================================="
    echo "APT encontrou problemas."
    echo "Tentando correção automática..."
    echo "========================================="
    echo

    REPAIRED=0

    # --------------------------------------------------------
    # Detectar PPAs Launchpad sem arquivo Release
    # --------------------------------------------------------

    while IFS= read -r BAD_REPO
    do
        [[ -n "$BAD_REPO" ]] || continue

        # Remove http:// ou https:// para facilitar
        # a localização dentro dos arquivos.
        REPO_PATTERN="${BAD_REPO#http://}"
        REPO_PATTERN="${REPO_PATTERN#https://}"

        disable_matching_repository \
            "$REPO_PATTERN" \
            "PPA retornou erro: repository does not have a Release file"

        REPAIRED=1

    done < <(
        grep -oE \
            'https?://(ppa\.launchpadcontent\.net|ppa\.launchpad\.net)/[^ '"'"']+/ubuntu' \
            "$APT_LOG" \
        | sort -u
    )

    # --------------------------------------------------------
    # Caso ainda tenha ocorrido erro NO_PUBKEY do Google
    # --------------------------------------------------------

    if grep -q "NO_PUBKEY" "$APT_LOG" &&
       grep -q "dl.google.com" "$APT_LOG"; then

        refresh_google_key || true
        REPAIRED=1
    fi

    # --------------------------------------------------------
    # Tentar novamente
    # --------------------------------------------------------

    if [[ "$REPAIRED" -eq 1 ]]; then

        echo
        echo "==> Tentando apt update novamente..."
        echo

        if ! LC_ALL=C apt-get update; then

            echo
            echo "ERRO: ainda existem problemas nos repositórios."
            echo
            echo "A instalação do Haskell foi interrompida para"
            echo "não alterar o sistema em estado inconsistente."

            if [[ -f "$APT_BACKUP" ]]; then
                echo
                echo "Backup dos repositórios:"
                echo "  $APT_BACKUP"
            fi

            rm -f "$APT_LOG"
            exit 1
        fi

    else

        echo
        echo "ERRO: foi encontrado um problema no APT que o"
        echo "script não sabe corrigir com segurança."
        echo
        echo "A instalação foi interrompida."

        if [[ -f "$APT_BACKUP" ]]; then
            echo
            echo "Backup dos repositórios:"
            echo "  $APT_BACKUP"
        fi

        rm -f "$APT_LOG"
        exit 1
    fi
fi

rm -f "$APT_LOG"

echo
echo "========================================="
echo "APT verificado com sucesso."
echo "========================================="
echo

# ============================================================
# 5. Remover versões antigas do Haskell instaladas pelo APT
# ============================================================

echo "==> Procurando instalações antigas do Haskell..."

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
        "$pkg" 2>/dev/null \
        | grep -q '^install ok installed$'; then

        old_pkgs+=("$pkg")
    fi
done

if ((${#old_pkgs[@]})); then

    echo "Removendo:"
    printf '  %s\n' "${old_pkgs[@]}"

    apt-get purge -y "${old_pkgs[@]}"
    apt-get autoremove -y

else
    echo "Nenhuma instalação antiga via APT encontrada."
fi

# ============================================================
# 6. Instalar dependências
# ============================================================

echo
echo "==> Instalando dependências do GHCup..."

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
# 7. Instalar GHCup como o usuário aluno
# ============================================================

echo
echo "==> Instalando Haskell para '$TARGET_USER'..."

runuser -u "$TARGET_USER" -- env \
    HOME="$TARGET_HOME" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    SHELL=/bin/bash \
    bash -s <<'USER_SCRIPT'

set -Eeuo pipefail

# ------------------------------------------------------------
# GHCup
# ------------------------------------------------------------

if [[ ! -x "$HOME/.ghcup/bin/ghcup" ]]; then

    echo "==> Instalando GHCup..."

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
    echo "==> Atualizando GHCup..."

    "$HOME/.ghcup/bin/ghcup" upgrade || true
fi

# ------------------------------------------------------------
# Configurar PATH
# ------------------------------------------------------------

echo
echo "==> Configurando PATH..."

GHCUP_ENV_LINE='[ -f "$HOME/.ghcup/env" ] && source "$HOME/.ghcup/env"'

touch "$HOME/.bashrc"
touch "$HOME/.profile"

if ! grep -Fq '.ghcup/env' "$HOME/.bashrc"; then
    {
        echo
        echo "# GHCup"
        echo "$GHCUP_ENV_LINE"
    } >> "$HOME/.bashrc"
fi

if ! grep -Fq '.ghcup/env' "$HOME/.profile"; then
    {
        echo
        echo "# GHCup"
        echo "$GHCUP_ENV_LINE"
    } >> "$HOME/.profile"
fi

source "$HOME/.ghcup/env"

# ------------------------------------------------------------
# GHC
# ------------------------------------------------------------

echo
echo "==> Instalando GHC recomendado..."

ghcup install ghc recommended --set

# ------------------------------------------------------------
# Cabal
# ------------------------------------------------------------

echo
echo "==> Instalando Cabal recomendado..."

ghcup install cabal recommended
ghcup set cabal recommended

# ------------------------------------------------------------
# Haskell Language Server
# ------------------------------------------------------------

echo
echo "==> Instalando Haskell Language Server..."

ghcup install hls recommended
ghcup set hls recommended

# ------------------------------------------------------------
# Cabal
# ------------------------------------------------------------

echo
echo "==> Atualizando índice do Cabal..."

cabal update

# ------------------------------------------------------------
# Testes
# ------------------------------------------------------------

echo
echo "========================================="
echo "Versões instaladas"
echo "========================================="

ghc --version
cabal --version | head -n 1

haskell-language-server-wrapper --version 2>/dev/null \
    | head -n 1 || true

echo
echo "Executáveis:"
echo

command -v ghcup
command -v ghc
command -v ghci
command -v cabal

USER_SCRIPT

# ============================================================
# 8. Final
# ============================================================

echo
echo "========================================="
echo "INSTALAÇÃO CONCLUÍDA"
echo "========================================="
echo
echo "Usuário:"
echo "  $TARGET_USER"
echo
echo "GHCup:"
echo "  $TARGET_HOME/.ghcup"
echo
echo "O usuário '$TARGET_USER' NÃO precisa de sudo"
echo "para utilizar Haskell."
echo
echo "Após entrar na conta '$TARGET_USER', teste:"
echo
echo "  ghcup --version"
echo "  ghc --version"
echo "  cabal --version"
echo "  ghci"
echo
echo "Caso já estivesse logado como '$TARGET_USER'"
echo "durante a instalação, abra um novo terminal ou execute:"
echo
echo "  exec bash"
echo
```

3. salvar e fechar (ctrl+o, ctrl+x)

4. dar permissão

```bash
sudo chmod +x instalar-haskell.sh
```

5. executar

```bash
sudo ./instalar-haskell.sh aluno
```

