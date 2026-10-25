#!/bin/bash
# ============================================================================
#  Установка системы заказов «Фермерофф» на чистый сервер Ubuntu 22.04 / 24.04.
#  Запуск (под root):   bash install.sh
#  Можно запускать повторно — уже сделанные шаги пропускаются.
#
#  Что ставится: PostgreSQL (база), Node.js 22 (сервер заказов), Caddy (HTTPS),
#  автообновление с GitHub раз в минуту и ночные резервные копии.
#  Docker не нужен.
# ============================================================================
set -euo pipefail

REPO_SSH="${REPO_SSH:-git@github.com:pavurs/fermeroff.git}"
REPO_KEYS_URL="https://github.com/pavurs/fermeroff/settings/keys/new"
APP=/opt/fermeroff
DATA=/var/lib/fermeroff
ENV=/etc/fermeroff.env
NODE_VER=v22.11.0
CADDY_VER=2.8.4

say()  { printf '\n\033[1;32m▶ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*"; exit 1; }
[ "$(id -u)" = 0 ] || die "Запустите от root: sudo bash install.sh"
. /etc/os-release
[ "${ID:-}" = ubuntu ] || warn "Скрипт проверен на Ubuntu, у вас ${PRETTY_NAME:-неизвестная система}"

# ---------- 1. Вопросы ----------
if [ -f "$ENV" ]; then
  say "Настройки уже есть ($ENV) — использую их"
  set -a; . "$ENV"; set +a
else
  say "Несколько вопросов"
  read -rp "Домен [fermeroff.pro]: " DOMAIN; DOMAIN=${DOMAIN:-fermeroff.pro}
  read -rp "Почта для уведомлений о сертификатах HTTPS: " ACME_EMAIL
  [ -n "$ACME_EMAIL" ] || die "Почта нужна для сертификатов Let's Encrypt"
  read -rsp "Ключ от прайса (SEED_KEY, его прислал Claude): " SEED_KEY; echo
  [ -n "$SEED_KEY" ] || warn "Без ключа каталог загрузится без цен — их можно будет внести в офисе"
fi

# ---------- 2. Пакеты ----------
say "Устанавливаю PostgreSQL, git и утилиты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql git curl ca-certificates xz-utils openssh-client openssl >/dev/null

# ---------- 3. Node.js ----------
need_node=1
if command -v /usr/local/bin/node >/dev/null && [ "$(/usr/local/bin/node -p 'process.versions.node.split(".")[0]')" -ge 20 ]; then need_node=0; fi
if [ $need_node = 1 ]; then
  say "Устанавливаю Node.js $NODE_VER"
  T=$(mktemp -d)
  for U in "https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-linux-x64.tar.xz" "https://npmmirror.com/mirrors/node/$NODE_VER/node-$NODE_VER-linux-x64.tar.xz"; do
    curl -fsSL --retry 3 -o "$T/node.tar.xz" "$U" && break || warn "Не скачалось: $U"
  done
  [ -s "$T/node.tar.xz" ] || die "Не удалось скачать Node.js"
  tar -xJf "$T/node.tar.xz" -C /usr/local --strip-components=1
  rm -rf "$T"
fi
/usr/local/bin/node -v

# ---------- 4. Caddy ----------
if ! /usr/local/bin/caddy version 2>/dev/null | grep -q "v$CADDY_VER"; then
  say "Устанавливаю Caddy $CADDY_VER"
  T=$(mktemp -d)
  curl -fsSL --retry 3 -o "$T/caddy.tgz" "https://github.com/caddyserver/caddy/releases/download/v$CADDY_VER/caddy_${CADDY_VER}_linux_amd64.tar.gz" || die "Не удалось скачать Caddy с GitHub"
  tar -xzf "$T/caddy.tgz" -C "$T" caddy && install -m 755 "$T/caddy" /usr/local/bin/caddy
  rm -rf "$T"
fi
id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy

# ---------- 5. Пользователь и доступ к GitHub ----------
id fermeroff >/dev/null 2>&1 || useradd --system --home /home/fermeroff --create-home --shell /bin/bash fermeroff
KEY=/home/fermeroff/.ssh/id_ed25519
if [ ! -f "$KEY" ]; then
  runuser -u fermeroff -- mkdir -p /home/fermeroff/.ssh
  runuser -u fermeroff -- ssh-keygen -q -t ed25519 -N "" -C "fermeroff-server" -f "$KEY"
fi
runuser -u fermeroff -- bash -c 'ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null; sort -u -o ~/.ssh/known_hosts ~/.ssh/known_hosts'
if ! runuser -u fermeroff -- git ls-remote "$REPO_SSH" >/dev/null 2>&1; then
  say "Нужно разрешить серверу читать репозиторий"
  echo "1) Откройте: $REPO_KEYS_URL"
  echo "2) Title: fermeroff-server, в поле Key вставьте строку ниже, галочку «Allow write access» НЕ ставьте"
  echo "3) Нажмите «Add key»"
  echo
  cat "$KEY.pub"
  echo
  until runuser -u fermeroff -- git ls-remote "$REPO_SSH" >/dev/null 2>&1; do
    read -rp "Когда добавите ключ — нажмите Enter… " _
  done
  echo "Доступ есть."
fi

# ---------- 6. Код ----------
if [ ! -d "$APP/.git" ]; then
  say "Скачиваю код в $APP"
  install -d -o fermeroff -g fermeroff "$APP"
  runuser -u fermeroff -- git clone -q "$REPO_SSH" "$APP"
else
  runuser -u fermeroff -- git -C "$APP" pull -q --ff-only || true
fi
chmod +x "$APP"/deploy/*.sh
install -d -o fermeroff -g fermeroff "$DATA" "$DATA/uploads"
chmod 755 "$DATA" "$DATA/uploads"

# ---------- 7. База данных ----------
say "Готовлю базу данных"
if [ -z "${POSTGRES_PASSWORD:-}" ]; then POSTGRES_PASSWORD=$(openssl rand -hex 18); fi
systemctl enable --now postgresql >/dev/null
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='fermeroff'" | grep -q 1; then
  runuser -u postgres -- psql -qc "CREATE ROLE fermeroff LOGIN PASSWORD '$POSTGRES_PASSWORD'"
fi
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='fermeroff'" | grep -q 1; then
  runuser -u postgres -- psql -qc "CREATE DATABASE fermeroff OWNER fermeroff"
fi

# ---------- 8. Настройки ----------
if [ ! -f "$ENV" ]; then
  umask 077
  cat > "$ENV" <<EOT
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=postgres://fermeroff:$POSTGRES_PASSWORD@127.0.0.1:5432/fermeroff
JWT_SECRET=$(openssl rand -hex 32)
SEED_KEY=$SEED_KEY
APP_TZ=Europe/Samara
CUTOFF_HOUR=16
EOT
  umask 022
fi
chown root:fermeroff "$ENV"; chmod 640 "$ENV"
# Caddy тоже читает этот файл (домен и почта)
usermod -aG fermeroff caddy

# ---------- 9. Сервер заказов ----------
say "Ставлю зависимости сервера"
cd "$APP/apps/api"
runuser -u fermeroff -- /usr/local/bin/npm ci --omit=dev --no-audit --no-fund >/dev/null \
  || runuser -u fermeroff -- /usr/local/bin/npm ci --omit=dev --no-audit --no-fund --registry=https://registry.npmmirror.com >/dev/null

say "Загружаю каталог и создаю ключи"
KEYS=/root/fermeroff-keys.txt
set -a; . "$ENV"; set +a
OUT=$(runuser -u fermeroff --preserve-environment -- env DATA_DIR="$APP/data/" UPLOAD_DIR="$DATA/uploads" /usr/local/bin/node src/seed.js)
echo "$OUT"
if grep -q -- '-....-....-' <<<"$OUT"; then { date; echo "$OUT"; echo; } >> "$KEYS"; chmod 600 "$KEYS"; fi

# ---------- 10. Службы ----------
say "Запускаю службы"
cp "$APP"/deploy/systemd/*.service "$APP"/deploy/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now fermeroff-api >/dev/null
systemctl enable --now fermeroff-caddy >/dev/null
systemctl enable --now fermeroff-update.timer fermeroff-backup.timer >/dev/null
sleep 3
systemctl is-active --quiet fermeroff-api || { journalctl -u fermeroff-api -n 30 --no-pager; die "Сервер заказов не запустился"; }
systemctl is-active --quiet fermeroff-caddy || { journalctl -u fermeroff-caddy -n 30 --no-pager; die "Caddy не запустился"; }
curl -fsS http://127.0.0.1:3000/api/health >/dev/null && echo "Сервер заказов отвечает."

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow 80/tcp >/dev/null; ufw allow 443 >/dev/null; fi

IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
say "Готово"
cat <<EOT
Приложения (заработают, когда домен будет указывать на этот сервер — $IP):
  Клиенты:   https://$DOMAIN
  Офис:      https://office.$DOMAIN
  Менеджер:  https://manager.$DOMAIN

В настройках домена нужны A-записи на $IP:  @   www   office   manager
Сертификаты HTTPS Caddy получит сам в течение пары минут после этого.

Ключи офиса и менеджера выведены выше и сохранены в $KEYS (только для root).
Новый ключ сотрудника:  bash $APP/deploy/keys.sh office "Имя"   (или manager "Имя"; список — keys.sh list)
Обновления с GitHub подтягиваются сами раз в минуту:  journalctl -u fermeroff-update -f
Резервные копии каждую ночь в /var/backups/fermeroff
EOT
