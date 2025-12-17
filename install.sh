#!/usr/bin/env bash
set -euo pipefail

# BASH_SOURCE może być puste przy uruchomieniu via curl|bash; wyłączamy nounset na chwilę
set +u
if [ -n "${BASH_SOURCE:-}" ]; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  REPO_DIR="$(pwd)"
fi
set -u

ENV_FILE="${REPO_DIR}/.env"

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_sudo() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    SUDO="sudo"
  else
    SUDO=""
  fi
}

ensure_dirs() {
  mkdir -p "${REPO_DIR}/services/n8n/data"
}

install_docker() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    echo "Docker i docker compose już dostępne."
    return
  fi

  require_sudo
  echo "Instaluję Docker + docker-compose-plugin..."

  if command_exists apt-get; then
    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y ca-certificates curl gnupg lsb-release
    if ! [ -f /etc/apt/keyrings/docker.gpg ]; then
      ${SUDO} install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
        $(. /etc/os-release; echo "$VERSION_CODENAME") stable" | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
      ${SUDO} apt-get update -y
    fi
    ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  elif command_exists dnf; then
    ${SUDO} dnf -y install dnf-plugins-core
    ${SUDO} dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    ${SUDO} dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  elif command_exists yum; then
    ${SUDO} yum install -y yum-utils
    ${SUDO} yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    ${SUDO} yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    echo "Brak obsługiwanego menedżera pakietów (apt/dnf/yum). Zainstaluj Docker ręcznie." >&2
    exit 1
  fi

  ${SUDO} systemctl enable docker >/dev/null 2>&1 || true
  ${SUDO} systemctl start docker >/dev/null 2>&1 || true
}

ask() {
  local prompt="$1"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "$prompt: " value </dev/tty
    if [ -z "$value" ]; then
      echo "Wartość nie może być pusta! Spróbuj ponownie."
    fi
  done
  echo "$value"
}

ask_yes_no() {
  local prompt="$1"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "$prompt [y/n]: " value </dev/tty
    case "$value" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) 
        echo "Proszę odpowiedzieć 'y' (tak) lub 'n' (nie)"
        value=""
        ;;
    esac
  done
}

configure_env() {
  echo ""
  echo "=== Konfiguracja n8n ==="
  echo ""

  # Domena
  echo "Konfiguracja domeny:"
  if ask_yes_no "Czy masz domenę dla n8n?"; then
    N8N_DOMAIN="$(ask "Podaj pełną domenę dla n8n (np. n8n.example.com)")"
    BASE_DOMAIN="${N8N_DOMAIN#*.}"  # wyciągnij domenę bazową
  else
    BASE_DOMAIN="localhost"
    N8N_DOMAIN="localhost"
    echo "Używam localhost jako domeny."
  fi

  echo ""

  # Wersja
  echo "Konfiguracja wersji:"
  if ask_yes_no "Czy chcesz użyć najnowszej wersji n8n?"; then
    N8N_VERSION="latest"
    echo "Używam najnowszej wersji (latest)."
  else
    N8N_VERSION="$(ask "Podaj konkretną wersję n8n (np. 1.72.0)")"
  fi

  echo ""

  # Port
  N8N_PORT="$(ask "Na jakim porcie ma działać n8n? (domyślnie 5678)")"
  if [ -z "$N8N_PORT" ]; then
    N8N_PORT="5678"
  fi

  # Zapisz .env
  {
    echo "BASE_DOMAIN=${BASE_DOMAIN}"
    echo "N8N_IMAGE=n8nio/n8n"
    echo "N8N_VERSION=${N8N_VERSION}"
    echo "N8N_DOMAIN=${N8N_DOMAIN}"
    echo "N8N_PORT=${N8N_PORT}"
  } > "$ENV_FILE"

  echo ".env zapisany w ${ENV_FILE}"
}

create_compose_file() {
  echo "Tworzę docker-compose.yml dla n8n..."
  
  # Wczytaj .env
  if [ -f "$ENV_FILE" ]; then
    set +u
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
    set -u
  fi

  cat > "${REPO_DIR}/services/n8n/docker-compose.yml" <<EOF
version: "3.9"

services:
  n8n:
    image: ${N8N_IMAGE}:${N8N_VERSION}
    ports:
      - "${N8N_PORT}:5678"
    environment:
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
    volumes:
      - "${REPO_DIR}/services/n8n/data:/home/node/.n8n"
    restart: unless-stopped
EOF
  echo "✓ services/n8n/docker-compose.yml"
}

bring_up() {
  require_sudo
  echo ""
  echo "Uruchamiam n8n..."
  
  service_dir="${REPO_DIR}/services/n8n"
  if [ -f "${service_dir}/docker-compose.yml" ]; then
    echo "Pobieram obraz..."
    (cd "$service_dir" && ${SUDO} docker compose pull)
    echo "Uruchamiam kontener..."
    (cd "$service_dir" && ${SUDO} docker compose up -d)
  fi

  echo ""
  echo "Status kontenera:"
  ${SUDO} docker ps --filter "name=n8n" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

main() {
  ensure_dirs
  install_docker
  configure_env
  create_compose_file
  bring_up
  
  echo ""
  echo "=== Gotowe! ==="
  echo "n8n dostępne pod adresem: http://${N8N_DOMAIN}:${N8N_PORT}"
  echo "lub bezpośrednio: http://$(hostname -I | awk '{print $1}'):${N8N_PORT}"
}

main "$@"
