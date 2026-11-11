#!/bin/bash
# Mautic on Railway: one container runs the web app, cron jobs and queue workers.
# Railway volumes can't be shared between services, so everything uses one volume at /data.
set -e
D=/data
H=/var/www/html
log() { echo "[railway-start] $*"; }

# 1. Persistent folders on the volume, linked into the places Mautic expects.
mkdir -p $D/config $D/logs $D/media/files $D/media/images $D/cron
rm -rf $D/lost+found
for p in config:config logs:var/logs media/files:docroot/media/files media/images:docroot/media/images; do
  src=$D/${p%%:*}; dst=$H/${p#*:}
  if mountpoint -q "$dst"; then log "$dst is already a mounted volume; leaving it in place."; continue; fi
  if [ ! -L "$dst" ]; then cp -an "$dst"/. "$src"/ 2>/dev/null || true; rm -rf "$dst"; ln -s "$src" "$dst"; fi
done
chown -R www-data:www-data $D

# 2. Apache: only the prefork MPM (mod_php needs it; Railway's image unpacking can leave mpm_event enabled
#    too, which stops Apache with "More than one MPM loaded"), listening on Railway's PORT.
rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
[ -e /etc/apache2/mods-enabled/mpm_prefork.load ] || a2enmod -q mpm_prefork
export PORT="${PORT:-8080}"
sed -ri "s/^Listen [0-9]+$/Listen ${PORT}/" /etc/apache2/ports.conf
sed -ri "s/<VirtualHost \*:[0-9]+>/<VirtualHost *:${PORT}>/" /etc/apache2/sites-available/000-default.conf

# 3. Settings. Plain MAUTIC_* variables override local.php; set them only when needed.
export DOCKER_MAUTIC_ROLE=mautic_web
export MAUTIC_DB_PORT="${MAUTIC_DB_PORT:-3306}"
export MAUTIC_MESSENGER_DSN_EMAIL="${MAUTIC_MESSENGER_DSN_EMAIL:-doctrine://default}"
export MAUTIC_MESSENGER_DSN_HIT="${MAUTIC_MESSENGER_DSN_HIT:-doctrine://default}"
export MAUTIC_TRUSTED_PROXIES="${MAUTIC_TRUSTED_PROXIES:-[\"0.0.0.0/0\",\"::/0\"]}"
[ -n "$MAILER_DSN" ] && export MAUTIC_MAILER_DSN="$MAILER_DSN"
[ -n "$MAILER_FROM_EMAIL" ] && export MAUTIC_MAILER_FROM_EMAIL="$MAILER_FROM_EMAIL"
[ -n "$MAILER_FROM_NAME" ] && export MAUTIC_MAILER_FROM_NAME="$MAILER_FROM_NAME"
SITE_URL="${MAUTIC_SITE_URL:-https://${RAILWAY_PUBLIC_DOMAIN:-localhost}}"

installed() { php -r "include('$H/config/local.php'); exit(!empty(\$parameters['db_driver']) && !empty(\$parameters['site_url']) ? 0 : 1);" 2>/dev/null; }

# 4. Upstream checks (volumes, env, database, local.php).
export DEBUG="${DEBUG:-false}" MAUTIC_VOLUME_CONFIG=$H/config MAUTIC_CONSOLE=$H/bin/console \
  MAUTIC_WWW_USER=www-data MAUTIC_WWW_GROUP=www-data
source /startup/logger.sh
export REQUIRED_MAUTIC_VARIABLES="MAUTIC_DB_HOST MAUTIC_DB_USER MAUTIC_DB_PASSWORD DOCKER_MAUTIC_ROLE"
/startup/check_environment_variables.sh
/startup/check_database_connection.sh
/startup/check_local_php_exists.sh

# 5. First boot: install with the Railway domain as site URL and the generated admin password.
if ! installed; then
  if [ -z "$MAUTIC_ADMIN_EMAIL" ] || [ -z "$MAUTIC_ADMIN_PASSWORD" ]; then
    log "MAUTIC_ADMIN_EMAIL and MAUTIC_ADMIN_PASSWORD must be set for the first install."; exit 1
  fi
  log "Installing Mautic at $SITE_URL ..."
  su -s /bin/bash www-data -c "php $H/bin/console mautic:install --force --no-interaction \
    --admin_username=\"\${MAUTIC_ADMIN_USERNAME:-admin}\" --admin_email=\"\$MAUTIC_ADMIN_EMAIL\" \
    --admin_password=\"\$MAUTIC_ADMIN_PASSWORD\" \"$SITE_URL\"" </dev/null
  installed || { log "Install did not finish; see the output above."; exit 1; }
fi

# 6. Database migrations (needed after an image upgrade), before anything else touches the database.
su -s /bin/bash www-data -c "php $H/bin/console doctrine:migrations:migrate -n --allow-no-migration" </dev/null

# 7. Cron jobs (upstream schedule) and queue workers (upstream supervisord config) in the background.
[ -f $D/cron/mautic ] || cp /templates/mautic_cron $D/cron/mautic
crontab -u www-data $D/cron/mautic
rm -f /tmp/stdout; mkfifo /tmp/stdout; chmod 777 /tmp/stdout
declare -p | grep -E 'PHP_INI_VALUE_|MAUTIC' > /tmp/cron.env; chgrp www-data /tmp/cron.env; chmod 640 /tmp/cron.env
( tail -f /tmp/stdout & cron -f ) &
supervisord -c /etc/supervisor/conf.d/supervisord.conf &

# 8. Apache in the foreground.
exec apache2-foreground
