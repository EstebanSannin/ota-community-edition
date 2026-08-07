# Tooling credentials: using torizoncore-builder with your own instance

`torizoncore-builder` (TCB) and `garage-sign` expect a **credentials.zip** — the bundle Torizon
Cloud hands out — to know where your server is and how to authenticate to it. This instance can
issue an equivalent zip, so the standard Torizon tooling works against your own OTA server with no
patched clients.

The main thing you need it for is **canonicalizing** a docker-compose file. An offline update
(Lockbox) can only contain a compose file whose images are pinned by digest, and TCB is what turns
`image: nginx` into `image: nginx@sha256:…`.

> **Two different OAuth2s.** The browser login (GitHub sign-in, see [console-auth.md](console-auth.md))
> and the tooling credential are separate auth planes. `garage-sign` only speaks
> `client_credentials` — a machine-to-machine grant that GitHub and Google cannot serve — so this
> instance runs its own small token endpoint for tooling. Humans log in with GitHub; tools use a
> client id + secret.

## 1. Get the zip

In the console, open **Packages** and use **Tooling credentials → Download credentials.zip**. The
browser session is what authorises it, so the download goes through your normal login.

From a shell on the server (useful when scripting, and it bypasses the browser login):

```bash
cd /opt/ota-community-edition
sudo docker compose exec lockbox \
  python3 -c "import urllib.request as u; print(u.urlopen(u.Request('http://localhost:9920/api/credentials', method='POST')).read().decode('latin1'), end='')" \
  > credentials.zip
```

The zip contains:

| File | What it's for |
|---|---|
| `treehub.json` | the `oauth2` block: token endpoint, client id, client secret |
| `tufrepo.url` | base URL of your TUF repo (`https://<host>/tuf`) |
| `root.json` | the current root role, so the client can verify the repo |
| `targets.pub` / `targets.sec` | the targets keypair — this is what lets tooling *sign* new targets |

**The secret is shown once.** Minting a new credential replaces the old one; `DELETE
/api/lockbox/credentials` revokes without issuing a replacement. Treat the zip like a password —
`targets.sec` can sign packages your whole fleet will trust.

## 2. Object storage is required to push

`platform push` uploads a target **out of band**: it asks the server for a pre-signed URL and PUTs
the bytes straight to the object store. The reposerver's local-disk backend refuses out-of-band
uploads outright:

```
http/500  "out of band storage of target is not supported for local storage"
```

So pushing needs the S3 overlay ([compose.s3.yaml](../compose.s3.yaml)), which runs a MinIO
alongside the stack:

```bash
grep -q '^MINIO_ROOT_PASSWORD=' /opt/ota-community-edition/.env || \
  echo "MINIO_ROOT_PASSWORD=$(openssl rand -hex 16)" | sudo tee -a /opt/ota-community-edition/.env >/dev/null

cd /opt/ota-community-edition
sudo docker compose -f compose.release.yaml -f compose.public.yaml -f compose.oauth2.yaml \
  -f compose.observability.yaml -f compose.s3.yaml --env-file .env up -d
```

Uploading a package **through the console** works with either backend — only external tooling needs
this.

Two things worth knowing about how it's wired:

- **Devices are unaffected.** With a self-hosted object store, target downloads are streamed back
  through the reposerver rather than redirecting the caller to the store. Devices keep talking only
  to the OTA gateway, so they never need to reach MinIO or trust its certificate.
- **Uploads go through the front proxy.** A pre-signed URL is only valid for the exact host it was
  signed for, so Caddy routes the bucket path straight through to MinIO, unmodified and outside the
  console login. MinIO checks the signature itself — an unsigned request gets a `403`.

**Switching storage does not move existing targets.** Both backends use the same key layout, so
migrate once:

```bash
docker run --rm --network ota-community-edition_default \
  -v ota-community-edition_objects:/o \
  -e MC_HOST_local="http://otaadmin:$MINIO_ROOT_PASSWORD@minio:9000" \
  minio/mc mirror /o/tuf-objects local/ota-targets
```

## 3. Canonicalize and push a compose file

TCB runs as a container. It needs the credentials, your compose file, and an anonymous volume at
`/deploy` (it writes there internally and fails without it):

```bash
docker run --rm -it -v /deploy \
  -v "$PWD":/workdir -w /workdir \
  torizon/torizoncore-builder:3 \
  platform push --credentials credentials.zip \
    --canonicalize-only docker-compose.yml
```

That writes `docker-compose.lock.yml` with every image pinned by digest. Drop
`--canonicalize-only` to also upload it as a package:

```bash
docker run --rm -it -v /deploy -v "$PWD":/workdir -w /workdir \
  torizon/torizoncore-builder:3 \
  platform push --credentials credentials.zip \
    --package-name my-app --package-version 1 docker-compose.lock.yml
```

The package then shows up in the console's Packages list like any other, and can go into a Lockbox.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `401` from the token endpoint | wrong client secret, or the credential was revoked/replaced |
| `404 missing 'fileSize'` | a proxy dropped the query string on the way to `/tuf` |
| `500 out of band storage … not supported` | S3 overlay not enabled (see step 2) |
| `403 SignatureDoesNotMatch` on upload | the bucket route is rewriting the path, compressing, or not preserving `Host` |
| TCB exits complaining about `/deploy` | the `-v /deploy` anonymous volume is missing |
