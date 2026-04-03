#!/usr/bin/env bash
set -euo pipefail

# ─── Resolve working directory ────────────────────────────────────────────────
set +u
if [ -n "${BASH_SOURCE:-}" ]; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  REPO_DIR="$(pwd)"
fi
set -u

# ─── Global constants ─────────────────────────────────────────────────────────
LOG_FILE="${REPO_DIR}/install.log"
ENV_FILE="${REPO_DIR}/.env"
SUDO=""

# Resource tracking for rollback
CREATED_DIRS=()
CREATED_FILES=()
CREATED_NETWORKS=()
STARTED_SERVICES=()
ROLLBACK_TRIGGERED=0

# Service selection flags
BASE_DOMAIN="localhost"
INSTALL_N8N=0
INSTALL_NOCODB=0
INSTALL_ONYX=0
USE_TRAEFIK=0

# Versions
N8N_VERSION="latest"
NOCODB_VERSION="latest"
ONYX_VERSION="latest"
TRAEFIK_VERSION="v3.3"

# Domain variables
N8N_DOMAIN="localhost"
NOCODB_DOMAIN="localhost"
ONYX_DOMAIN="localhost"
TRAEFIK_DOMAIN="localhost"

# n8n configuration
N8N_PORT="5678"
N8N_PROTOCOL="http"
N8N_WEBHOOK_URL=""
N8N_SMTP_HOST=""
N8N_SMTP_PORT=""
N8N_SMTP_USER=""
N8N_SMTP_PASS=""
N8N_SMTP_SENDER=""
N8N_SMTP_SECURE="false"

# NocoDB configuration
NOCODB_PORT="8080"

# Onyx configuration
ONYX_PORT="3000"

# Traefik configuration
TRAEFIK_ACME_EMAIL=""
TRAEFIK_AUTH_USER=""
TRAEFIK_AUTH_PASS=""
TRAEFIK_BASIC_AUTH=""
TRAEFIK_DASHBOARD=0

# ─── Logging ──────────────────────────────────────────────────────────────────
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

log_error() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
  echo "$msg" >&2
  echo "$msg" >> "$LOG_FILE"
}

log_section() {
  local sep="══════════════════════════════════════════════════"
  log ""
  log "$sep"
  log "  $*"
  log "$sep"
  log ""
}

