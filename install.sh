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
DEFAULT_TRAEFIK_BASIC_AUTH='traefik:\$apr1\$changeme\$2wH8KsEgbduEh1P1LzpT1/'

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

  local enabled_services=()
  [ "$enable_traefik" -eq 1 ] && enabled_services+=("traefik")
  [ "$enable_n8n" -eq 1 ] && enabled_services+=("n8n")
  [ "$enable_onyx" -eq 1 ] && enabled_services+=("onyx")
  [ "$enable_nocodb" -eq 1 ] && enabled_services+=("nocodb")
  if [ "${#enabled_services[@]}" -eq 0 ]; then
    echo "Nie wybrano żadnej usługi. Przerywam." >&2
    exit 1
  fi

  TRAEFIK_ACME_EMAIL=""
  TRAEFIK_DOMAIN=""
  TRAEFIK_BASIC_AUTH=""
  if [ "$enable_traefik" -eq 1 ]; then
    TRAEFIK_ACME_EMAIL="$(ask "E-mail do Let's Encrypt" "admin@${BASE_DOMAIN}")"
    TRAEFIK_DOMAIN="$(ask "Domena dla panelu Traefik" "traefik.${BASE_DOMAIN}")"
    TRAEFIK_BASIC_AUTH="$(ask "Basic auth (user:hash) dla panelu Traefik" "${DEFAULT_TRAEFIK_BASIC_AUTH}")"
  fi

  N8N_DOMAIN=""
  N8N_VERSION=""
  if [ "$enable_n8n" -eq 1 ]; then
    N8N_DOMAIN="$(ask "Domena dla n8n" "n8n.${BASE_DOMAIN}")"
    N8N_VERSION="$(ask "Wersja obrazu n8n" "1.72.0")"
  fi

  NOCODB_DOMAIN=""
  NOCODB_VERSION=""
  if [ "$enable_nocodb" -eq 1 ]; then
    NOCODB_DOMAIN="$(ask "Domena dla NocoDB" "nocodb.${BASE_DOMAIN}")"
    NOCODB_VERSION="$(ask "Wersja obrazu NocoDB" "0.204.3")"
  fi

  ONYX_DOMAIN=""
  ONYX_VERSION=""
  if [ "$enable_onyx" -eq 1 ]; then
    ONYX_DOMAIN="$(ask "Domena dla Onyx" "onyx.${BASE_DOMAIN}")"
    ONYX_VERSION="$(ask "Wersja obrazu Onyx" "latest")"
  fi

  TRAEFIK_VERSION=""
  if [ "$enable_traefik" -eq 1 ]; then
    TRAEFIK_VERSION="$(ask "Wersja obrazu Traefik" "2.11")"
  fi

  # zabezpieczenie znaków $ w basic auth dla zapisu do .env
  local SAFE_TRAEFIK_BASIC_AUTH
  SAFE_TRAEFIK_BASIC_AUTH="${TRAEFIK_BASIC_AUTH//$/\\$}"

  # Zapisz .env
  {
    echo "BASE_DOMAIN=${BASE_DOMAIN}"
    echo ""
    if [ "$enable_traefik" -eq 1 ]; then
      echo "TRAEFIK_IMAGE=traefik:v${TRAEFIK_VERSION}"
      echo "TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN}"
      echo "TRAEFIK_ACME_EMAIL=${TRAEFIK_ACME_EMAIL}"
      echo "TRAEFIK_BASIC_AUTH=${SAFE_TRAEFIK_BASIC_AUTH}"
      echo ""
    fi
    if [ "$enable_n8n" -eq 1 ]; then
      echo "N8N_IMAGE=n8nio/n8n"
      echo "N8N_VERSION=${N8N_VERSION}"
      echo "N8N_DOMAIN=${N8N_DOMAIN}"
      echo ""
    fi
    if [ "$enable_nocodb" -eq 1 ]; then
      echo "NOCODB_IMAGE=nocodb/nocodb"
      echo "NOCODB_VERSION=${NOCODB_VERSION}"
      echo "NOCODB_DOMAIN=${NOCODB_DOMAIN}"
      echo ""
    fi
    if [ "$enable_onyx" -eq 1 ]; then
      echo "ONYX_IMAGE=ghcr.io/onyx-oss/onyx"
      echo "ONYX_VERSION=${ONYX_VERSION}"
      echo "ONYX_DOMAIN=${ONYX_DOMAIN}"
    fi
  } > "$ENV_FILE"

  echo ".env zapisany w ${ENV_FILE}"
  
  # Zapisz listę włączonych usług do zmiennej globalnej
  ENABLED_SERVICES=("${enabled_services[@]}")
}

