#!/usr/bin/env node
'use strict';

// Reference backend for the Plinth drive.
//
// A WebDAV server with one addition that matters: every item carries a STABLE,
// OPAQUE id, and can be addressed by it.
//
//   PROPFIND /dav/                      the root, Depth 0 or 1
//   PROPFIND /dav/.id/<id>              one item, Depth 0 or 1
//   GET      /dav/.id/<id>
//   PUT      /dav/.id/<parent>/<name>   create
//   PUT      /dav/.id/<id>              overwrite in place
//   PUT      /dav/<name>                create at the root
//   MKCOL    /dav/.id/<parent>/<name>   |  MKCOL /dav/<name>
//   DELETE   /dav/.id/<id>
//   MOVE     /dav/.id/<id>              Destination: <any of the create forms>
//
// The id is `<inode>-<birthtimeMs>`. It survives rename and reparent, because
// neither moves an inode. It changes if a file is deleted and recreated, which
// is correct — that is a different item. And it contains no filename, which is
// the whole point: see the note at the top of Extension/DriveItem.swift.
//
// 🔴 NOT PRODUCTION CODE. Auth accepts any non-empty credential, the id index is
// rebuilt by walking the tree on every request, and there is no locking. It
// exists so the extension has something correct to talk to.
//
// Node stdlib only. No dependencies.
//
//   node plinth-server.js [--root ./files] [--port 8080]

const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const args = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const ROOT = path.resolve(argOf('--root', path.join(__dirname, 'files')));
const PORT = parseInt(argOf('--port', '8080'), 10);
const PREFIX = '/dav';

fs.mkdirSync(ROOT, { recursive: true });

// --- identity ---------------------------------------------------------------

function idOf(stat) {
  // birthtimeMs is 0 on filesystems that do not record a birth time. The inode
  // alone is still stable for the lifetime of the file; the birth time only adds
  // resistance to inode reuse after a delete.
  return `${stat.ino}-${Math.floor(stat.birthtimeMs || 0)}`;
}

// Walk the tree and build id -> absolute path. Rebuilt per request: correct and
// slow, which is the right trade for a reference.
function index() {
  const map = new Map();
  const walk = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      let stat;
      try {
        stat = fs.lstatSync(full);
      } catch {
        continue;
      }
      if (stat.isSymbolicLink()) continue;
      map.set(idOf(stat), full);
      if (stat.isDirectory()) walk(full);
    }
  };
  const rootStat = fs.statSync(ROOT);
  map.set(idOf(rootStat), ROOT);
  walk(ROOT);
  return map;
}

// Resolve a request path to { target, parentDir, name }.
// `target` is null when the path names something that does not exist yet.
function resolve(pathname, map) {
  const rel = decodeURIComponent(pathname.slice(PREFIX.length));
  const parts = rel.split('/').filter(Boolean);

  if (parts.length === 0) return { target: ROOT };

  if (parts[0] === '.id') {
    const id = parts[1];
    const base = map.get(id);
    if (!base) return null;
    if (parts.length === 2) return { target: base };
    // .id/<parent>/<name> — a child that may or may not exist
    const name = parts.slice(2).join('/');
    if (!safeName(name)) return null;
    const full = path.join(base, name);
    if (!within(full)) return null;
    return { target: fs.existsSync(full) ? full : null, parentDir: base, name };
  }

  // A plain name at the root.
  const name = parts.join('/');
  if (!safeName(name)) return null;
  const full = path.join(ROOT, name);
  if (!within(full)) return null;
  return { target: fs.existsSync(full) ? full : null, parentDir: ROOT, name };
}

const safeName = (name) => !name.split('/').some((p) => p === '.' || p === '..');
const within = (p) => path.resolve(p) === ROOT || path.resolve(p).startsWith(ROOT + path.sep);

// --- PROPFIND ---------------------------------------------------------------

