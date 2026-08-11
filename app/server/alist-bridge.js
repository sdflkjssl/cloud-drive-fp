#!/usr/bin/env node
'use strict';

// AList bridge for the Plinth drive — WebDAV-only (Basic auth), no AList login.
//
// Implements the /dav/.id/<id> contract for the extension. Item ids are
// managed by THIS bridge (stable, opaque, persisted): enumeration assigns ids,
// rename/move updates the mapping, so an id survives rename (as Plinth
// requires). All backend operations go through AList WebDAV with Basic auth —
// no tokens, no device sessions.
//
//   node alist-bridge.js [--port 8081]

const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const args = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const PORT = parseInt(argOf('--port', '8081'), 10);
const PREFIX = '/dav';
const ALIST = argOf('--alist', 'http://127.0.0.1:5244');
// AList storage mount path inside /dav — change to any AList-mounted storage
// (e.g. Baidu/Quark/Ali), or serve the whole /dav root with ''.
const STORAGE_ROOT = argOf('--root', '/quark');
const PROJECT = process.env.FP_DATA_DIR || path.join(__dirname, '..', '..', '..', 'quark-sync');
const IDMAP = path.join(PROJECT, 'fp-idmap.json');

const AUTH = (() => {
  try {
    const pw = fs.readFileSync(path.join(PROJECT, 'alist-admin-pass.txt'), 'utf8').trim();
    return 'Basic ' + Buffer.from('admin:' + pw).toString('base64');
  } catch { return ''; }
})();

// --- id mapping (persisted) --------------------------------------------------

let idToPath = new Map();   // id -> relPath ("" = root)
let pathToId = new Map();   // relPath -> id
let nextId = 1;

function loadMap() {
  try {
    const raw = JSON.parse(fs.readFileSync(IDMAP, 'utf8'));
    idToPath = new Map(Object.entries(raw.idToPath || {}));
    pathToId = new Map(Object.entries(raw.pathToId || {}));
    nextId = raw.nextId || 1;
  } catch {
    idToPath = new Map(); pathToId = new Map(); nextId = 1;
  }
}
function saveMap() {
  try {
    fs.writeFileSync(IDMAP, JSON.stringify(
      { idToPath: Object.fromEntries(idToPath), pathToId: Object.fromEntries(pathToId), nextId }, null, 0));
  } catch (e) { console.error('idmap save failed:', e.message); }
}
loadMap();

function getIdForPath(relPath) {
  if (pathToId.has(relPath)) return pathToId.get(relPath);
  const id = 'f' + (nextId++).toString(36);
  idToPath.set(id, relPath);
  pathToId.set(relPath, id);
  return id;
}
function forgetId(id) {
  const p = idToPath.get(id);
  if (p !== undefined) pathToId.delete(p);
  idToPath.delete(id);
}

// --- WebDAV backend helpers ---------------------------------------------------

const relToURL = (rel) => ALIST + '/dav' + STORAGE_ROOT
  + (rel ? '/' + rel.split('/').map(encodeURIComponent).join('/') : '');

// Forward a WebDAV request to AList, streaming the response back.
function forward(req, res, method, relPath, extraHeaders = {}) {
  const u = new URL(relToURL(relPath));
  const headers = {
    Authorization: AUTH,
    ...extraHeaders,
  };
  const up = http.request(u, { method, headers }, (down) => {
    res.writeHead(down.statusCode || 200, {
      'Content-Type': down.headers['content-type'] || 'application/octet-stream',
      'Content-Length': down.headers['content-length'],
      'Accept-Ranges': 'bytes',
    });
    down.pipe(res);
  });
  up.on('error', () => { try { send(res, 502, 'Backend error'); } catch {} });
  if (req) req.pipe(up);
  else up.end();
}

// PROPFIND: fetch from AList, rewrite hrefs to path form and inject fileid/parentid.
function propfindAndRewrite(relPath, depth, cb) {
  const u = new URL(relToURL(relPath));
  const up = http.request(u, {
    method: 'PROPFIND',
    headers: { Authorization: AUTH, Depth: depth || '1' },
  }, (down) => {
    const chunks = [];
    down.on('data', (c) => chunks.push(c));
    down.on('end', () => {
      const xml = Buffer.concat(chunks).toString('utf8');
      if (down.statusCode !== 207) return cb(null, down.statusCode || 500, xml);
      cb(rewritePropfind(xml, relPath, depth), 207, null);
    });
  });
  up.on('error', () => cb(null, 502, null));
  up.end();
}

