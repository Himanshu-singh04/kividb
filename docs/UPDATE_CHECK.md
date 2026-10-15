# The startup update check

When KiviDB starts, it makes one HTTPS request to kividb.io. The reply says
whether a newer release is out, and may carry a short announcement. If there
is something to show, the server prints it once, above the startup banner.

This page is for two audiences: operators, who need to know what is sent and
how to turn it off, and whoever runs the endpoint on kividb.io, who needs to
know what to send back.

## For operators

**What is sent.** One `GET` request, over HTTPS, to
`https://kividb.io/api/release-check`, with four query parameters:

| Parameter | Example | Meaning |
|---|---|---|
| `version` | `1.1.0` | The running version |
| `os` | `linux` | `linux`, `macos` or `windows` |
| `arch` | `aarch64` | `x86_64` or `aarch64` |
| `build` | `full` | The variant: `default`, `lua`, `tls` or `full` |

Nothing else is sent: no host name, IP address, configuration, key or
dataset information, and no identifier. The `User-Agent` is
`kividb/<version>`. kividb.io sees the source IP address of the request, as
any web server would.

**When.** Once per server start, before the banner is printed, so that
what it finds appears above it. Startup waits for the reply for at
most 1.5 seconds; a slower reply is dropped, never printed later among the
log lines. It never touches a client connection. A failure is logged at
debug level only (`--loglevel debug`), and otherwise ignored.

**What is shown.** If the reply names a release newer than the running one,
a boxed notice with the download address. If the reply carries an
announcement, its text and an optional ASCII-art header. Before anything is
printed:

- control characters are removed, including terminal escape sequences, so
  the reply cannot move the cursor, change colours or rewrite the screen;
- bidirectional-text override characters are removed;
- each line is cut to 120 characters, text to 5 lines and art to 15.

**Turning it off.** Any one of these turns it off:

- `update-check no` in the config file;
- `--update-check no` on the command line;
- `KIVIDB_NO_UPDATE_CHECK=1` in the environment.

It is also never made by a debug build, or when the `CI` environment
variable is set.

`update-check-url` (config file) or `--update-check-url` points the check
somewhere else, for example a mirror inside a closed network. Only `https://`
URLs are accepted.

## For the kividb.io endpoint

`GET /api/release-check?version=…&os=…&arch=…&build=…`

Reply `200` with a JSON object. Every field is optional:

```json
{
  "latest":  "1.1.0",
  "url":     "https://kividb.io/downloads",
  "message": "KiviDB Cloud is live: managed clusters in three clicks.\nhttps://kividb.io/cloud",
  "art":     "  _  __ _       _ ____  ____\n | |/ /(_)_   _(_)  _ \\| __ )\n ..."
}
```

| Field | Shown when | Notes |
|---|---|---|
| `latest` | It is newer than the running version | First line only. Compared as `major.minor.patch`. A release is newer than its own release candidates (`1.0.6` > `1.0.6-rc1`), and `rc2` is newer than `rc1` |
| `url` | Together with `latest` | Where to download. If it is absent, the notice says `https://kividb.io/downloads` |
| `message` | Always, if present | Plain text; `\n` separates lines. At most 5 lines of 120 characters |
| `art` | Always, if present | Plain text, printed above the box. At most 15 lines of 120 characters |

A reply that is not `200`, is not JSON, or is larger than 64 KB is ignored,
as is any field of the wrong type. Redirects are not followed. To show
nothing, return `{}`.

The query parameters let the reply depend on what is running. For example:

- name the latest release candidate as `latest` only for builds that are
  release candidates themselves;
- point `url` at the right download for the `os`, `arch` and `build`;
- leave out a message for versions that predate a feature it mentions.

### Keep the reply small, safe and rare

Every server that starts will show this to whoever reads its log: operators
during an incident, and log pipelines that keep it for years. Keep
announcements short and relevant to people running KiviDB, and change them
rarely.

Anything that can change this reply can put text in front of every operator
who starts a server. Guard the endpoint as you would the release pipeline.
