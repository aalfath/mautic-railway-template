# Mautic on Railway

The start script behind the Railway template for [Mautic](https://github.com/mautic/mautic), the open-source marketing automation platform.

The template runs the **official image** `mautic/mautic:7.2.2-apache@sha256:83461b9ec7c109413281490180e1f96c379aa935bd92f80c68294f98487a9015` with Railway's MySQL (`mysql:8.4.13`, pinned by digest). Nothing is built from this repo; it's here so you can read what the start command does.

## Why one service instead of three

Upstream runs three containers from the same image (`DOCKER_MAUTIC_ROLE` = `mautic_web`, `mautic_cron`, `mautic_worker`) that share the config and media folders. Railway volumes can't be shared between services, so [`start.sh`](start.sh) runs all three roles in one container:

1. Puts `config/`, `var/logs/`, `docroot/media/files/` and `docroot/media/images/` on one volume at `/data` (symlinks).
2. Makes Apache listen on Railway's `PORT`.
3. On first boot, runs `mautic:install` with the Railway domain as the site URL and the admin login from `MAUTIC_ADMIN_EMAIL` and `MAUTIC_ADMIN_PASSWORD`. The web installer is never left open.
4. Runs database migrations on every start, then upstream's cron schedule (segments, campaigns, triggers) and upstream's supervisord queue workers (email, hit, failed), with the Doctrine queue in MySQL.
5. Starts Apache in the foreground.

Railway's start command carries the script inline as base64 (`make-start-command.sh` prints it), so the container needs no extra download at boot.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `MAUTIC_ADMIN_EMAIL` | (you enter it) | Admin email; sign in as `admin` |
| `MAUTIC_ADMIN_PASSWORD` | `${{secret(24)}}` | Admin password, used on first install only |
| `MAUTIC_DB_*` | references to `MySQL` | Host, port, database, user, password |
| `MAILER_DSN` | empty | Optional Symfony mailer DSN, e.g. `smtp://user:pass@smtp.example.com:587`. When set, it overrides the email settings in the UI |
| `MAILER_FROM_EMAIL`, `MAILER_FROM_NAME` | empty | Optional sender address and name |
| `MAUTIC_SITE_URL` | `https://$RAILWAY_PUBLIC_DOMAIN` | Optional; read only on first install. Change it later under Settings > Configuration |
| `MAUTIC_ADMIN_USERNAME` | `admin` | Optional; read only on first install |

Mautic can't send email until you set `MAILER_DSN` or configure a transport under Settings > Configuration > Email Settings.

## License

The script is MIT. Mautic is GPL-3.0.
