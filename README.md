# notify

A dependency-free self notifier. One Go file, standard library only.
No accounts, no API keys, no hosted service that can shut down or
change its terms. You run it, you own the data.

Monitoring scripts POST alerts to it. Your phone polls an RSS feed,
or a second box polls a health endpoint and tells you when this one
stops answering.

## How it works

- `POST /alert` with a token, a title, a message, and a topic.
- `GET /alerts` shows recent alerts as a plain page.
- `GET /feed` serves alerts as RSS, optionally filtered by topic.
- `GET /healthz` answers `ok`, for a heartbeat watcher.
- Alerts append to `alerts.jsonl` (mode 0600) and load back on start.

Tokens come in two kinds:

- The admin token (`NOTIFY_TOKEN`) reads and writes every topic.
- Friend tokens live in `tokens.txt`, one per line: a token plus the
  topics it may read and write. A friend token with no topic filter
  sees only its own topics.

There is no endpoint that creates tokens. You mint them by hand with
`add_token`, so nobody can mint tokens to flood your server. The
tokens file is re-read on every request, so adding a friend needs no
restart.

## Quickstart (Docker, recommended)

The container runs only notify.go: scratch image, no shell, user
10001, read-only filesystem, all capabilities dropped. If it gets
compromised, the attacker gets a dead-end container, not your host.
Caddy on the host terminates TLS and proxies a subpath to it.

```sh
git clone https://github.com/DaUmega/notifier.git
cd notifier
sudo ./manage.sh build
sudo NOTIFY_TOKEN=$(openssl rand -hex 16) ./manage.sh start
```

Save that admin token. It is set at start time; changing it means
stop, then start again with the new one.

Put it behind Caddy (or any reverse proxy) on a subpath:

```
# inside your site block
handle_path /notify/* {
    reverse_proxy 127.0.0.1:47124
}
```

The proxy strips the `/notify` prefix, so the app itself only ever
sees `/alert`, `/feed`, and so on.

Check it:

```sh
curl https://your-domain.com/notify/healthz
curl -X POST https://your-domain.com/notify/alert \
  -H 'X-Token: <admin-token>' \
  -d '{"title":"test","message":"hello","topic":"self"}'
```

## Managing it

manage.sh wraps the container. It needs docker and root (for the
data dir ownership).

- `build` builds the notify image.
- `start` builds if needed, then starts the container. Requires
  `NOTIFY_TOKEN` in the environment.
- `stop` stops the container.
- `restart` restarts the container.
- `status` shows the container and the config.
- `logs [-f]` shows container logs (flags pass through).
- `add-token [topic]` mints a friend token (topic defaults to main).
- `shell` opens a shell with the data dir mounted, for hand-editing
  `tokens.txt` (comments, names). The app re-reads the file on every
  request, so no restart is needed after editing.
- `help` shows usage, examples, and RSS reader info.
- `purge` is a dry run and changes nothing.
- `purge --yes` removes the container and image, keeps the data dir.
- `purge --yes --data` also deletes the data dir (alerts and friend
  tokens). That is the only destructive command.

The shell runs in a throwaway alpine container, because the notify
image itself has no shell by design.

## Friends

```sh
sudo ./manage.sh add-token andy
```

That prints a token for topic `main`, shared by every friend on
`main`. For isolation, give each friend their own topic:

```sh
sudo ./manage.sh add-token andy-watch
```

Then share only that topic's feed:
`/feed?token=<token>&topic=andy-watch`. A friend posting with no
topic defaults to their first listed topic, and cross-topic posts
and reads are rejected.

To annotate the file by hand (names, comments), use
`sudo ./manage.sh shell` and edit `tokens.txt` there; no restart is
needed, the app re-reads the file on every request.

## Reading the feed on your phone

No signup, no account: paste this link into any RSS reader,
replacing the domain, token, and topic:

```
https://your-domain.com/notify/feed?token=<friend-token>&topic=<topic>
```

Two readers that need no account at all: Feeder on Android
(free, open source, on F-Droid) and NetNewsWire on iPhone
(free, open source, on the App Store). Set the reader to
refresh on an interval you like (15 minutes is a good default);
it polls, so an alert shows up at most one refresh interval
late. Use a friend token in the link, never the admin token:
anyone with the link can read that topic's feed, and a friend
token only exposes its own topics.

## Bare metal (no Docker)

```sh
NOTIFY_TOKEN=<secret> go run notify.go
```

Same endpoints, same files, default port 47124. Add a systemd unit
or a process manager if you want it persistent; the Docker path
already restarts on boot and on crash.

## Configuration

- `NOTIFY_TOKEN` (required): admin token, full access to all topics.
- `NOTIFY_DATA_DIR` (default `/var/lib/notify`): host dir holding
  `alerts.jsonl` and `tokens.txt`.
- `NOTIFY_PORT` (default `47124`): host port, published on
  127.0.0.1 only.

The app itself takes flags too: `-addr` (default `:47124`), `-data`
(default `alerts.jsonl`), `-tokens` (default `tokens.txt`). In the
container these point at the bind-mounted data dir, so you normally
leave them alone.

## Security and limits, stated plainly

- Polling, not push. A phone checking the feed every 15 minutes sees
  an alert up to 15 minutes late. If you need seconds, this is not
  the tool.
- A notifier on a box that dies cannot report its own death. Watch
  `/healthz` from a second box if that matters.
- The container protects the host, not the notifier's own data. A
  break-in still exposes the alerts and friend tokens in the data
  dir, because the service legitimately holds them.
- The admin token is visible to host root through `docker inspect`,
  which is fine: host root already owns the box.
- Alerts accumulate in memory and on disk; there is no rotation yet.
  For a personal notifier this stays small, but it is worth knowing.
