#!/usr/bin/env bash
set -euo pipefail

if [ -n "${BASH_SOURCE:-}" ]; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  REPO_DIR="$(pwd)"
fi
ENV_FILE="${REPO_DIR}/.env"
DEFAULT_TRAEFIK_BASIC_AUTH='traefik:$apr1$changeme$2wH8KsEgbduEh1P1LzpT1/'

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_sudo() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    SUDO="sudo"
  else
    SUDO=""
  fi
}

ensure_dirs() {
  mkdir -p \
    "${REPO_DIR}/services/traefik/letsencrypt" \
    "${REPO_DIR}/services/traefik/data" \
    "${REPO_DIR}/services/n8n/data" \
    "${REPO_DIR}/services/onyx/data" \
    "${REPO_DIR}/services/nocodb/data"
  if [ ! -f "${REPO_DIR}/services/traefik/letsencrypt/acme.json" ]; then
    touch "${REPO_DIR}/services/traefik/letsencrypt/acme.json"
    chmod 600 "${REPO_DIR}/services/traefik/letsencrypt/acme.json"
  fi
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
  local default="${2:-}"
  local value
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " value || true
    echo "${value:-$default}"
  else
    read -r -p "$prompt: " value || true
    echo "${value}"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local value
  read -r -p "$prompt [${default}/n]: " value || true
  value="${value:-$default}"
  case "$value" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

configure_env() {
  echo "Konfiguracja .env"

  BASE_DOMAIN="$(ask "Podaj domenę bazową (np. example.com)" "example.com")"

  local enable_n8n enable_traefik enable_onyx enable_nocodb
  ask_yes_no "Włączyć n8n?" "y" && enable_n8n=1 || enable_n8n=0
  ask_yes_no "Włączyć Traefik (reverse proxy + TLS)?" "y" && enable_traefik=1 || enable_traefik=0
  ask_yes_no "Włączyć Onyx?" "y" && enable_onyx=1 || enable_onyx=0
  ask_yes_no "Włączyć NocoDB?" "y" && enable_nocodb=1 || enable_nocodb=0

  local profiles=()
  [ "$enable_traefik" -eq 1 ] && profiles+=("traefik")
  [ "$enable_n8n" -eq 1 ] && profiles+=("n8n")
  [ "$enable_onyx" -eq 1 ] && profiles+=("onyx")
  [ "$enable_nocodb" -eq 1 ] && profiles+=("nocodb")
  if [ "${#profiles[@]}" -eq 0 ]; then
    echo "Nie wybrano żadnej usługi. Przerywam." >&2
    exit 1
  fi
  local profiles_csv
  profiles_csv=$(IFS=,; echo "${profiles[*]}")

  TRAEFIK_ACME_EMAIL="$(ask "E-mail do Let's Encrypt" "admin@${BASE_DOMAIN}")"
  TRAEFIK_DOMAIN="$(ask "Domena dla panelu Traefik" "traefik.${BASE_DOMAIN}")"
  TRAEFIK_BASIC_AUTH="$(ask "Basic auth (user:hash) dla panelu Traefik" "${DEFAULT_TRAEFIK_BASIC_AUTH}")"

  N8N_DOMAIN="$(ask "Domena dla n8n" "n8n.${BASE_DOMAIN}")"
  NOCODB_DOMAIN="$(ask "Domena dla NocoDB" "nocodb.${BASE_DOMAIN}")"
  ONYX_DOMAIN="$(ask "Domena dla Onyx" "onyx.${BASE_DOMAIN}")"

  N8N_VERSION="$(ask "Wersja obrazu n8n" "1.72.0")"
  NOCODB_VERSION="$(ask "Wersja obrazu NocoDB" "0.204.3")"
  ONYX_VERSION="$(ask "Wersja obrazu Onyx" "latest")"
  TRAEFIK_VERSION="$(ask "Wersja obrazu Traefik" "2.11")"

  cat > "$ENV_FILE" <<EOF
BASE_DOMAIN=${BASE_DOMAIN}
COMPOSE_PROFILES=${profiles_csv}

TRAEFIK_IMAGE=traefik:v${TRAEFIK_VERSION}
TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN}
TRAEFIK_ACME_EMAIL=${TRAEFIK_ACME_EMAIL}
TRAEFIK_BASIC_AUTH=${TRAEFIK_BASIC_AUTH}

N8N_IMAGE=n8nio/n8n
N8N_VERSION=${N8N_VERSION}
N8N_DOMAIN=${N8N_DOMAIN}

NOCODB_IMAGE=nocodb/nocodb
NOCODB_VERSION=${NOCODB_VERSION}
NOCODB_DOMAIN=${NOCODB_DOMAIN}

ONYX_IMAGE=ghcr.io/onyx-oss/onyx
ONYX_VERSION=${ONYX_VERSION}
ONYX_DOMAIN=${ONYX_DOMAIN}
EOF

  echo ".env zapisany w ${ENV_FILE}"
}

bring_up() {
  require_sudo
  echo "Uruchamiam docker compose (pull + up -d)..."
  (cd "$REPO_DIR" && ${SUDO} docker compose pull)
  (cd "$REPO_DIR" && ${SUDO} docker compose up -d)
  echo "Status kontenerów:"
  (cd "$REPO_DIR" && ${SUDO} docker compose ps)
}

main() {
  ensure_dirs
  install_docker
  configure_env
  bring_up
  echo "Gotowe! Sprawdź swoje domeny: n8n=${N8N_DOMAIN}, nocodb=${NOCODB_DOMAIN}, onyx=${ONYX_DOMAIN}, traefik=${TRAEFIK_DOMAIN}"
}

main "$@"

