1. criar arquivo

```bash
nano instalar-haskell.sh
```

2. copiar script

```bash
#!/usr/bin/env bash

set -Eeuo pipefail

# Usuário que utilizará o Haskell.
# Exemplo:
# sudo ./instalar-haskell.sh aluno
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

# ------------------------------------------------------------
# 4. Remover versões antigas instaladas pelo APT
# ------------------------------------------------------------

echo "==> Procurando instalações antigas do Haskell..."

old_pkgs=()

for pkg in ghc cabal-install haskell-platform haskell-stack; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
        | grep -q '^install ok installed$'; then

        old_pkgs+=("$pkg")
    fi
done

if ((${#old_pkgs[@]})); then
    echo "Removendo: ${old_pkgs[*]}"
    apt-get purge -y "${old_pkgs[@]}"
    apt-get autoremove -y
else
    echo "Nenhuma instalação antiga via APT encontrada."
fi

# ------------------------------------------------------------
# 5. Instalar dependências do sistema
# ------------------------------------------------------------

echo
echo "==> Instalando dependências do sistema..."

apt-get update

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

# ------------------------------------------------------------
# 6. Instalar GHCup como o usuário alvo
# ------------------------------------------------------------

echo
echo "==> Instalando GHCup para '$TARGET_USER'..."

runuser -u "$TARGET_USER" -- env \
    HOME="$TARGET_HOME" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    bash -s <<'USER_SCRIPT'

set -Eeuo pipefail

# ------------------------------------------------------------
# Instalar/atualizar GHCup
# ------------------------------------------------------------

if [[ ! -x "$HOME/.ghcup/bin/ghcup" ]]; then

    curl --proto '=https' \
         --tlsv1.2 \
         -sSf \
         https://get-ghcup.haskell.org \
    | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
      BOOTSTRAP_HASKELL_MINIMAL=1 \
      sh

else
    echo "GHCup já está instalado."
    echo "Tentando atualizar o GHCup..."

    "$HOME/.ghcup/bin/ghcup" upgrade || true
fi

# ------------------------------------------------------------
# Configurar o ambiente
# ------------------------------------------------------------

GHCUP_ENV_LINE='[ -f "$HOME/.ghcup/env" ] && source "$HOME/.ghcup/env"'

echo
echo "==> Configurando PATH do GHCup..."

# Bash interativo
touch "$HOME/.bashrc"

if ! grep -Fq '.ghcup/env' "$HOME/.bashrc"; then
    {
        echo
        echo "# GHCup"
        echo "$GHCUP_ENV_LINE"
    } >> "$HOME/.bashrc"
fi

# Sessões de login
touch "$HOME/.profile"

if ! grep -Fq '.ghcup/env' "$HOME/.profile"; then
    {
        echo
        echo "# GHCup"
        echo "$GHCUP_ENV_LINE"
    } >> "$HOME/.profile"
fi

# Ativa GHCup nesta execução do instalador
source "$HOME/.ghcup/env"

# ------------------------------------------------------------
# 7. Instalar GHC
# ------------------------------------------------------------

echo
echo "==> Instalando GHC recomendado..."

ghcup install ghc recommended --set

# ------------------------------------------------------------
# 8. Instalar Cabal
# ------------------------------------------------------------

echo
echo "==> Instalando Cabal recomendado..."

ghcup install cabal recommended || true
ghcup set cabal recommended

# ------------------------------------------------------------
# 9. Instalar Haskell Language Server
# ------------------------------------------------------------

echo
echo "==> Instalando Haskell Language Server recomendado..."

ghcup install hls recommended || true
ghcup set hls recommended

# ------------------------------------------------------------
# 10. Atualizar índice do Cabal
# ------------------------------------------------------------

echo
echo "==> Atualizando índice do Cabal..."

cabal update

# ------------------------------------------------------------
# 11. Testar instalação
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
echo "Localização dos executáveis:"
echo

command -v ghcup
command -v ghc
command -v ghci
command -v cabal

USER_SCRIPT

# ------------------------------------------------------------
# 12. Corrigir proprietário dos arquivos de configuração
# ------------------------------------------------------------

TARGET_GROUP="$(id -gn "$TARGET_USER")"

chown "$TARGET_USER:$TARGET_GROUP" \
    "$TARGET_HOME/.bashrc" \
    "$TARGET_HOME/.profile"

# ------------------------------------------------------------
# Final
# ------------------------------------------------------------

echo
echo "========================================="
echo "Instalação concluída."
echo "========================================="
echo
echo "GHCup e Haskell foram instalados para:"
echo
echo "  $TARGET_USER"
echo
echo "Diretório:"
echo
echo "  $TARGET_HOME/.ghcup"
echo
echo "O usuário '$TARGET_USER' NÃO precisa de sudo"
echo "para utilizar Haskell."
echo
echo "IMPORTANTE:"
echo "O script não consegue modificar o ambiente do terminal"
echo "que já estava aberto antes da instalação."
echo
echo "Se você estiver nesse mesmo terminal, execute:"
echo
echo "  exec bash"
echo
echo "ou:"
echo
echo "  source ~/.ghcup/env"
echo
echo "Depois teste:"
echo
echo "  ghcup --version"
echo "  ghc --version"
echo "  cabal --version"
echo "  ghci"
echo
```

3. salvar e fechar (ctrl+o, ctrl+x)

4. dar permissão

```bash
sudo chmod +x instalar-haskell.sh
```

5. executar

```bash
sudo ./instalar.haskell.sh aluno
```