# ─── Rollback ─────────────────────────────────────────────────────────────────
rollback() {
  if [ "$ROLLBACK_TRIGGERED" -eq 1 ]; then
    return
  fi
  ROLLBACK_TRIGGERED=1

  log_error "Instalacja nie powiodła się. Uruchamiam rollback..."

  # Stop started containers
  local svc
  for svc in "${STARTED_SERVICES[@]:-}"; do
    local svc_dir="${REPO_DIR}/services/${svc}"
    if [ -f "${svc_dir}/docker-compose.yml" ]; then
      log "Zatrzymuję ${svc}..."
      (cd "$svc_dir" && ${SUDO:-} docker compose down --remove-orphans 2>>"$LOG_FILE") || true
    fi
  done

  # Remove created networks
  local net
  for net in "${CREATED_NETWORKS[@]:-}"; do
    log "Usuwam sieć Docker '${net}'..."
    ${SUDO:-} docker network rm "$net" 2>>"$LOG_FILE" || true
  done

  # Remove generated files
  local f
  for f in "${CREATED_FILES[@]:-}"; do
    log "Usuwam plik ${f}..."
    rm -f "$f" 2>/dev/null || true
  done

  # Remove created directories (reverse order, only if empty)
  local i
  for (( i=${#CREATED_DIRS[@]}-1; i>=0; i-- )); do
    local d="${CREATED_DIRS[$i]}"
    if [ -d "$d" ] && [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
      log "Usuwam pusty katalog ${d}..."
      rmdir "$d" 2>/dev/null || true
    fi
  done

  log_error "Rollback zakończony. Szczegóły w: ${LOG_FILE}"
}

trap rollback ERR

# ─── Utility helpers ──────────────────────────────────────────────────────────
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_sudo() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    SUDO="sudo"
  else
    SUDO=""
  fi
}

# Read input from terminal even when stdin is piped (curl|bash)
ask() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  local full_prompt="$prompt"
  [ -n "$default" ] && full_prompt="${prompt} [domyślnie: ${default}]"

  while [ -z "$value" ]; do
    if [ -t 0 ]; then
      read -r -p "${full_prompt}: " value
    else
      read -r -p "${full_prompt}: " value </dev/tty
    fi
    if [ -z "$value" ] && [ -n "$default" ]; then
      value="$default"
      break
    fi
    [ -z "$value" ] && echo "Wartość nie może być pusta. Spróbuj ponownie."
  done
  echo "$value"
}

ask_yes_no() {
  local prompt="$1"
  local value=""
  while true; do
    if [ -t 0 ]; then
      read -r -p "${prompt} [y/n]: " value
    else
      read -r -p "${prompt} [y/n]: " value </dev/tty
    fi
    case "${value,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo "Proszę odpowiedzieć 'y' (tak) lub 'n' (nie)." ;;
    esac
  done
}

# ─── Docker installation ──────────────────────────────────────────────────────
install_docker_linux() {
  require_sudo
  log "Instaluję Docker na Linux..."

  if command_exists apt-get; then
    log "  Wykryto apt-get (Debian/Ubuntu)"
    ${SUDO} apt-get update -y >> "$LOG_FILE" 2>&1
    ${SUDO} apt-get install -y ca-certificates curl gnupg lsb-release >> "$LOG_FILE" 2>&1
    if ! [ -f /etc/apt/keyrings/docker.gpg ]; then
      ${SUDO} install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg" \
        | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
$(. /etc/os-release; echo "$VERSION_CODENAME") stable" \
        | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
      ${SUDO} apt-get update -y >> "$LOG_FILE" 2>&1
    fi
    ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

  elif command_exists dnf; then
    log "  Wykryto dnf (Fedora/RHEL)"
    ${SUDO} dnf -y install dnf-plugins-core >> "$LOG_FILE" 2>&1
    ${SUDO} dnf config-manager --add-repo \
      https://download.docker.com/linux/centos/docker-ce.repo >> "$LOG_FILE" 2>&1
    ${SUDO} dnf install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

  elif command_exists yum; then
    log "  Wykryto yum (CentOS/RHEL)"
    ${SUDO} yum install -y yum-utils >> "$LOG_FILE" 2>&1
    ${SUDO} yum-config-manager --add-repo \
      https://download.docker.com/linux/centos/docker-ce.repo >> "$LOG_FILE" 2>&1
    ${SUDO} yum install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

  else
    log_error "Brak obsługiwanego menedżera pakietów (apt/dnf/yum)."
    log_error "Zainstaluj Docker ręcznie: https://docs.docker.com/engine/install/"
    exit 1
  fi

  ${SUDO} systemctl enable docker >> "$LOG_FILE" 2>&1 || true
  ${SUDO} systemctl start docker  >> "$LOG_FILE" 2>&1 || true

  # Add user to docker group so sudo is not needed later
  if [ -n "${SUDO}" ] && command_exists usermod; then
    ${SUDO} usermod -aG docker "${USER:-$(whoami)}" >> "$LOG_FILE" 2>&1 || true
  fi

  log "Docker zainstalowany pomyślnie."
}

install_docker() {
  log_section "Krok 1: Instalacja Docker"

  if command_exists docker && docker compose version >/dev/null 2>&1; then
    log "Docker i docker compose już zainstalowane — pomijam."
    log "  $(docker --version)"
    log "  $(docker compose version)"
    return
  fi

  install_docker_linux

  if ! command_exists docker || ! docker compose version >/dev/null 2>&1; then
    log_error "Instalacja Docker nie powiodła się."
    exit 1
  fi

  log "Weryfikacja: $(docker --version)"
  log "Weryfikacja: $(docker compose version)"
}

# ─── Interactive configuration ────────────────────────────────────────────────
configure_domain() {
  log_section "Krok 2a: Konfiguracja domeny"

  if ask_yes_no "Czy masz już domenę klienta dla tego projektu?"; then
    BASE_DOMAIN="$(ask "Podaj pełny adres domeny głównej (np. example.com)")"
    USE_TRAEFIK=1
    log "Domena: ${BASE_DOMAIN}"

    log "Traefik zostanie skonfigurowany jako reverse proxy z SSL (Let's Encrypt)."
  else
    BASE_DOMAIN="localhost"
    USE_TRAEFIK=0
    log "Brak domeny — usługi dostępne wyłącznie lokalnie (HTTP)."
  fi
}

select_services() {
  log_section "Krok 2b: Wybór usług"

  ask_yes_no "Czy chcesz zainstalować n8n (automatyzacja przepływów)?" \
    && INSTALL_N8N=1 || INSTALL_N8N=0

  ask_yes_no "Czy chcesz zainstalować NocoDB (zarządzanie bazami danych)?" \
    && INSTALL_NOCODB=1 || INSTALL_NOCODB=0

  ask_yes_no "Czy chcesz zainstalować Onyx.app (AI knowledge base)?" \
    && INSTALL_ONYX=1 || INSTALL_ONYX=0

  if [ "$INSTALL_N8N" -eq 0 ] && [ "$INSTALL_NOCODB" -eq 0 ] && [ "$INSTALL_ONYX" -eq 0 ]; then
    log_error "Nie wybrano żadnej usługi. Przerywam instalację."
    exit 1
  fi

  log "Wybrane usługi:"
  [ "$INSTALL_N8N" -eq 1 ]    && log "  ✓ n8n"          || true
  [ "$INSTALL_NOCODB" -eq 1 ] && log "  ✓ NocoDB"       || true
  [ "$INSTALL_ONYX" -eq 1 ]   && log "  ✓ Onyx.app"     || true
  [ "$USE_TRAEFIK" -eq 1 ]    && log "  ✓ Traefik (automatyczny — domena wykryta)" || true
}

configure_versions() {
  log_section "Krok 3: Wersje usług"

  if [ "$INSTALL_N8N" -eq 1 ]; then
    if ask_yes_no "Zainstalować najnowszą wersję n8n?"; then
      N8N_VERSION="latest"
    else
      N8N_VERSION="$(ask "Podaj wersję n8n (np. 1.72.0)")"
    fi
    log "n8n: ${N8N_VERSION}"
  fi

  if [ "$INSTALL_NOCODB" -eq 1 ]; then
    if ask_yes_no "Zainstalować najnowszą wersję NocoDB?"; then
      NOCODB_VERSION="latest"
    else
      NOCODB_VERSION="$(ask "Podaj wersję NocoDB (np. 0.204.3)")"
    fi
    log "NocoDB: ${NOCODB_VERSION}"
  fi

  if [ "$INSTALL_ONYX" -eq 1 ]; then
    if ask_yes_no "Zainstalować najnowszą wersję Onyx?"; then
      ONYX_VERSION="latest"
    else
      ONYX_VERSION="$(ask "Podaj wersję Onyx (np. v0.20.0)")"
    fi
    log "Onyx: ${ONYX_VERSION}"
  fi
}

configure_subdomains() {
  if [ "$USE_TRAEFIK" -eq 1 ]; then
    [ "$INSTALL_N8N" -eq 1 ]    && N8N_DOMAIN="n8n.${BASE_DOMAIN}"
    [ "$INSTALL_NOCODB" -eq 1 ] && NOCODB_DOMAIN="nocodb.${BASE_DOMAIN}"
    [ "$INSTALL_ONYX" -eq 1 ]   && ONYX_DOMAIN="onyx.${BASE_DOMAIN}"
    TRAEFIK_DOMAIN="traefik.${BASE_DOMAIN}"

    log "Wygenerowane subdomeny:"
    [ "$INSTALL_N8N" -eq 1 ]       && log "  n8n:    https://${N8N_DOMAIN}"    || true
    [ "$INSTALL_NOCODB" -eq 1 ]    && log "  NocoDB: https://${NOCODB_DOMAIN}" || true
    [ "$INSTALL_ONYX" -eq 1 ]      && log "  Onyx:   https://${ONYX_DOMAIN}"   || true
    [ "$TRAEFIK_DASHBOARD" -eq 1 ] && log "  Traefik: https://${TRAEFIK_DOMAIN}" || true
  else
    N8N_DOMAIN="localhost"
    NOCODB_DOMAIN="localhost"
    ONYX_DOMAIN="localhost"
  fi
}

configure_n8n_extras() {
  if [ "$INSTALL_N8N" -eq 0 ]; then
    return
  fi

  log ""
  log "=== Konfiguracja n8n ==="

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    N8N_PROTOCOL="https"
    N8N_WEBHOOK_URL="https://${N8N_DOMAIN}/"
  else
    N8N_PORT="$(ask "Port dla n8n" "5678")"
    N8N_PROTOCOL="http"
    N8N_WEBHOOK_URL="http://localhost:${N8N_PORT}/"
  fi

  if ask_yes_no "Czy chcesz skonfigurować SMTP dla n8n?"; then
    N8N_SMTP_HOST="$(ask "SMTP host (np. smtp.gmail.com)")"
    N8N_SMTP_PORT="$(ask "SMTP port" "587")"
    N8N_SMTP_USER="$(ask "SMTP użytkownik (e-mail)")"
    N8N_SMTP_PASS="$(ask "SMTP hasło")"
    N8N_SMTP_SENDER="$(ask "Adres nadawcy e-mail")"
    ask_yes_no "Używać TLS/SSL dla SMTP?" \
      && N8N_SMTP_SECURE="true" || N8N_SMTP_SECURE="false"
  fi
}

configure_traefik_auth() {
  if [ "$USE_TRAEFIK" -eq 0 ]; then
    return
  fi

  log ""
  log "=== Konfiguracja Traefik ==="

  TRAEFIK_ACME_EMAIL="$(ask "E-mail do Let's Encrypt (rejestracja certyfikatów)")"

  if ask_yes_no "Czy chcesz włączyć dashboard Traefika?"; then
    TRAEFIK_DASHBOARD=1
    TRAEFIK_AUTH_USER="$(ask "Użytkownik do dashboardu Traefik")"
    TRAEFIK_AUTH_PASS="$(ask "Hasło do dashboardu Traefik")"

    if command_exists htpasswd; then
      TRAEFIK_BASIC_AUTH="$(htpasswd -nb "${TRAEFIK_AUTH_USER}" "${TRAEFIK_AUTH_PASS}")"
    elif command_exists openssl; then
      local hash
      hash="$(openssl passwd -apr1 "${TRAEFIK_AUTH_PASS}")"
      TRAEFIK_BASIC_AUTH="${TRAEFIK_AUTH_USER}:${hash}"
    else
      log "Uwaga: htpasswd i openssl niedostępne — używam prostego formatu (niezalecane produkcyjnie)."
      TRAEFIK_BASIC_AUTH="${TRAEFIK_AUTH_USER}:${TRAEFIK_AUTH_PASS}"
    fi
  else
    TRAEFIK_DASHBOARD=0
    log "Dashboard Traefika wyłączony."
  fi

  log "Traefik skonfigurowany."
}

# ─── Directory structure ──────────────────────────────────────────────────────
ensure_dirs() {
  log_section "Krok 4a: Tworzenie struktury katalogów"

  local dirs=()

  [ "$INSTALL_N8N" -eq 1 ] && dirs+=("${REPO_DIR}/services/n8n/data")

  [ "$INSTALL_NOCODB" -eq 1 ] && dirs+=("${REPO_DIR}/services/nocodb/data")

  if [ "$INSTALL_ONYX" -eq 1 ]; then
    dirs+=(
      "${REPO_DIR}/services/onyx/data"
      "${REPO_DIR}/services/onyx/postgres_data"
      "${REPO_DIR}/services/onyx/vespa_data"
    )
  fi

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    dirs+=(
      "${REPO_DIR}/services/traefik/data"
      "${REPO_DIR}/services/traefik/letsencrypt"
    )
  fi

  local d
  for d in "${dirs[@]}"; do
    if [ ! -d "$d" ]; then
      mkdir -p "$d"
      CREATED_DIRS+=("$d")
      log "  Utworzono: ${d}"
    else
      log "  Istnieje:  ${d}"
    fi
  done

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    local acme="${REPO_DIR}/services/traefik/letsencrypt/acme.json"
    if [ ! -f "$acme" ]; then
      touch "$acme"
      chmod 600 "$acme"
      CREATED_FILES+=("$acme")
      log "  Utworzono: ${acme} (chmod 600)"
    fi
  fi
}

# ─── Generate .env ────────────────────────────────────────────────────────────
generate_env() {
  log "Generuję plik .env..."

  {
    echo "# Wygenerowano automatycznie przez install.sh"
    echo "# Data: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "BASE_DOMAIN=${BASE_DOMAIN}"
    echo ""

    if [ "$INSTALL_N8N" -eq 1 ]; then
      echo "# n8n"
      echo "N8N_IMAGE=n8nio/n8n"
      echo "N8N_VERSION=${N8N_VERSION}"
      echo "N8N_DOMAIN=${N8N_DOMAIN}"
      echo "N8N_PORT=${N8N_PORT}"
      echo "N8N_PROTOCOL=${N8N_PROTOCOL}"
      echo "N8N_WEBHOOK_URL=${N8N_WEBHOOK_URL}"
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

    if [ "$INSTALL_NOCODB" -eq 1 ]; then
      echo "# NocoDB"
      echo "NOCODB_IMAGE=nocodb/nocodb"
      echo "NOCODB_VERSION=${NOCODB_VERSION}"
      echo "NOCODB_DOMAIN=${NOCODB_DOMAIN}"
      echo ""
    fi

    if [ "$INSTALL_ONYX" -eq 1 ]; then
      echo "# Onyx"
      echo "ONYX_VERSION=${ONYX_VERSION}"
      echo "ONYX_DOMAIN=${ONYX_DOMAIN}"
      echo ""
    fi

    if [ "$USE_TRAEFIK" -eq 1 ]; then
      echo "# Traefik"
      echo "TRAEFIK_IMAGE=traefik:${TRAEFIK_VERSION}"
      echo "TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN}"
      echo "TRAEFIK_ACME_EMAIL=${TRAEFIK_ACME_EMAIL}"
      [ "$TRAEFIK_DASHBOARD" -eq 1 ] && echo "TRAEFIK_BASIC_AUTH=${TRAEFIK_BASIC_AUTH}"
    fi
  } > "$ENV_FILE"

  CREATED_FILES+=("$ENV_FILE")
  log "  .env zapisany w: ${ENV_FILE}"
}

# ─── docker-compose generators ───────────────────────────────────────────────
create_compose_n8n() {
  local f="${REPO_DIR}/services/n8n/docker-compose.yml"
  log "  Generuję services/n8n/docker-compose.yml"

  cat > "$f" <<YAML
services:
  n8n:
    image: n8nio/n8n:${N8N_VERSION}
    container_name: n8n
    environment:
      - N8N_HOST=${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - WEBHOOK_URL=${N8N_WEBHOOK_URL}
      # Log retention: 30 days (default is 7)
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=30
      - EXECUTIONS_DATA_SAVE_ON_ERROR=all
      - EXECUTIONS_DATA_SAVE_ON_SUCCESS=none
      - EXECUTIONS_DATA_SAVE_ON_PROGRESS=false
      - N8N_LOG_LEVEL=info
      - GENERIC_TIMEZONE=Europe/Warsaw
YAML

  if [ -n "$N8N_SMTP_HOST" ]; then
    cat >> "$f" <<YAML
      - N8N_EMAIL_MODE=smtp
      - N8N_SMTP_HOST=${N8N_SMTP_HOST}
      - N8N_SMTP_PORT=${N8N_SMTP_PORT}
      - N8N_SMTP_USER=${N8N_SMTP_USER}
      - N8N_SMTP_PASS=${N8N_SMTP_PASS}
      - N8N_SMTP_SENDER=${N8N_SMTP_SENDER}
      - N8N_SMTP_SSL=${N8N_SMTP_SECURE}
YAML
  fi

  cat >> "$f" <<YAML
    volumes:
      - n8n_data:/home/node/.n8n
    restart: unless-stopped
YAML

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    cat >> "$f" <<YAML
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_DOMAIN}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=le"
      - "traefik.http.routers.n8n.middlewares=n8n-headers"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.http.middlewares.n8n-headers.headers.SSLRedirect=true"
      - "traefik.http.middlewares.n8n-headers.headers.forceSTSHeader=true"
      - "traefik.http.middlewares.n8n-headers.headers.STSSeconds=31536000"
    networks:
      - proxy
YAML
  else
    cat >> "$f" <<YAML
    ports:
      - "${N8N_PORT}:5678"
YAML
  fi

  cat >> "$f" <<YAML

volumes:
  n8n_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${REPO_DIR}/services/n8n/data
YAML

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    cat >> "$f" <<YAML

networks:
  proxy:
    external: true
YAML
  fi

  CREATED_FILES+=("$f")
}

create_compose_nocodb() {
  local f="${REPO_DIR}/services/nocodb/docker-compose.yml"
  log "  Generuję services/nocodb/docker-compose.yml"

  local public_url
  if [ "$USE_TRAEFIK" -eq 1 ]; then
    public_url="https://${NOCODB_DOMAIN}"
  else
    public_url="http://localhost:${NOCODB_PORT}"
  fi

  cat > "$f" <<YAML
services:
  nocodb:
    image: nocodb/nocodb:${NOCODB_VERSION}
    container_name: nocodb
    environment:
      - NC_PUBLIC_URL=${public_url}
    volumes:
      - nocodb_data:/usr/app/data
    restart: unless-stopped
YAML

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    cat >> "$f" <<YAML
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nocodb.rule=Host(\`${NOCODB_DOMAIN}\`)"
      - "traefik.http.routers.nocodb.entrypoints=websecure"
      - "traefik.http.routers.nocodb.tls.certresolver=le"
      - "traefik.http.services.nocodb.loadbalancer.server.port=8080"
    networks:
      - proxy
YAML
  else
    cat >> "$f" <<YAML
    ports:
      - "${NOCODB_PORT}:8080"
YAML
  fi

  cat >> "$f" <<YAML

volumes:
  nocodb_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${REPO_DIR}/services/nocodb/data
YAML

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    cat >> "$f" <<YAML

networks:
  proxy:
    external: true
YAML
  fi

  CREATED_FILES+=("$f")
}

create_compose_onyx() {
  local f="${REPO_DIR}/services/onyx/docker-compose.yml"
  log "  Generuję services/onyx/docker-compose.yml"

  # Generate random secrets
  local secret_key pg_pass
  if command_exists openssl; then
    secret_key="$(openssl rand -hex 32)"
    pg_pass="$(openssl rand -hex 16)"
  else
    secret_key="$(head -c 32 /dev/urandom | base64 | tr -d '=/+\n' | head -c 32)"
    pg_pass="$(head -c 16 /dev/urandom | base64 | tr -d '=/+\n' | head -c 16)"
  fi

  cat > "$f" <<YAML
services:
  # ── PostgreSQL database ──────────────────────────────────────────────────
  relational_db:
    image: postgres:15.2-alpine
    container_name: onyx_postgres
    environment:
      - POSTGRES_USER=onyx
      - POSTGRES_PASSWORD=${pg_pass}
      - POSTGRES_DB=onyx
    volumes:
      - onyx_postgres:/var/lib/postgresql/data
    restart: unless-stopped
    networks:
      - onyx_internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U onyx"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ── Redis cache ──────────────────────────────────────────────────────────
  cache:
    image: redis:7.4-alpine
    container_name: onyx_redis
    restart: unless-stopped
    networks:
      - onyx_internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ── Vespa vector search ──────────────────────────────────────────────────
  index:
    image: vespaengine/vespa:8.526.15
    container_name: onyx_vespa
    volumes:
      - onyx_vespa:/opt/vespa/var
    restart: unless-stopped
    networks:
      - onyx_internal

  # ── API server ───────────────────────────────────────────────────────────
  api_server:
    image: ghcr.io/onyx-dot-app/onyx-backend:${ONYX_VERSION}
    container_name: onyx_api
    command: /usr/local/bin/api_server
    environment:
      - AUTH_TYPE=disabled
      - POSTGRES_HOST=relational_db
      - POSTGRES_USER=onyx
      - POSTGRES_PASSWORD=${pg_pass}
      - POSTGRES_DB=onyx
      - VESPA_HOST=index
      - REDIS_HOST=cache
      - SECRET_KEY=${secret_key}
      - DISABLE_TELEMETRY=true
      - LOG_LEVEL=info
    depends_on:
      relational_db:
        condition: service_healthy
      cache:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - onyx_internal
YAML

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    cat >> "$f" <<YAML
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.onyx-api.rule=Host(\`${ONYX_DOMAIN}\`) && PathPrefix(\`/api\`)"
      - "traefik.http.routers.onyx-api.entrypoints=websecure"
      - "traefik.http.routers.onyx-api.tls.certresolver=le"
      - "traefik.http.services.onyx-api.loadbalancer.server.port=8080"
YAML
  fi

  cat >> "$f" <<YAML

  # ── Background worker ────────────────────────────────────────────────────
  background:
    image: ghcr.io/onyx-dot-app/onyx-backend:${ONYX_VERSION}
    container_name: onyx_background
    command: /usr/local/bin/background
    environment:
      - AUTH_TYPE=disabled
      - POSTGRES_HOST=relational_db
      - POSTGRES_USER=onyx
      - POSTGRES_PASSWORD=${pg_pass}
      - POSTGRES_DB=onyx
      - VESPA_HOST=index
      - REDIS_HOST=cache
      - SECRET_KEY=${secret_key}
      - DISABLE_TELEMETRY=true
    depends_on:
      relational_db:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - onyx_internal

  # ── Web frontend ─────────────────────────────────────────────────────────
  web_server:
    image: ghcr.io/onyx-dot-app/onyx-web:${ONYX_VERSION}
    container_name: onyx_web
    environment:
      - INTERNAL_URL=http://api_server:8080
    depends_on:
      - api_server
    restart: unless-stopped
YAML

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    cat >> "$f" <<YAML
    networks:
      - onyx_internal
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.onyx.rule=Host(\`${ONYX_DOMAIN}\`)"
      - "traefik.http.routers.onyx.entrypoints=websecure"
      - "traefik.http.routers.onyx.tls.certresolver=le"
      - "traefik.http.services.onyx.loadbalancer.server.port=3000"
YAML
  else
    cat >> "$f" <<YAML
    networks:
      - onyx_internal
    ports:
      - "${ONYX_PORT}:3000"
YAML
  fi

  cat >> "$f" <<YAML

volumes:
  onyx_postgres:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${REPO_DIR}/services/onyx/postgres_data
  onyx_vespa:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${REPO_DIR}/services/onyx/vespa_data

networks:
  onyx_internal:
    driver: bridge
YAML

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    cat >> "$f" <<YAML
  proxy:
    external: true
YAML
  fi

  CREATED_FILES+=("$f")
}

create_compose_traefik() {
  if [ "$USE_TRAEFIK" -eq 0 ]; then
    return
  fi

  local f="${REPO_DIR}/services/traefik/docker-compose.yml"
  log "  Generuję services/traefik/docker-compose.yml"

  local dashboard_flag="false"
  [ "$TRAEFIK_DASHBOARD" -eq 1 ] && dashboard_flag="true" || true

  cat > "$f" <<YAML
networks:
  proxy:
    external: true
  socket:
    internal: true

services:
  socket-proxy:
    image: tecnativa/docker-socket-proxy
    container_name: socket-proxy
    environment:
      - CONTAINERS=1
      - EVENTS=1
      - PING=1
      - VERSION=1
      - NETWORKS=1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped
    networks:
      - socket

  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: traefik
    command:
      - --api.dashboard=${dashboard_flag}
      - --api.insecure=false
      - --providers.docker=true
      - --providers.docker.endpoint=tcp://socket-proxy:2375
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=proxy
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=${TRAEFIK_ACME_EMAIL}
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --log.level=INFO
      - --accesslog=true
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${REPO_DIR}/services/traefik/letsencrypt:/letsencrypt
    restart: unless-stopped
    depends_on:
      - socket-proxy
    networks:
      - proxy
      - socket
YAML

  if [ "$TRAEFIK_DASHBOARD" -eq 1 ]; then
    local escaped_auth="${TRAEFIK_BASIC_AUTH//\$/\$\$}"
    cat >> "$f" <<YAML
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`${TRAEFIK_DOMAIN}\`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=le"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.middlewares=traefik-auth"
      - "traefik.http.middlewares.traefik-auth.basicauth.users=${escaped_auth}"
YAML
  fi

  CREATED_FILES+=("$f")
}

create_compose_files() {
  log_section "Krok 4b: Generowanie docker-compose.yml"

  [ "$INSTALL_N8N" -eq 1 ]    && create_compose_n8n
  [ "$INSTALL_NOCODB" -eq 1 ] && create_compose_nocodb
  [ "$INSTALL_ONYX" -eq 1 ]   && create_compose_onyx
  [ "$USE_TRAEFIK" -eq 1 ]    && create_compose_traefik

  log "Pliki konfiguracyjne wygenerowane."
}

# ─── Docker network setup ─────────────────────────────────────────────────────
setup_proxy_network() {
  if [ "$USE_TRAEFIK" -eq 0 ]; then
    return
  fi

  require_sudo
  if ! docker network inspect proxy >/dev/null 2>&1; then
    log "Tworzę sieć Docker 'proxy'..."
    ${SUDO} docker network create proxy >> "$LOG_FILE" 2>&1
    CREATED_NETWORKS+=("proxy")
    log "  Sieć 'proxy' utworzona."
  else
    log "  Sieć 'proxy' już istnieje."
  fi
}

# ─── Start services ───────────────────────────────────────────────────────────
bring_up() {
  log_section "Krok 6: Uruchamianie usług"
  require_sudo

  # Traefik must start first (owns the proxy network)
  if [ "$USE_TRAEFIK" -eq 1 ]; then
    local traefik_dir="${REPO_DIR}/services/traefik"
    log "Uruchamiam Traefik..."
    (cd "$traefik_dir" && ${SUDO} docker compose pull >> "$LOG_FILE" 2>&1)
    (cd "$traefik_dir" && ${SUDO} docker compose up -d >> "$LOG_FILE" 2>&1)
    STARTED_SERVICES+=("traefik")
    log "  ✓ Traefik uruchomiony"
    sleep 2
  fi

  # Start application services
  local services=()
  [ "$INSTALL_N8N" -eq 1 ]    && services+=("n8n")
  [ "$INSTALL_NOCODB" -eq 1 ] && services+=("nocodb")
  [ "$INSTALL_ONYX" -eq 1 ]   && services+=("onyx")

  local svc
  for svc in "${services[@]}"; do
    local svc_dir="${REPO_DIR}/services/${svc}"
    if [ -f "${svc_dir}/docker-compose.yml" ]; then
      log "Uruchamiam ${svc}..."
      (cd "$svc_dir" && ${SUDO} docker compose pull >> "$LOG_FILE" 2>&1)
      (cd "$svc_dir" && ${SUDO} docker compose up -d >> "$LOG_FILE" 2>&1)
      STARTED_SERVICES+=("$svc")
      log "  ✓ ${svc} uruchomiony"
    fi
  done
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  log_section "Instalacja zakończona pomyślnie!"

  log "Status kontenerów:"
  log ""
  require_sudo
  ${SUDO} docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null \
    | tee -a "$LOG_FILE"
  log ""
  log "Adresy dostępowe:"

  if [ "$INSTALL_N8N" -eq 1 ]; then
    if [ "$USE_TRAEFIK" -eq 1 ]; then
      log "  n8n:    https://${N8N_DOMAIN}"
    else
      log "  n8n:    http://localhost:${N8N_PORT}"
    fi
  fi

  if [ "$INSTALL_NOCODB" -eq 1 ]; then
    if [ "$USE_TRAEFIK" -eq 1 ]; then
      log "  NocoDB: https://${NOCODB_DOMAIN}"
    else
      log "  NocoDB: http://localhost:${NOCODB_PORT}"
    fi
  fi

  if [ "$INSTALL_ONYX" -eq 1 ]; then
    if [ "$USE_TRAEFIK" -eq 1 ]; then
      log "  Onyx:   https://${ONYX_DOMAIN}"
    else
      log "  Onyx:   http://localhost:${ONYX_PORT}"
    fi
  fi

  if [ "$USE_TRAEFIK" -eq 1 ]; then
    if [ "$TRAEFIK_DASHBOARD" -eq 1 ]; then
      log "  Traefik dashboard: https://${TRAEFIK_DOMAIN}"
    fi
    log ""

    log "WAŻNE — Skonfiguruj rekordy DNS (A) wskazujące na IP tego serwera:"

    [ "$INSTALL_N8N" -eq 1 ]       && log "  ${N8N_DOMAIN} → <IP serwera>"    || true
    [ "$INSTALL_NOCODB" -eq 1 ]    && log "  ${NOCODB_DOMAIN} → <IP serwera>" || true
    [ "$INSTALL_ONYX" -eq 1 ]      && log "  ${ONYX_DOMAIN} → <IP serwera>"   || true
    [ "$TRAEFIK_DASHBOARD" -eq 1 ] && log "  ${TRAEFIK_DOMAIN} → <IP serwera>" || true
  fi

  log ""
  log "Log instalacji: ${LOG_FILE}"
  log ""
  log "Środowisko gotowe i uruchomione."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  # Initialize log
  {
    echo "# codeless_starter — instalacja $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# System: $(uname -srm)"
    echo ""
  } > "$LOG_FILE"

  log_section "Codeless Starter — Instalator"
  log "Log zapisywany w: ${LOG_FILE}"

  install_docker
  configure_domain
  select_services
  configure_versions
  configure_subdomains
  configure_n8n_extras
  configure_traefik_auth
  ensure_dirs
  generate_env
  create_compose_files
  setup_proxy_network
  bring_up
  print_summary
}

main "$@"
