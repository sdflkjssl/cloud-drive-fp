# The backend contract

The extension will talk to any backend that satisfies this. `plinth-server.js` is
the smallest thing that does, in Node stdlib with no dependencies.

## What the extension needs

**Every item has a stable, opaque id, and can be addressed by it.**

That is the whole contract. Plain WebDAV is path-addressed, which fails as an
identity scheme for two independent reasons — see findings #1 and #3 in the root
README. So two custom properties are added to `PROPFIND` responses:

| Property | Meaning |
|---|---|
| `<D:fileid>` | This item's stable id. Must survive rename, reparent and overwrite. |
| `<D:parentid>` | The containing folder's id. **Empty** for a direct child of the root. |

An empty `parentid` maps to `NSFileProviderItemIdentifier.rootContainer`, which
is a fixed system constant rather than anything your server names.

## Verbs

```
PROPFIND /dav/                     the root, Depth 0 or 1
PROPFIND /dav/.id/<id>             one item, Depth 0 or 1
GET      /dav/.id/<id>
PUT      /dav/.id/<parent>/<name>  create
PUT      /dav/<name>               create at the root
PUT      /dav/.id/<id>             overwrite, in place
MKCOL    /dav/.id/<parent>/<name>  |  MKCOL /dav/<name>
DELETE   /dav/.id/<id>
MOVE     /dav/.id/<id>             Destination: any of the create forms
```

A `Depth: 1` response returns the container **first**, then its children; the
client drops that first entry.

The `.id/<parent>/<name>` form exists because a file being created has no id
yet — it is addressed as a name inside an identified parent, which the server
resolves in one step.

## Status codes the client acts on

The client maps these onto File Provider errors, and the mapping decides what the
*system* does next, not just what the user reads. Getting one wrong can delete a
file — see finding #2.

| Code | Meaning to the client |
|---|---|
| 404 on `PROPFIND` | The item is genuinely gone. The only status that means this. |
| 401 / 403 on a read | Not authenticated |
| 403 on a write | A policy refusal — shown to the user, not retried |
| 405 / 412 | Filename collision |
| 507 | Out of quota |
| anything else | Server unreachable; retried with backoff |

## This implementation

The id is `<inode>-<birthtimeMs>`. Inodes survive rename and reparent; the birth
time guards against inode reuse, which **is not hypothetical** — one was reused
within milliseconds during testing.

🔴 An overwrite is written **in place**, not renamed into place, because a rename
would allocate a new inode and change the item's identity on every save. This is
finding #8, and it is the reason to prefer an explicitly stored id over a derived
one in anything real.

🔴 Not production code. Any non-empty credential is accepted, the id index is
rebuilt by walking the tree on every request, and there is no locking.

## Checking it

```bash
node plinth-server.js --port 8080 &
./verify.sh 8080
```

11 assertions, including the negative case: an id must *change* on
delete-and-recreate. A property that cannot fail is not being tested.
