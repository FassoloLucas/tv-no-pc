// Service worker do controle: guarda a pagina para ela abrir mesmo com o PC desligado
// (ai so aparece "Sem conexao com o PC" em vez da tela de erro do Chrome).
// Sempre tenta a rede primeiro, entao mudancas na pagina chegam na hora.
const CACHE = 'controle-v1';
const ARQUIVOS = ['/', '/manifest.webmanifest', '/icone-192.png', '/icone-512.png'];

self.addEventListener('install', e => {
  // Se o cache falhar, o app continua funcionando (so perde a tela de "sem conexao")
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ARQUIVOS)).catch(() => {}).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(nomes => Promise.all(nomes.filter(n => n !== CACHE).map(n => caches.delete(n))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // Comandos para a TV nunca vem do cache
  if (e.request.method !== 'GET' || url.pathname.startsWith('/api/')) return;
  e.respondWith(
    fetch(e.request)
      .then(resposta => {
        const copia = resposta.clone();
        caches.open(CACHE).then(c => c.put(e.request, copia)).catch(() => {});
        return resposta;
      })
      .catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match('/')))
  );
});