create_compose_files() {
  echo "Tworzę docker-compose.yml dla każdej usługi..."
  
  # Wczytaj .env (wyłączamy nounset na czas wczytywania, żeby nie było problemu z $ w wartościach)
  set +u
  set -a
  [ -f "$ENV_FILE" ] && source "$ENV_FILE"
  set +a
  set -u

  # Utwórz wspólną sieć (jeśli nie istnieje)
  if ! docker network inspect proxy >/dev/null 2>&1; then
    require_sudo
    echo "Tworzę sieć 'proxy'..."
    ${SUDO} docker network create proxy
  fi

  # Traefik
  if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
    cat > "${REPO_DIR}/services/traefik/docker-compose.yml" <<EOF
version: "3.9"

networks:
  proxy:
    external: true

services:
  traefik:
    image: ${TRAEFIK_IMAGE}
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=${TRAEFIK_ACME_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "${REPO_DIR}/services/traefik/letsencrypt:/letsencrypt"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`${TRAEFIK_DOMAIN}\`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=le"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.middlewares=traefik-auth"
      - "traefik.http.middlewares.traefik-auth.basicauth.users=${TRAEFIK_BASIC_AUTH}"
    restart: unless-stopped
    networks:
      - proxy
EOF
    echo "✓ services/traefik/docker-compose.yml"
  fi

  # n8n
  if [[ " ${ENABLED_SERVICES[@]} " =~ " n8n " ]]; then
    cat > "${REPO_DIR}/services/n8n/docker-compose.yml" <<EOF
version: "3.9"

networks:
  proxy:
    external: true

services:
  n8n:
    image: ${N8N_IMAGE}:${N8N_VERSION}
    environment:
      - N8N_HOST=${N8N_DOMAIN}
      - WEBHOOK_URL=https://${N8N_DOMAIN}/
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
    volumes:
      - "${REPO_DIR}/services/n8n/data:/home/node/.n8n"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=le"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    restart: unless-stopped
    networks:
      - proxy
EOF
    echo "✓ services/n8n/docker-compose.yml"
  fi

  # NocoDB
  if [[ " ${ENABLED_SERVICES[@]} " =~ " nocodb " ]]; then
    cat > "${REPO_DIR}/services/nocodb/docker-compose.yml" <<EOF
version: "3.9"

networks:
  proxy:
    external: true

services:
  nocodb:
    image: ${NOCODB_IMAGE}:${NOCODB_VERSION}
    environment:
      - NC_PUBLIC_URL=https://${NOCODB_DOMAIN}
    volumes:
      - "${REPO_DIR}/services/nocodb/data:/usr/app/data"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nocodb.rule=Host(\`${NOCODB_DOMAIN}\`)"
      - "traefik.http.routers.nocodb.entrypoints=websecure"
      - "traefik.http.routers.nocodb.tls.certresolver=le"
      - "traefik.http.services.nocodb.loadbalancer.server.port=8080"
    restart: unless-stopped
    networks:
      - proxy
EOF
    echo "✓ services/nocodb/docker-compose.yml"
  fi

  # Onyx
  if [[ " ${ENABLED_SERVICES[@]} " =~ " onyx " ]]; then
    cat > "${REPO_DIR}/services/onyx/docker-compose.yml" <<EOF
version: "3.9"

networks:
  proxy:
    external: true

services:
  onyx:
    image: ${ONYX_IMAGE}:${ONYX_VERSION}
    environment:
      - PORT=3000
    volumes:
      - "${REPO_DIR}/services/onyx/data:/data"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.onyx.rule=Host(\`${ONYX_DOMAIN}\`)"
      - "traefik.http.routers.onyx.entrypoints=websecure"
      - "traefik.http.routers.onyx.tls.certresolver=le"
      - "traefik.http.services.onyx.loadbalancer.server.port=3000"
    restart: unless-stopped
    networks:
      - proxy
EOF
    echo "✓ services/onyx/docker-compose.yml"
  fi
}

bring_up() {
  require_sudo
  echo ""
  echo "Uruchamiam wszystkie usługi..."
  
  for service in "${ENABLED_SERVICES[@]}"; do
    service_dir="${REPO_DIR}/services/${service}"
    if [ -f "${service_dir}/docker-compose.yml" ]; then
      echo "Uruchamiam ${service}..."
      (cd "$service_dir" && ${SUDO} docker compose pull)
      (cd "$service_dir" && ${SUDO} docker compose up -d)
    fi
  done

  echo ""
  echo "Status wszystkich kontenerów:"
  ${SUDO} docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

main() {
  ensure_dirs
  install_docker
  configure_env
  create_compose_files
  bring_up
  
  echo ""
  echo "=== Gotowe! ==="
  for service in "${ENABLED_SERVICES[@]}"; do
    case "$service" in
      traefik) echo "  Traefik: https://${TRAEFIK_DOMAIN}" ;;
      n8n) echo "  n8n: https://${N8N_DOMAIN}" ;;
      nocodb) echo "  NocoDB: https://${NOCODB_DOMAIN}" ;;
      onyx) echo "  Onyx: https://${ONYX_DOMAIN}" ;;
    esac
  done
}

main "$@"
