# codeless_starter

## Opis projektu

**codeless_starter** to automatyczny instalator środowiska no-code/low-code opartego na Dockerze. Umożliwia jednolinijkową lub interaktywną instalację ekosystemu narzędzi automatyzacji i zarządzania danymi wraz z reverse proxy i automatycznym SSL przez Let's Encrypt.

Projekt przeznaczony jest dla agencji i deweloperów wdrażających narzędzia no-code dla klientów — umożliwia szybkie przygotowanie środowiska produkcyjnego na serwerze Linux lub macOS.

---

## Architektura systemowa

```
Internet
    │
    ▼
┌──────────────────────────────────────┐
│  Traefik (reverse proxy)             │
│  Port 80 (HTTP → HTTPS redirect)     │
│  Port 443 (HTTPS + Let's Encrypt)    │
│  Dashboard: traefik.DOMENA           │
└──────────┬───────────────────────────┘
           │ Sieć Docker: proxy (external)
     ┌─────┼─────────────────────┐
     ▼     ▼                     ▼
┌─────────┐ ┌──────────┐ ┌─────────────────────────────┐
│  n8n    │ │  NocoDB  │ │  Onyx                       │
│ :5678   │ │ :8080    │ │  web(:3000) api(:8080)       │
│         │ │          │ │  postgres vespa redis        │
└─────────┘ └──────────┘ └─────────────────────────────┘
     │             │                │
     ▼             ▼                ▼
  n8n/data    nocodb/data    onyx/{postgres,vespa}_data
  (volume)    (volume)       (volumes)
```

**Tryb lokalny (bez domeny):** usługi dostępne bezpośrednio przez porty HTTP, bez Traefik.

---

## Komponenty i technologie

### Usługi aplikacyjne

| Usługa    | Obraz Docker                              | Opis                              |
|-----------|-------------------------------------------|-----------------------------------|
| n8n       | `n8nio/n8n`                               | Automatyzacja przepływów pracy    |
| NocoDB    | `nocodb/nocodb`                           | Interfejs webowy do baz danych    |
| Onyx      | `ghcr.io/onyx-dot-app/onyx-backend/web`  | AI knowledge base (RAG)           |

### Infrastruktura

| Komponent   | Obraz                      | Opis                                  |
|-------------|----------------------------|---------------------------------------|
| Traefik     | `traefik:v3.3`             | Reverse proxy, SSL/TLS, routing       |
| PostgreSQL  | `postgres:15.2-alpine`     | Baza relacyjna dla Onyx               |
| Redis       | `redis:7.4-alpine`         | Cache/kolejka dla Onyx                |
| Vespa       | `vespaengine/vespa:8.526`  | Wyszukiwarka wektorowa dla Onyx       |

### Technologie i narzędzia

- **Bash** — skrypt instalacyjny (POSIX-compatible + bash arrays)
- **Docker + Docker Compose v2** — konteneryzacja usług
- **Let's Encrypt (ACME HTTP-01)** — automatyczne certyfikaty SSL
- **Traefik labels** — konfiguracja routingu przez metadane kontenerów

---

## Wymagania systemowe

### Minimalne

| Zasób  | Minimum           | Zalecane (z Onyx) |
|--------|-------------------|-------------------|
| CPU    | 2 vCPU            | 4 vCPU            |
| RAM    | 2 GB              | 8 GB              |
| Dysk   | 20 GB             | 50 GB             |
| OS     | Ubuntu 20.04+ / Debian 11+ / RHEL 8+ / macOS 12+ |

### Oprogramowanie (instalowane automatycznie na Linux)

- Docker CE + docker-compose-plugin v2
- `curl`, `ca-certificates`, `gnupg`, `lsb-release`
- `htpasswd` lub `openssl` (dla hasha hasła Traefik)

### Wymagania sieciowe (tryb produkcyjny)

- Publiczny adres IP
- Otwarte porty: 80/TCP, 443/TCP
- Skonfigurowane rekordy DNS (A) wskazujące na serwer dla każdej subdomeny
- E-mail do rejestracji Let's Encrypt

---

## Instrukcje uruchomienia

### Szybka instalacja (curl | bash)

```bash
curl -fsSL https://raw.githubusercontent.com/patrykcodeless/codeless_starter/main/install.sh | bash
```

### Instalacja lokalna (zalecana)

```bash
git clone https://github.com/patrykcodeless/codeless_starter.git
cd codeless_starter
chmod +x install.sh
./install.sh
```

### Prywatne repozytorium (GitHub Token)

