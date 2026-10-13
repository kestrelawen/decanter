# Decanter 0.3.1

Fix for in-app updates on a private repository. **Use this build rather than
0.3.0.**

## Install

Download `decanter-0.3.1.apk` below and open it on the device.

## Fixed: the update download 404'd on a private repository

0.3.0 found new releases correctly and then failed to download them. The cause was
not the token or the redirect handling — it was the URL.

GitHub publishes two ways to reach a release asset:

- `browser_download_url` on `github.com` — what the release page links to. It
  authenticates with a **cookie**, so it does not accept a bearer token. For a
  private repository's asset it answers **404**, exactly as it would if the asset
  did not exist.
- `GET /repos/{owner}/{repo}/releases/assets/{id}` on `api.github.com`, with
  `Accept: application/octet-stream` — accepts a token and answers 302 to signed
  object storage.

0.3.0 always used the first, so it could never download an asset from a private
repository: the check would say "0.3.1 is available" and the download would fail
with a bare 404 that gave no hint the URL was the problem.

Now a configured token switches the download to the API asset endpoint, and the
`id` of each asset is parsed from the release response to build that URL. Without a
token the browser URL is still used, since it is not subject to the API's hourly
rate limit and works for public repositories.

Verified against the real API, not just mocked: the downloader fetched the
published v0.3.0 asset — 50,846,969 bytes, sha256
`783165e5ccb589ec7376a9c427dc78feba5e5d92b05166b31b4270d376c92abc` — matching that
published file byte for byte. That run also exercised the 302 to
`release-assets.githubusercontent.com` and the cross-host `Authorization`
stripping.

## From 0.3.0

Nothing else changed. The updater's version comparison, redirect handling and
truncation guards are as described in the 0.3.0 notes.

## Not verified

The final step — Android's installer actually replacing the app — has not been run
on a device. It is exercised the first time a release newer than the installed
build exists, which needs this release to exist first.

## Still missing

No character library or menu, no card importing, no persistence between launches.
The API key is stored unencrypted in shared preferences.
