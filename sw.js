// Service worker do app SAC Victos.
// Páginas e arquivos do site: busca na rede primeiro (para sempre pegar a versão nova)
// e usa a cópia guardada quando a internet falha. Chamadas ao Supabase nunca passam por aqui.
const CACHE = 'sac-victos-v1';
const SUPABASE_JS = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js';
const BASICOS = [
  './', 'index.html', 'estilo.css', 'comum.js', 'config.js', 'manifest.webmanifest',
  'img/victos-logo.png', 'img/victos-logo-escuro.png', 'img/unisuper-logo.png',
  'img/favicon.png', 'img/app-192.png', 'img/app-512.png', 'img/apple-touch-icon.png'
];

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await cache.addAll(BASICOS);
    try { await cache.add(SUPABASE_JS); } catch (err) { /* sem CDN agora: tenta de novo no próximo uso */ }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    for (const nome of await caches.keys()) if (nome !== CACHE) await caches.delete(nome);
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Biblioteca do Supabase: versão fixa, então pode vir direto da cópia guardada.
  if (req.url === SUPABASE_JS) {
    e.respondWith(caches.match(req).then((c) => c || fetch(req).then((r) => {
      if (r.ok) { const copia = r.clone(); caches.open(CACHE).then((cache) => cache.put(req, copia)); }
      return r;
    })));
    return;
  }

  if (url.origin !== self.location.origin) return;

  e.respondWith((async () => {
    try {
      const r = await fetch(req);
      if (r.ok && r.type === 'basic') { const copia = r.clone(); caches.open(CACHE).then((cache) => cache.put(req, copia)); }
      return r;
    } catch (err) {
      const guardado = await caches.match(req, { ignoreSearch: req.mode === 'navigate' });
      if (guardado) return guardado;
      if (req.mode === 'navigate') return (await caches.match('index.html')) || Response.error();
      return Response.error();
    }
  })());
});
