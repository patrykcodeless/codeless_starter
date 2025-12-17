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
  mkdir -p \
    "${REPO_DIR}/services/traefik/letsencrypt" \
    "${REPO_DIR}/services/traefik/data" \
    "${REPO_DIR}/services/n8n/data" \
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
  local value=""
  # Sprawdź czy stdin jest terminalem, jeśli nie - użyj /dev/tty
  if [ -t 0 ]; then
    while [ -z "$value" ]; do
      read -r -p "$prompt: " value
      if [ -z "$value" ]; then
        echo "Wartość nie może być pusta! Spróbuj ponownie."
      fi
    done
  else
    while [ -z "$value" ]; do
      read -r -p "$prompt: " value </dev/tty
      if [ -z "$value" ]; then
        echo "Wartość nie może być pusta! Spróbuj ponownie."
      fi
    done
  fi
  echo "$value"
}

ask_yes_no() {
  local prompt="$1"
  local value=""
  # Sprawdź czy stdin jest terminalem, jeśli nie - użyj /dev/tty
  if [ -t 0 ]; then
    while [ -z "$value" ]; do
      read -r -p "${prompt} [y/n]: " value
      case "$value" in
        y|Y|yes|YES) return 0 ;;
        n|N|no|NO) return 1 ;;
        *) 
          echo "Proszę odpowiedzieć 'y' (tak) lub 'n' (nie)"
          value=""
          ;;
      esac
    done
  else
    while [ -z "$value" ]; do
      read -r -p "${prompt} [y/n]: " value </dev/tty
      case "$value" in
        y|Y|yes|YES) return 0 ;;
        n|N|no|NO) return 1 ;;
        *) 
          echo "Proszę odpowiedzieć 'y' (tak) lub 'n' (nie)"
          value=""
          ;;
      esac
    done
  fi
}

select_services() {
  echo ""
  echo "=== Wybór usług do instalacji ==="
  echo ""
  
  local enable_n8n=0
  local enable_nocodb=0
  local enable_traefik=0
  
  ask_yes_no "Czy chcesz zainstalować n8n?" && enable_n8n=1 || enable_n8n=0
  ask_yes_no "Czy chcesz zainstalować NocoDB?" && enable_nocodb=1 || enable_nocodb=0
  ask_yes_no "Czy chcesz zainstalować Traefik (reverse proxy + HTTPS)?" && enable_traefik=1 || enable_traefik=0
  
  if [ "$enable_n8n" -eq 0 ] && [ "$enable_nocodb" -eq 0 ] && [ "$enable_traefik" -eq 0 ]; then
    echo "Nie wybrano żadnej usługi. Przerywam." >&2
    exit 1
  fi
  
  ENABLED_SERVICES=()
  [ "$enable_n8n" -eq 1 ] && ENABLED_SERVICES+=("n8n")
  [ "$enable_nocodb" -eq 1 ] && ENABLED_SERVICES+=("nocodb")
  [ "$enable_traefik" -eq 1 ] && ENABLED_SERVICES+=("traefik")
  
  echo ""
  echo "Wybrane usługi: ${ENABLED_SERVICES[*]}"
}

configure_domain() {
  echo ""
  echo "=== Konfiguracja domeny ==="
  echo ""
  
  if ask_yes_no "Czy masz domenę dla usług?"; then
    BASE_DOMAIN="$(ask "Podaj domenę bazową (np. example.com)")"
    
    # Automatycznie generuj subdomeny
    if [[ " ${ENABLED_SERVICES[@]} " =~ " n8n " ]]; then
      N8N_DOMAIN="n8n.${BASE_DOMAIN}"
    fi
    if [[ " ${ENABLED_SERVICES[@]} " =~ " nocodb " ]]; then
      NOCODB_DOMAIN="nocodb.${BASE_DOMAIN}"
    fi
    if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
      TRAEFIK_DOMAIN="traefik.${BASE_DOMAIN}"
    fi
    
    echo ""
    echo "Wygenerowane domeny:"
    [[ " ${ENABLED_SERVICES[@]} " =~ " n8n " ]] && echo "  n8n: ${N8N_DOMAIN}"
    [[ " ${ENABLED_SERVICES[@]} " =~ " nocodb " ]] && echo "  nocodb: ${NOCODB_DOMAIN}"
    [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]] && echo "  traefik: ${TRAEFIK_DOMAIN}"
  else
    BASE_DOMAIN="localhost"
    if [[ " ${ENABLED_SERVICES[@]} " =~ " n8n " ]]; then
      N8N_DOMAIN="localhost"
    fi
    if [[ " ${ENABLED_SERVICES[@]} " =~ " nocodb " ]]; then
      NOCODB_DOMAIN="localhost"
    fi
    if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
      TRAEFIK_DOMAIN="localhost"
    fi
    echo "Używam localhost jako domeny."
  fi
}