const xmlEscape = (s) => String(s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// Rewrite AList's PROPFIND response: keep href (path form), set fileid/parentid.
function rewritePropfind(xml, dirRel, depth) {
  const responses = xml.match(/<D:response>[\s\S]*?<\/D:response>/g) || [];
  const parts = [];
  for (const r of responses) {
    const href = (r.match(/<D:href>([^<]*)<\/D:href>/) || [])[1] || '';
    // decode path, strip /dav/quark/ prefix
    let rel = '';
    try {
      const full = decodeURIComponent(href).replace(/\/$/, '');
      const prefix = '/dav' + STORAGE_ROOT;
      rel = full.startsWith(prefix) ? full.slice(prefix.length + (full[prefix.length] === '/' ? 1 : 0)) : '';
    } catch { continue; }
    const id = rel === '' ? '' : getIdForPath(rel);
    // parent id: for a directory listing (depth 1) children's parent is the
    // requested dir; for a single stat (depth 0) the item's parent is its parent dir.
    let parentID;
    if (depth === '0') {
      const parentRel = rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : '';
      parentID = parentRel === '' ? '' : getIdForPath(parentRel);
    } else {
      parentID = dirRel === '' ? '' : getIdForPath(dirRel);
    }
    // rebuild response with our fileid/parentid
    const isDir = /<D:collection[^>]*\/>/.test(r) || href.endsWith('/');
    const size = (r.match(/<D:getcontentlength>(\d+)<\/D:getcontentlength>/) || [])[1] || '';
    const modified = (r.match(/<D:getlastmodified>([^<]*)<\/D:getlastmodified>/) || [])[1] || '';
    const etag = (r.match(/<D:getetag>([^<]*)<\/D:getetag>/) || [])[1] || '';
    parts.push([
      '  <D:response>',
      `    <D:href>${xmlEscape(href)}</D:href>`,
      '    <D:propstat>',
      '      <D:prop>',
      `        <D:resourcetype>${isDir ? '<D:collection/>' : ''}</D:resourcetype>`,
      isDir ? '' : `        <D:getcontentlength>${size}</D:getcontentlength>`,
      `        <D:getlastmodified>${modified}</D:getlastmodified>`,
      `        <D:getetag>${etag}</D:getetag>`,
      `        <D:fileid>${xmlEscape(id)}</D:fileid>`,
      `        <D:parentid>${xmlEscape(parentID)}</D:parentid>`,
      '      </D:prop>',
      '      <D:status>HTTP/1.1 200 OK</D:status>',
      '    </D:propstat>',
      '  </D:response>',
    ].join('\n'));
  }
  saveMap();
  return '<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:">\n' + parts.join('\n') + '\n</D:multistatus>\n';
}

// --- resolve request path -> { target: relPath|null, parentDir, name } --------

function resolve(pathname) {
  const rel = decodeURIComponent(pathname.slice(PREFIX.length));
  const parts = rel.split('/').filter(Boolean);
  if (parts.length === 0) return { target: '', parentDir: null, name: null };
  if (parts[0] === '.id') {
    const id = parts[1];
    const baseRel = idToPath.get(id);
    if (baseRel === undefined) return null;
    if (parts.length === 2) return { target: baseRel, parentDir: null, name: null };
    const name = parts.slice(2).join('/');
    if (!safeName(name)) return null;
    const targetRel = baseRel ? baseRel + '/' + name : name;
    return { target: targetRel, parentDir: baseRel, name };
  }
  const name = parts.join('/');
  if (!safeName(name)) return null;
  return { target: name, parentDir: '', name };
}
const safeName = (n) => !n.split('/').some((p) => p === '.' || p === '..');

// --- server -------------------------------------------------------------------

const send = (res, code, body, headers = {}) => {
  res.writeHead(code, { 'Content-Type': 'text/plain; charset=utf-8', ...headers });
  res.end(body ?? '');
};

const server = http.createServer((req, res) => {
  const auth = req.headers.authorization || '';
  if (!auth.startsWith('Basic ')) {
    return send(res, 401, 'Authentication required', { 'WWW-Authenticate': 'Basic realm="Plinth"' });
  }
  const [account, password] = Buffer.from(auth.slice(6), 'base64').toString().split(':');
  if (!account || !password) return send(res, 401, 'Authentication required');

  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!url.pathname.startsWith(PREFIX)) return send(res, 404, 'Not found');

  const found = resolve(url.pathname);
  if (!found) return send(res, 404, 'Not found');
  const { target, parentDir, name } = found;
  console.log(req.method, url.pathname, '->', JSON.stringify(target));

  switch (req.method) {
    case 'PROPFIND': {
      if (target === null) return send(res, 404, 'Not found');
      const depth = req.headers.depth === undefined ? '1' : String(req.headers.depth);
      propfindAndRewrite(target, depth, (xml, status, raw) => {
        if (!xml) return send(res, status, raw || 'Not found', { 'Content-Type': 'text/plain' });
        send(res, 207, xml, { 'Content-Type': 'application/xml; charset=utf-8' });
      });
      return;
    }

    case 'GET': {
      if (target === null) return send(res, 404, 'Not found');
      return forward(null, res, 'GET', target, req.headers.range ? { Range: req.headers.range } : {});
    }

    case 'PUT': {
      if (target === null && !(parentDir !== null && name)) return send(res, 409, 'No parent');
      const destRel = target || (parentDir ? (parentDir ? parentDir + (parentDir ? '/' : '') + name : name) : null);
      if (!destRel) return send(res, 409, 'No parent');
      return forward(req, res, 'PUT', destRel);
    }

    case 'MKCOL': {
      // resolve returns the target path regardless of existence; let AList decide
      if (target === null) return send(res, 404, 'Not found');
      if (!name) return send(res, 409, 'No parent');
      return forward(null, res, 'MKCOL', target);
    }

    case 'DELETE': {
      if (target === null) return send(res, 404, 'Not found');
      if (target === '') return send(res, 403, 'Refusing to delete the root');
      const u = new URL(relToURL(target));
      const up = http.request(u, { method: 'DELETE', headers: { Authorization: AUTH } }, (down) => {
        // drop ids for the subtree (best-effort: clear mapping entries under this rel)
        for (const [id, p] of [...idToPath]) {
          if (p === target || p.startsWith(target + '/')) forgetId(id);
        }
        saveMap();
        send(res, down.statusCode || 204, '');
      });
      up.on('error', () => send(res, 502, 'Backend error'));
      up.end();
      return;
    }

    case 'MOVE': {
      if (target === null) return send(res, 404, 'Not found');
      const raw = req.headers.destination;
      if (!raw) return send(res, 400, 'No Destination');
      const destPath = new URL(raw, `http://${req.headers.host}`).pathname;
      const destination = resolve(destPath);
      if (!destination) return send(res, 409, 'Bad Destination');
      const finalRel = destination.target
        || (destination.parentDir !== null ? (destination.parentDir ? destination.parentDir + '/' + destination.name : destination.name) : null);
      if (finalRel === null || finalRel === undefined) return send(res, 409, 'Bad Destination');

      const u = new URL(relToURL(target));
      const headers = {
        Authorization: AUTH,
        Destination: relToURL(finalRel),
        Overwrite: req.headers.overwrite || 'T',
      };
      const up = http.request(u, { method: 'MOVE', headers }, (down) => {
        if (down.statusCode && down.statusCode < 300) {
          // update mapping: every id under target moves to finalRel + suffix
          const moves = [];
          for (const [id, p] of [...idToPath]) {
            if (p === target) moves.push([id, finalRel]);
            else if (p.startsWith(target + '/')) moves.push([id, finalRel + p.slice(target.length)]);
          }
          for (const [id, p] of moves) {
            const oldP = idToPath.get(id);
            if (oldP !== undefined) pathToId.delete(oldP);
            idToPath.set(id, p);
            pathToId.set(p, id);
          }
          saveMap();
        }
        send(res, down.statusCode || 204, '');
      });
      up.on('error', () => send(res, 502, 'Backend error'));
      up.end();
      return;
    }

    case 'OPTIONS':
      return send(res, 200, '', { DAV: '1', Allow: 'OPTIONS,GET,PUT,DELETE,PROPFIND,MKCOL,MOVE' });

    default:
      return send(res, 405, 'Method not allowed');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`alist bridge (WebDAV, no login): http://127.0.0.1:${PORT}${PREFIX}`);
});
