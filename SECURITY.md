# Security policy

## Supported versions

Only the latest version on `main` receives fixes.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Use GitHub's private
[**Report a vulnerability**](https://github.com/umairleo1/thermac/security/advisories/new)
form instead. You'll get a reply within a few days.

## Scope

thermac runs without root, makes no network connections, and stores data only in
`~/Library/Application Support/thermac/`. Relevant reports include anything that lets
another process or user abuse the recorder, the installer (`install.sh`), or the app's
login items.
