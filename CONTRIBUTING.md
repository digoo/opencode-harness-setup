# Contributing

This repository documents one working harness configuration. If you change it, change the
verification script too.

## Rules

- Never commit credentials, keys, tokens, or personal hostnames.
- Provider URLs appear as placeholders or as the generic upstream used at authoring time.
- Every pitfall documented here was actually hit. If you cannot reproduce it, do not
  document it — delete it instead.
- Keep the guide runnable. A command in the README must work as written.

## After changing anything

```sh
sh scripts/verify.sh
```

It must print `all checks passed`.

## Updating the version numbers

The README quotes real versions. Refresh them from the live install before editing:

```sh
opencode --version
rtk --version
rtk-proxy --version
headroom --version
npm list -g --depth=0
opencode mcp list
opencode plugin list
```
