# Third-Party Notices

## plinth (MIT)

The macOS FileProvider extension (`app/Extension`, `app/App`) is a modified
fork of [plinth](https://github.com/ytomasch/plinth) by Amur Labs LLC,
licensed under the MIT License. See `app/LICENSE`.

Notable upstream documentation and findings (FileProvider framework traps)
are retained in the source comments and the original repository.

## AList (AGPL-3.0)

This project **does not link, include, or derive from AList**. AList is a
runtime dependency (a local server) that this project talks to over its
HTTP/WebDAV API, like any WebDAV client. AList remains AGPL-3.0 and must be
deployed per its own license.

## rclone (MIT)

`scripts/quark.sh` optionally uses rclone (MIT) for extra local downloads.

## Node.js (MIT)

The bridge (`app/server/alist-bridge.js`) runs on Node.js (MIT).

## Windows CFAPI reference (for future Windows frontend)

- [PrimalZed/CloudSync](https://github.com/PrimalZed/CloudSync)
- [pure01fx/cfapi](https://github.com/pure01fx/cfapi)