configure_versions() {
  echo ""
  echo "=== Konfiguracja wersji ==="
  echo ""
  
  if [[ " ${ENABLED_SERVICES[@]} " =~ " n8n " ]]; then
    if ask_yes_no "Czy chcesz użyć najnowszej wersji n8n?"; then
      N8N_VERSION="latest"
    else
      N8N_VERSION="$(ask "Podaj konkretną wersję n8n (np. 1.72.0)")"
    fi
  fi
  
  if [[ " ${ENABLED_SERVICES[@]} " =~ " nocodb " ]]; then
    if ask_yes_no "Czy chcesz użyć najnowszej wersji NocoDB?"; then
      NOCODB_VERSION="latest"
    else
      NOCODB_VERSION="$(ask "Podaj konkretną wersję NocoDB (np. 0.204.3)")"
    fi
  fi
  
  if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
    if ask_yes_no "Czy chcesz użyć najnowszej wersji Traefik?"; then
      TRAEFIK_VERSION="latest"
    else
      TRAEFIK_VERSION="$(ask "Podaj konkretną wersję Traefik (np. 2.11)")"
    fi
  fi
}

configure_n8n() {
  if [[ ! " ${ENABLED_SERVICES[@]} " =~ " n8n " ]]; then
    return
  fi
  
  echo ""
  echo "=== Konfiguracja n8n ==="
  echo ""
  
  N8N_PORT="$(ask "Na jakim porcie ma działać n8n?")"
  
  # SMTP
  echo ""
  if ask_yes_no "Czy chcesz skonfigurować SMTP dla n8n?"; then
    N8N_SMTP_HOST="$(ask "SMTP host (np. smtp.gmail.com)")"
    N8N_SMTP_PORT="$(ask "SMTP port (np. 587)")"
    N8N_SMTP_USER="$(ask "SMTP użytkownik")"
    N8N_SMTP_PASS="$(ask "SMTP hasło")"
    N8N_SMTP_SENDER="$(ask "Adres nadawcy e-mail")"
    if ask_yes_no "Czy używać TLS/SSL dla SMTP?"; then
      N8N_SMTP_SECURE="true"
    else
      N8N_SMTP_SECURE="false"
    fi
  else
    N8N_SMTP_HOST=""
    N8N_SMTP_PORT=""
    N8N_SMTP_USER=""
    N8N_SMTP_PASS=""
    N8N_SMTP_SENDER=""
    N8N_SMTP_SECURE="false"
  fi
  
  # Webhook URL
  if [ "$BASE_DOMAIN" != "localhost" ] && [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
    N8N_WEBHOOK_URL="https://${N8N_DOMAIN}/"
    N8N_PROTOCOL="https"
  else
    N8N_WEBHOOK_URL="http://${N8N_DOMAIN}:${N8N_PORT}/"
    N8N_PROTOCOL="http"
  fi
}

configure_traefik() {
  if [[ ! " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
    return
  fi
  
  echo ""
  echo "=== Konfiguracja Traefik ==="
  echo ""
  
  TRAEFIK_ACME_EMAIL="$(ask "E-mail do Let's Encrypt")"
  
  echo ""
  echo "Konfiguracja Basic Auth dla panelu Traefik:"
  TRAEFIK_AUTH_USER="$(ask "Użytkownik")"
  TRAEFIK_AUTH_PASS="$(ask "Hasło")"
  
  # Generuj hash hasła (używamy htpasswd jeśli dostępne, w przeciwnym razie prosty format)
  if command_exists htpasswd; then
    TRAEFIK_BASIC_AUTH="$(htpasswd -nb "${TRAEFIK_AUTH_USER}" "${TRAEFIK_AUTH_PASS}")"
  else
    # Fallback - prosty format (niezalecane, ale działa)
    TRAEFIK_BASIC_AUTH="${TRAEFIK_AUTH_USER}:${TRAEFIK_AUTH_PASS}"
    echo "Uwaga: htpasswd nie jest dostępne. Używam prostego formatu (niezalecane dla produkcji)."
  fi
}

configure_env() {
  select_services
  configure_domain
  configure_versions
  configure_n8n
  configure_traefik
  
  # Zapisz .env
  {
    echo "BASE_DOMAIN=${BASE_DOMAIN}"
    echo ""
    if [[ " ${ENABLED_SERVICES[@]} " =~ " n8n " ]]; then
      echo "N8N_IMAGE=n8nio/n8n"
      echo "N8N_VERSION=${N8N_VERSION}"
      echo "N8N_DOMAIN=${N8N_DOMAIN}"
      echo "N8N_PORT=${N8N_PORT}"
      echo "N8N_WEBHOOK_URL=${N8N_WEBHOOK_URL}"
      echo "N8N_PROTOCOL=${N8N_PROTOCOL}"
      if [ -n "$N8N_SMTP_HOST" ]; then
        echo "N8N_SMTP_HOST=${N8N_SMTP_HOST}"
        echo "N8N_SMTP_PORT=${N8N_SMTP_PORT}"
        echo "N8N_SMTP_USER=${N8N_SMTP_USER}"
        echo "N8N_SMTP_PASS=${N8N_SMTP_PASS}"
        echo "N8N_SMTP_SENDER=${N8N_SMTP_SENDER}"
        echo "N8N_SMTP_SECURE=${N8N_SMTP_SECURE}"
      fi
      echo ""
    fi
    if [[ " ${ENABLED_SERVICES[@]} " =~ " nocodb " ]]; then
      echo "NOCODB_IMAGE=nocodb/nocodb"
      echo "NOCODB_VERSION=${NOCODB_VERSION}"
      echo "NOCODB_DOMAIN=${NOCODB_DOMAIN}"
      echo ""
    fi
    if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
      echo "TRAEFIK_IMAGE=traefik:${TRAEFIK_VERSION}"
      echo "TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN}"
      echo "TRAEFIK_ACME_EMAIL=${TRAEFIK_ACME_EMAIL}"
      echo "TRAEFIK_BASIC_AUTH=\"${TRAEFIK_BASIC_AUTH}\""
    fi
  } > "$ENV_FILE"
  
  echo ""
  echo ".env zapisany w ${ENV_FILE}"
}

create_compose_files() {
  echo ""
  echo "=== Tworzenie docker-compose.yml dla każdej usługi ==="
  echo ""
  
  # Wczytaj .env
  if [ -f "$ENV_FILE" ]; then
    set +u
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
    set -u
  fi
  
  # Utwórz wspólną sieć (jeśli nie istnieje)
  if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
    if ! docker network inspect proxy >/dev/null 2>&1; then
      require_sudo
      echo "Tworzę sieć 'proxy'..."
      ${SUDO} docker network create proxy
    fi
  fi
  
  # n8n
  if [[ " ${ENABLED_SERVICES[@]} " =~ " n8n " ]]; then
    cat > "${REPO_DIR}/services/n8n/docker-compose.yml" <<EOF
services:
  n8n:
    image: ${N8N_IMAGE}:${N8N_VERSION}
    ports:
      - "${N8N_PORT}:5678"
    environment:
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - WEBHOOK_URL=${N8N_WEBHOOK_URL}
EOF
    
    if [ -n "$N8N_SMTP_HOST" ]; then
      cat >> "${REPO_DIR}/services/n8n/docker-compose.yml" <<EOF
      - N8N_EMAIL_MODE=smtp
      - N8N_SMTP_HOST=${N8N_SMTP_HOST}
      - N8N_SMTP_PORT=${N8N_SMTP_PORT}
      - N8N_SMTP_USER=${N8N_SMTP_USER}
      - N8N_SMTP_PASS=${N8N_SMTP_PASS}
      - N8N_SMTP_SENDER=${N8N_SMTP_SENDER}
      - N8N_SMTP_SECURE=${N8N_SMTP_SECURE}
EOF
    fi
    
    cat >> "${REPO_DIR}/services/n8n/docker-compose.yml" <<EOF
    volumes:
      - "${REPO_DIR}/services/n8n/data:/home/node/.n8n"
    restart: unless-stopped
EOF
    
    if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
      cat >> "${REPO_DIR}/services/n8n/docker-compose.yml" <<EOF
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=le"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    networks:
      - proxy
EOF
    fi
    
    echo "✓ services/n8n/docker-compose.yml"
  fi
  
  # NocoDB
  if [[ " ${ENABLED_SERVICES[@]} " =~ " nocodb " ]]; then
    cat > "${REPO_DIR}/services/nocodb/docker-compose.yml" <<EOF
services:
  nocodb:
    image: ${NOCODB_IMAGE}:${NOCODB_VERSION}
EOF
    
    if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
      cat >> "${REPO_DIR}/services/nocodb/docker-compose.yml" <<EOF
    environment:
      - NC_PUBLIC_URL=https://${NOCODB_DOMAIN}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nocodb.rule=Host(\`${NOCODB_DOMAIN}\`)"
      - "traefik.http.routers.nocodb.entrypoints=websecure"
      - "traefik.http.routers.nocodb.tls.certresolver=le"
      - "traefik.http.services.nocodb.loadbalancer.server.port=8080"
    networks:
      - proxy
EOF
    else
      cat >> "${REPO_DIR}/services/nocodb/docker-compose.yml" <<EOF
    ports:
      - "8080:8080"
    environment:
      - NC_PUBLIC_URL=http://${NOCODB_DOMAIN}:8080
EOF
    fi
    
    cat >> "${REPO_DIR}/services/nocodb/docker-compose.yml" <<EOF
    volumes:
      - "${REPO_DIR}/services/nocodb/data:/usr/app/data"
    restart: unless-stopped
EOF
    
    if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
      cat >> "${REPO_DIR}/services/nocodb/docker-compose.yml" <<EOF
    networks:
      - proxy
EOF
    fi
    
    echo "✓ services/nocodb/docker-compose.yml"
  fi
  
  # Traefik
  if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
    cat > "${REPO_DIR}/services/traefik/docker-compose.yml" <<EOF
networks:
  proxy: {}

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
}

bring_up() {
  require_sudo
  echo ""
  echo "=== Uruchamianie usług ==="
  echo ""
  
  for service in "${ENABLED_SERVICES[@]}"; do
    service_dir="${REPO_DIR}/services/${service}"
    if [ -f "${service_dir}/docker-compose.yml" ]; then
      echo "Uruchamiam ${service}..."
      (cd "$service_dir" && ${SUDO} docker compose pull)
      (cd "$service_dir" && ${SUDO} docker compose up -d)
    fi
  done
  
  echo ""
  echo "Status kontenerów:"
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
  if [[ " ${ENABLED_SERVICES[@]} " =~ " n8n " ]]; then
    if [ "$BASE_DOMAIN" != "localhost" ]; then
      echo "  n8n: https://${N8N_DOMAIN}"
    else
      echo "  n8n: http://${N8N_DOMAIN}:${N8N_PORT}"
    fi
  fi
  if [[ " ${ENABLED_SERVICES[@]} " =~ " nocodb " ]]; then
    if [ "$BASE_DOMAIN" != "localhost" ]; then
      echo "  NocoDB: https://${NOCODB_DOMAIN}"
    else
      echo "  NocoDB: http://${NOCODB_DOMAIN}:8080"
    fi
  fi
  if [[ " ${ENABLED_SERVICES[@]} " =~ " traefik " ]]; then
    echo "  Traefik: https://${TRAEFIK_DOMAIN}"
  fi
}

main "$@"