```bash
GITHUB_TOKEN=ghp_xxx \
curl -H "Authorization: token $GITHUB_TOKEN" \
     -H "Accept: application/vnd.github.v3.raw" \
     -fsSL https://api.github.com/repos/patrykcodeless/codeless_starter/contents/install.sh | bash
```

---

## Konfiguracja

### Przepływ interaktywny

Skrypt pyta w tej kolejności:

1. **Domena** — czy masz domenę klienta? (Y/N)
   - Y → podaj domenę, Traefik konfigurowany automatycznie
   - N → tryb lokalny, brak SSL

2. **Usługi** — wybór każdej usługi niezależnie (Y/N):
   - n8n
   - NocoDB
   - Onyx.app

3. **Wersje** — dla każdej wybranej usługi: najnowsza (Y) lub konkretna (N → podaj wersję)

4. **Konfiguracja n8n** (jeśli wybrane):
   - Port (tryb lokalny)
   - Opcjonalne SMTP (host, port, user, pass, sender, TLS)

5. **Konfiguracja Traefik** (jeśli tryb domenowy):
   - E-mail do Let's Encrypt
   - Użytkownik + hasło do dashboardu

### Plik .env

Generowany automatycznie w `REPO_DIR/.env`. Zawiera wszystkie zmienne środowiskowe usług.

```bash
# Przykładowy .env (tryb domenowy)
BASE_DOMAIN=example.com

N8N_IMAGE=n8nio/n8n
N8N_VERSION=latest
N8N_DOMAIN=n8n.example.com
N8N_PORT=5678
N8N_PROTOCOL=https
N8N_WEBHOOK_URL=https://n8n.example.com/

NOCODB_IMAGE=nocodb/nocodb
NOCODB_VERSION=latest
NOCODB_DOMAIN=nocodb.example.com

ONYX_VERSION=latest
ONYX_DOMAIN=onyx.example.com

TRAEFIK_IMAGE=traefik:v3.3
TRAEFIK_DOMAIN=traefik.example.com
TRAEFIK_ACME_EMAIL=admin@example.com
TRAEFIK_BASIC_AUTH=admin:$apr1$hash...
```

---

## Struktura katalogów po instalacji

```
codeless_starter/
├── install.sh              # Skrypt instalacyjny
├── install.log             # Log z ostatniej instalacji
├── .env                    # Wygenerowana konfiguracja
├── .env.example            # Szablon konfiguracji
├── Claude.md               # Ta dokumentacja
├── cursor/
│   └── rules/
│       └── installer.mdc  # Specyfikacja dla Cursor AI
└── services/
    ├── traefik/
    │   ├── docker-compose.yml
    │   ├── data/
    │   └── letsencrypt/
    │       └── acme.json   # Certyfikaty LE (chmod 600)
    ├── n8n/
    │   ├── docker-compose.yml
    │   └── data/           # Dane n8n (workflows, credentials)
    ├── nocodb/
    │   ├── docker-compose.yml
    │   └── data/           # Dane NocoDB
    └── onyx/
        ├── docker-compose.yml
        ├── data/
        ├── postgres_data/  # Dane PostgreSQL
        └── vespa_data/     # Dane Vespa (indeks wektorowy)
```

---

## Zarządzanie usługami

```bash
# Sprawdzenie statusu
docker ps

# Logi konkretnej usługi
cd services/n8n && docker compose logs -f

# Restart
cd services/n8n && docker compose restart

# Zatrzymanie
cd services/n8n && docker compose down

# Aktualizacja obrazu
cd services/n8n && docker compose pull && docker compose up -d
```

---

## Bezpieczeństwo

- Certyfikaty SSL generowane automatycznie przez Let's Encrypt (HTTP-01 challenge)
- Dashboard Traefik chroniony Basic Auth (hash htpasswd/openssl)
- Plik `acme.json` ma uprawnienia 600
- Docker socket montowany tylko do odczytu (`/var/run/docker.sock:ro`)
- HTTPS redirect (80 → 443) włączony automatycznie
- HSTS headers dla n8n
- Onyx: losowo generowane `SECRET_KEY` i hasło PostgreSQL

---

## Obsługa błędów i rollback

Skrypt zawiera mechanizm rollback (trap ERR):
- Zatrzymuje uruchomione kontenery
- Usuwa utworzone sieci Docker
- Usuwa wygenerowane pliki konfiguracyjne
- Usuwa puste katalogi

Log pełnej instalacji dostępny w `install.log`.