const xmlEscape = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
           .replace(/"/g, '&quot;');

const hrefFor = (full) => {
  const rel = path.relative(ROOT, full);
  const segments = rel === '' ? [] : rel.split(path.sep);
  return PREFIX + '/' + segments.map(encodeURIComponent).join('/');
};

function responseXML(full, stat, map) {
  const isDir = stat.isDirectory();
  const id = idOf(stat);
  // Empty for a direct child of the root: the client maps that to the system's
  // fixed root container rather than to a real directory.
  let parentID = '';
  if (full !== ROOT) {
    const parent = path.dirname(full);
    if (parent !== ROOT) parentID = idOf(fs.statSync(parent));
  }
  const etag = `${Math.floor(stat.mtimeMs)}-${isDir ? 0 : stat.size}`;

  const href = hrefFor(full);
  const shown = isDir && !href.endsWith('/') ? href + '/' : href;

  return [
    '  <D:response>',
    `    <D:href>${xmlEscape(shown)}</D:href>`,
    '    <D:propstat>',
    '      <D:prop>',
    `        <D:resourcetype>${isDir ? '<D:collection/>' : ''}</D:resourcetype>`,
    isDir ? '' : `        <D:getcontentlength>${stat.size}</D:getcontentlength>`,
    `        <D:getlastmodified>${new Date(stat.mtimeMs).toUTCString()}</D:getlastmodified>`,
    `        <D:getetag>"${etag}"</D:getetag>`,
    `        <D:fileid>${xmlEscape(id)}</D:fileid>`,
    `        <D:parentid>${xmlEscape(parentID)}</D:parentid>`,
    '      </D:prop>',
    '      <D:status>HTTP/1.1 200 OK</D:status>',
    '    </D:propstat>',
    '  </D:response>',
  ].filter(Boolean).join('\n');
}

function propfind(full, depth, map) {
  const stat = fs.statSync(full);
  // 🔑 The container itself comes FIRST. The client drops it by id, and for a
  // root listing it has no id to compare against, so it drops the first entry.
  const parts = [responseXML(full, stat, map)];
  if (depth === '1' && stat.isDirectory()) {
    for (const name of fs.readdirSync(full).sort()) {
      const child = path.join(full, name);
      let childStat;
      try {
        childStat = fs.lstatSync(child);
      } catch {
        continue;
      }
      if (childStat.isSymbolicLink()) continue;
      parts.push(responseXML(child, childStat, map));
    }
  }
  return `<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:">\n${parts.join('\n')}\n</D:multistatus>\n`;
}

// --- server -----------------------------------------------------------------

const send = (res, code, body, headers = {}) => {
  res.writeHead(code, { 'Content-Type': 'text/plain; charset=utf-8', ...headers });
  res.end(body ?? '');
};

const server = http.createServer((req, res) => {
  // Any non-empty credential is accepted. A real backend authenticates here.
  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Basic ')) {
    return send(res, 401, 'Authentication required', {
      'WWW-Authenticate': 'Basic realm="Plinth"',
    });
  }
  const [account, password] = Buffer.from(auth.slice(6), 'base64').toString().split(':');
  if (!account || !password) return send(res, 401, 'Authentication required');

  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!url.pathname.startsWith(PREFIX)) return send(res, 404, 'Not found');

  const map = index();
  const found = resolve(url.pathname, map);
  if (!found) return send(res, 404, 'Not found');
  const { target, parentDir, name } = found;

  const log = (note) => console.log(`${req.method} ${url.pathname} -> ${note}`);

  switch (req.method) {
    case 'PROPFIND': {
      if (!target) { log('404'); return send(res, 404, 'Not found'); }
      const depth = req.headers.depth === undefined ? '1' : String(req.headers.depth);
      log('207');
      return send(res, 207, propfind(target, depth, map), {
        'Content-Type': 'application/xml; charset=utf-8',
      });
    }

    case 'GET': {
      if (!target) { log('404'); return send(res, 404, 'Not found'); }
      const stat = fs.statSync(target);
      if (stat.isDirectory()) return send(res, 405, 'Is a collection');
      log(`200 ${stat.size}b`);
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': stat.size,
      });
      return fs.createReadStream(target).pipe(res);
    }

    case 'PUT': {
      const dest = target || (parentDir && name ? path.join(parentDir, name) : null);
      if (!dest) return send(res, 409, 'No parent');
      const exists = fs.existsSync(dest);
      if (exists && fs.statSync(dest).isDirectory()) {
        return send(res, 405, 'Is a collection');
      }

      // 🔴🔴 AN OVERWRITE MUST BE WRITTEN IN PLACE, NOT RENAMED INTO PLACE.
      //
      // The usual safe way to write a file is to stream into a temporary and
      // rename over the target, so a reader never sees a half-written file.
      // That is correct for durability and WRONG here: rename gives the path a
      // NEW inode, and this server derives item identity from the inode. Every
      // save would therefore mint a new id for what the user considers the same
      // document.
      //
      // What that costs on the client is not subtle. `modifyItem` uploads and
      // then re-reads by the id it started with, which would now 404. And if it
      // did resolve, returning a CHANGED identifier from modify is defined by
      // NSFileProviderReplicatedExtension.h as a MERGE, after which "the system
      // will keep one of the items and remove the other one from disk".
      //
      // Caught by testing it: a PUT over an existing file moved the id from
      // 687235-… to 687236-…, which is a different document as far as the
      // system is concerned.
      //
      // 🔑 The deeper lesson is that deriving identity from the inode couples
      // your identity scheme to your write strategy. A backend that stores an
      // explicit id — an xattr, a row in a database — can write however it likes
      // and is the better design. Inode-derived identity is used here because it
      // is simple enough to read in one sitting.
      const stream = exists
        ? fs.createWriteStream(dest, { flags: 'r+' })   // truncated below; keeps the inode
        : fs.createWriteStream(dest + '.plinth-partial');

      if (exists) fs.truncateSync(dest, 0);

      req.pipe(stream);
      stream.on('finish', () => {
        if (!exists) fs.renameSync(dest + '.plinth-partial', dest);
        log(exists ? '204 (in place)' : '201');
        send(res, exists ? 204 : 201, '');
      });
      stream.on('error', () => {
        if (!exists) { try { fs.unlinkSync(dest + '.plinth-partial'); } catch {} }
        send(res, 500, 'Write failed');
      });
      return;
    }

    case 'MKCOL': {
      if (target) return send(res, 405, 'Already exists');
      if (!parentDir || !name) return send(res, 409, 'No parent');
      try {
        fs.mkdirSync(path.join(parentDir, name));
        log('201');
        return send(res, 201, '');
      } catch {
        return send(res, 409, 'Could not create');
      }
    }

    case 'DELETE': {
      if (!target) { log('404'); return send(res, 404, 'Not found'); }
      if (target === ROOT) return send(res, 403, 'Refusing to delete the root');
      // 🔴 Recursive, as WebDAV requires. The extension refuses a non-empty
      // directory itself rather than relying on the server to be gentle —
      // see deleteItem in FileProviderExtension.swift.
      fs.rmSync(target, { recursive: true, force: true });
      log('204');
      return send(res, 204, '');
    }

    case 'MOVE': {
      if (!target) { log('404'); return send(res, 404, 'Not found'); }
      const raw = req.headers.destination;
      if (!raw) return send(res, 400, 'No Destination');
      let destPath;
      try {
        destPath = new URL(raw, `http://${req.headers.host}`).pathname;
      } catch {
        return send(res, 400, 'Bad Destination');
      }
      const destination = resolve(destPath, map);
      if (!destination) return send(res, 409, 'Bad Destination');
      const finalPath = destination.target
        || (destination.parentDir && destination.name
            ? path.join(destination.parentDir, destination.name)
            : null);
      if (!finalPath) return send(res, 409, 'Bad Destination');
      const overwrite = (req.headers.overwrite || 'T').toUpperCase() !== 'F';
      if (fs.existsSync(finalPath) && !overwrite) return send(res, 412, 'Exists');
      fs.renameSync(target, finalPath);
      log('204');
      return send(res, 204, '');
    }

    case 'OPTIONS':
      return send(res, 200, '', { DAV: '1', Allow: 'OPTIONS,GET,PUT,DELETE,PROPFIND,MKCOL,MOVE' });

    default:
      return send(res, 405, 'Method not allowed');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`plinth reference server: http://127.0.0.1:${PORT}${PREFIX}  root=${ROOT}`);
});
