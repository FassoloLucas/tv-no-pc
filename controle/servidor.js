// Servidor do controle remoto: entrega o webapp para o celular e repassa
// os botoes para o LDPlayer pelo adb.
//   node controle\servidor.js            -> porta 8765
//   set PORTA=9000 && node controle\...  -> outra porta
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const dgram = require('dgram');
const { spawn, execFile } = require('child_process');

const PORTA = Number(process.env.PORTA) || 8765;
const PROJETO = path.join(__dirname, '..');
const PUBLICO = path.join(__dirname, 'public');
const ADB = path.join(process.env.LOCALAPPDATA, 'Android', 'Sdk', 'platform-tools', 'adb.exe');
const LDCONSOLE = 'C:\\LDPlayer\\LDPlayer9\\ldconsole.exe';
const SERIAL = 'emulator-5554'; // adb da instancia 0 do LDPlayer

// Botao do controle -> codigo de tecla do Linux (mapa em /system/usr/keylayout/input.kl do LDPlayer)
const TECLAS = {
  cima: 103, baixo: 108, esquerda: 105, direita: 106,
  ok: 28, // ENTER: confirma nos menus, mas o player do YouCine ignora (veja apertarOk())
  voltar: 158, home: 172, menu: 139,
  volmais: 115, volmenos: 114, mudo: 113,
  play: 164, // play/pause de midia (o YouCine ignora; veja pausar())
};
// O OK de controle de TV. O teclado virtual do LDPlayer nao tem essa tecla (o kernel descarta),
// entao ela vai pelo injetor de teclas (TeclasAndroid)
const KEYCODE_DPAD_CENTER = 23;
const DEX_LOCAL = path.join(__dirname, 'teclas', 'teclas.dex');
const DEX_ANDROID = '/data/local/tmp/teclas.dex';

// Eventos do Linux (linux/input-event-codes.h)
const EV_SYN = 0, EV_KEY = 1, EV_REL = 2;
const REL_X = 0, REL_Y = 1, REL_WHEEL = 8, BTN_LEFT = 272;

// Um struct input_event de 64 bits (16 bytes de hora, que o kernel ignora, + tipo,
// codigo e valor) escrito como \0ooo, que o "print" do shell do Android transforma em bytes
function evento(tipo, codigo, valor) {
  const b = Buffer.alloc(24);
  b.writeUInt16LE(tipo, 16);
  b.writeUInt16LE(codigo, 18);
  b.writeInt32LE(valor, 20);
  return [...b].map(x => '\\0' + x.toString(8).padStart(3, '0')).join('');
}
const SYN = evento(EV_SYN, 0, 0);

// --- adb ----------------------------------------------------------------------
// Uma sessao "adb shell" fica aberta: abrir uma por tecla custaria ~1 s cada.
// Ela deixa abertos o teclado virtual do LDPlayer (fd 3) e o mouse (fd 4), e cada tecla
// e um "print" (comando interno do shell) com os eventos prontos: leva menos de 1 ms no
// Android, contra ~24 ms de cada "sendevent". Nao precisa de root: o SELinux do LDPlayer
// e permissivo e o shell esta no grupo input.
class ShellAdb {
  constructor() {
    this.proc = null;
    this.aparelhos = null; // { teclado, mouse }: /dev/input/eventN do LDPlayer
    this.fila = Promise.resolve();
    this.pendente = null;
    this.contador = 0;
  }

  // Os comandos rodam um de cada vez, na ordem em que chegaram
  executar(comando, timeoutMs = 5000) {
    const vez = this.fila.then(() => this.#executar(comando, timeoutMs));
    this.fila = vez.catch(() => {});
    return vez;
  }

  async tecla(codigo) {
    await this.#escrever(3, evento(EV_KEY, codigo, 1) + SYN + evento(EV_KEY, codigo, 0) + SYN);
  }

  async mouse(eventos) {
    if (!(await this.#abrirAparelhos()).mouse) throw new Error('O LDPlayer nao tem mouse virtual.');
    await this.#escrever(4, eventos);
  }

  fechar() {
    if (this.proc) this.proc.kill();
    this.proc = null;
    this.aparelhos = null;
  }

  async #escrever(fd, eventos) {
    await this.#abrirAparelhos();
    await this.executar(`print -nu${fd} "${eventos}"`);
  }

  async #abrirAparelhos() {
    if (this.proc && this.aparelhos) return this.aparelhos;
    // O LDPlayer cria um teclado chamado "input" e um mouse chamado "mouse"
    // (hoje sao o event2 e o event4, mas pode mudar)
    const saida = await this.executar('for f in /sys/class/input/event*/device/name; do echo "$f $(cat $f)"; done');
    const achar = nome => {
      const linha = saida.split('\n').find(l => l.trim().endsWith(' ' + nome));
      return linha && '/dev/input/' + linha.match(/(event\d+)/)[1];
    };
    const teclado = achar('input'), mouse = achar('mouse');
    if (!teclado) throw new Error('Nao achei o teclado virtual do LDPlayer.');
    // Abrir o aparelho custa ~16 ms, entao ele fica aberto no shell
    await this.executar(`exec 3>${teclado}` + (mouse ? ` 4>${mouse}` : ''));
    this.aparelhos = { teclado, mouse };
    return this.aparelhos;
  }

  #abrir() {
    const proc = spawn(ADB, ['-s', SERIAL, 'shell'], { windowsHide: true });
    let saida = '', erro = '';
    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', d => {
      saida += d;
      const p = this.pendente;
      if (p && saida.includes(p.marca)) {
        const resposta = saida.slice(0, saida.indexOf(p.marca));
        saida = '';
        this.pendente = null;
        p.resolver(resposta);
      }
    });
    proc.stderr.on('data', d => { erro += d; });
    proc.on('exit', () => {
      if (this.proc === proc) { this.proc = null; this.aparelhos = null; }
      const p = this.pendente;
      this.pendente = null;
      if (p) p.rejeitar(new TvDesligada(erro.trim()));
    });
    proc.on('error', e => { erro += e.message; });
    proc.stdin.on('error', () => {}); // escrever num shell que acabou de fechar nao pode derrubar o servidor
    this.proc = proc;
  }

  #executar(comando, timeoutMs) {
    if (!this.proc) this.#abrir();
    return new Promise((resolver, rejeitar) => {
      const marca = `__fim${++this.contador}__`;
      const timer = setTimeout(() => {
        this.pendente = null;
        this.fechar(); // shell travado: o proximo comando abre outro
        rejeitar(new Error('O adb nao respondeu.'));
      }, timeoutMs);
      this.pendente = {
        marca,
        resolver: r => { clearTimeout(timer); resolver(r); },
        rejeitar: e => { clearTimeout(timer); rejeitar(e); },
      };
      this.proc.stdin.write(`${comando}; echo ${marca}\n`);
    });
  }
}

class TvDesligada extends Error {
  constructor(detalhe) {
    super('A TV esta desligada.');
    this.detalhe = detalhe;
  }
}

// Injetor de teclas: o teclas.dex (controle/teclas) roda no Android e aperta qualquer
// KEYCODE pelo InputManager, como o "input keyevent". Ele fica aberto, entao so a 1a tecla
// espera o Java ligar (~0,8 s); por isso ele ja e ligado quando o celular abre o controle.
class TeclasAndroid {
  constructor() {
    this.proc = null;
    this.iniciando = null;
    this.esperando = []; // quem espera a resposta, na ordem das teclas
  }

  aquecer() {
    this.#iniciar().catch(() => {});
  }

  async tecla(keycode) {
    await this.#iniciar();
    const proc = this.proc;
    if (!proc) throw new Error('O injetor de teclas fechou.');
    return new Promise((resolver, rejeitar) => {
      const timer = setTimeout(() => {
        this.fechar();
        rejeitar(new Error('O Android nao respondeu a tecla.'));
      }, 5000);
      this.esperando.push({
        resolver: () => { clearTimeout(timer); resolver(); },
        rejeitar: e => { clearTimeout(timer); rejeitar(e); },
      });
      proc.stdin.write(`${keycode}\n`);
    });
  }

  fechar() {
    if (this.proc) this.proc.kill();
    this.proc = null;
    this.iniciando = null;
  }

  #iniciar() {
    if (!this.iniciando) {
      this.iniciando = this.#abrir();
      this.iniciando.catch(() => { this.iniciando = null; });
    }
    return this.iniciando;
  }

  async #abrir() {
    // Copia sempre (sao 3 KB): assim o Android fica com a versao atual
    try {
      await rodar(ADB, ['-s', SERIAL, 'push', DEX_LOCAL, DEX_ANDROID], 15000);
    } catch (e) {
      throw new TvDesligada(e.message);
    }
    const proc = spawn(ADB, ['-s', SERIAL, 'shell', `CLASSPATH=${DEX_ANDROID} exec app_process / Teclas`], { windowsHide: true });
    this.proc = proc;
    let resto = '', erro = '';
    proc.stdin.on('error', () => {});
    proc.stderr.on('data', d => { erro += d; });
    proc.on('error', e => { erro += e.message; });
    return new Promise((resolver, rejeitar) => {
      const timer = setTimeout(() => { this.fechar(); rejeitar(new Error('O injetor de teclas nao ligou.')); }, 10000);
      proc.stdout.setEncoding('utf8');
      proc.stdout.on('data', d => {
        resto += d;
        let i;
        while ((i = resto.indexOf('\n')) >= 0) {
          const linha = resto.slice(0, i).trim();
          resto = resto.slice(i + 1);
          if (linha === 'pronto') { clearTimeout(timer); resolver(); }
          else if (linha === 'ok') this.esperando.shift()?.resolver();
          else if (linha.startsWith('erro')) this.esperando.shift()?.rejeitar(new Error(linha.slice(5)));
        }
      });
      proc.on('exit', () => {
        clearTimeout(timer);
        if (this.proc === proc) { this.proc = null; this.iniciando = null; }
        const e = new Error(`O injetor de teclas fechou${erro.trim() ? `: ${erro.trim()}` : '.'}`);
        for (const p of this.esperando.splice(0)) p.rejeitar(e);
        rejeitar(e);
      });
    });
  }
}

const shell = new ShellAdb();
const teclasAndroid = new TeclasAndroid();

// --- Acoes ----------------------------------------------------------------------
function rodar(programa, args, timeoutMs = 30000) {
  return new Promise((resolver, rejeitar) => {
    execFile(programa, args, { windowsHide: true, timeout: timeoutMs }, (erro, stdout, stderr) => {
      if (erro) rejeitar(new Error((stderr || stdout || erro.message).trim()));
      else resolver(stdout.trim());
    });
  });
}

async function tvLigada() {
  return (await rodar(LDCONSOLE, ['isrunning', '--index', '0'])) === 'running';
}

// Liga o LDPlayer (se precisar) e abre o YouCine em tela cheia.
// Se pedirem de novo enquanto liga, aproveita a mesma vez.
let ligando = null;
function ligarTv() {
  if (!ligando) {
    const script = path.join(PROJETO, 'ldplayer', 'iniciar.ps1');
    ligando = rodar('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script], 240000)
      .finally(() => { ligando = null; });
  }
  return ligando;
}

async function desligarTv() {
  shell.fechar();
  teclasAndroid.fechar();
  await rodar(LDCONSOLE, ['quit', '--index', '0']);
}

// O OK do controle: DPAD_CENTER, como num controle de TV (o player do YouCine so pausa com
// ele). Se o injetor falhar, o ENTER do teclado virtual ainda confirma nos menus.
async function apertarOk() {
  try {
    await teclasAndroid.tecla(KEYCODE_DPAD_CENTER);
  } catch (e) {
    if (e instanceof TvDesligada) throw e;
    console.log(`${hora()} injetor de teclas falhou (${e.message}); usando ENTER`);
    await shell.tecla(TECLAS.ok);
  }
}

async function digitar(texto) {
  // O "input text" do Android nao aceita acentos nem espacos: tira os acentos e troca espaco por %s
  const limpo = texto.normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^\x20-\x7e]/g, '');
  if (!limpo) return;
  const arg = limpo.replace(/ /g, '%s').replace(/'/g, `'\\''`);
  await shell.executar(`input text '${arg}'`, 15000);
}

// --- Mouse ------------------------------------------------------------------------
// O LDPlayer tem um mouse virtual: mexer nele faz aparecer a setinha do Android
// (ela some sozinha depois de uns segundos parada ou quando se aperta uma tecla)
async function mexerMouse({ dx, dy, roda, clique }) {
  const limitar = (v, max) => Math.max(-max, Math.min(max, Math.round(Number(v) || 0)));
  dx = limitar(dx, 2000);
  dy = limitar(dy, 2000);
  roda = limitar(roda, 20);
  let eventos = '';
  if (dx) eventos += evento(EV_REL, REL_X, dx);
  if (dy) eventos += evento(EV_REL, REL_Y, dy);
  if (roda) eventos += evento(EV_REL, REL_WHEEL, roda);
  if (eventos) eventos += SYN;
  if (clique) eventos += evento(EV_KEY, BTN_LEFT, 1) + SYN + evento(EV_KEY, BTN_LEFT, 0) + SYN;
  if (eventos) await shell.mouse(eventos);
}

// --- YouCine: pausar e trocar de episodio ---------------------------------------------
// O player do YouCine e de TV: o OK (DPAD_CENTER, o ENTER nao serve) pausa e a seta para
// baixo abre um painel com a lista de episodios. Ele ignora as teclas de midia (play/pause,
// proximo), entao o servidor le a tela (dumpsys activity top) e navega como alguem com o
// controle da TV na mao.
const esperar = ms => new Promise(r => setTimeout(r, ms));

// Uma linha da hierarquia, ex.: "com.vod.view.VodPlayerWindow{40e10e9 VFE...... .F...... 0,0-1920,1080 #7f0a0352 app:id/mPlayerWindow}"
// 1o grupo de flags: V/I/G = visivel/invisivel/sumida; 2o grupo: F na 2a posicao = tem o foco
const LINHA_VIEW = /^( *)([\w.$]+)\{[0-9a-f]+ (\S{9}) (\S{8}) (-?\d+),(-?\d+)-(-?\d+),(-?\d+)(?: #[0-9a-f]+(?: [\w:]+\/(\w+))?)?/;

function arvoreDaTela(saida, atividade) {
  const linhas = saida.replace(/\r/g, '').split('\n');
  const inicio = linhas.findIndex(l => l.includes('DecorView@') && l.includes(`[${atividade}]`));
  if (inicio < 0) return null;
  const recuoDecor = linhas[inicio].search(/\S/);
  const raiz = { visivel: true, filhos: [] };
  const pilha = [{ recuo: recuoDecor, no: raiz }];
  for (const linha of linhas.slice(inicio + 1)) {
    const recuo = linha.search(/\S/);
    if (recuo <= recuoDecor) break; // acabou a hierarquia desta tela
    const m = linha.match(LINHA_VIEW);
    if (!m) continue;
    while (pilha.length > 1 && pilha[pilha.length - 1].recuo >= recuo) pilha.pop();
    const pai = pilha[pilha.length - 1].no;
    const no = {
      pai, filhos: [], id: m[9],
      visivel: m[3][0] === 'V', foco: m[4][1] === 'F',
      largura: m[7] - m[5],
    };
    pai.filhos.push(no);
    pilha.push({ recuo, no });
  }
  return raiz;
}

function acharId(no, id) {
  if (no.id === id) return no;
  for (const f of no.filhos) {
    const achado = acharId(f, id);
    if (achado) return achado;
  }
  return null;
}

function aparece(no) {
  for (let n = no; n; n = n.pai) if (!n.visivel) return false;
  return true;
}

function temFoco(no) {
  return no.foco || no.filhos.some(temFoco);
}

// A fileira de episodios do painel: cada item tem o icone "tocando" (mImgPlaying),
// visivel so no episodio atual. Os indices valem para a leitura em que foram calculados.
function episodiosDoPainel(painel) {
  let fileira = null;
  (function procurar(no) {
    if (fileira) return;
    if (no.filhos.length && no.filhos.every(f => f.filhos.some(g => g.id === 'mImgPlaying'))) fileira = no;
    else no.filhos.forEach(procurar);
  })(painel);
  if (!fileira) return null;
  return {
    tocando: fileira.filhos.findIndex(f => f.filhos.find(g => g.id === 'mImgPlaying').visivel),
    foco: fileira.filhos.findIndex(temFoco),
  };
}

// null = o YouCine nao esta na tela de um video
async function lerYouCine() {
  const arvore = arvoreDaTela(await shell.executar('dumpsys activity top', 8000), 'VodDetailsActivity');
  if (!arvore || !arvore.filhos.length) return null;
  const player = acharId(arvore, 'mPlayerWindow');
  const painel = acharId(arvore, 'mPlaySettingView');
  const painelAberto = !!painel && aparece(painel);
  return {
    telaCheia: !!player && aparece(player) && player.largura >= arvore.filhos[0].largura * 0.95,
    painel: painelAberto,
    episodios: painelAberto ? episodiosDoPainel(painel) : null,
  };
}

// Le a tela de novo ate "condicao" valer ou o tempo acabar; devolve a ultima leitura
async function esperarTela(condicao, tempoMs) {
  const fim = Date.now() + tempoMs;
  for (;;) {
    const tela = await lerYouCine();
    if (!tela || condicao(tela) || Date.now() > fim) return tela;
    await esperar(120);
  }
}
const episodios = tela => (tela && tela.episodios) || { tocando: -1, foco: -1 };

async function pausar() {
  const tela = await lerYouCine();
  // Fora do player do YouCine, a tecla de midia serve para outros apps
  if (!tela || !tela.telaCheia) return shell.tecla(TECLAS.play);
  // Com o painel de episodios aberto, o OK escolheria o episodio em vez de pausar
  if (tela.painel) {
    await shell.tecla(TECLAS.voltar);
    await esperarTela(t => !t.painel, 1000);
  }
  await apertarOk();
}

// passo: +1 = proximo episodio, -1 = anterior
let trocando = null;
function trocarEpisodio(passo) {
  if (!trocando) trocando = trocarEpisodioAgora(passo).finally(() => { trocando = null; });
  return trocando;
}

async function trocarEpisodioAgora(passo) {
  let tela = await lerYouCine();
  if (!tela || !tela.telaCheia) throw new Error('Abra um episodio no YouCine, em tela cheia.');
  // A seta para baixo abre o painel (se a 1a so mostrar a barra de informacoes, a 2a abre)
  for (let i = 0; i < 2 && tela && !tela.painel; i++) {
    await shell.tecla(TECLAS.baixo);
    tela = await esperarTela(t => t.painel, 1500);
  }
  if (!tela || !tela.painel) throw new Error('Nao consegui abrir a lista de episodios.');
  const fecharPainel = () => shell.tecla(TECLAS.voltar);
  // Ao abrir, o painel poe o foco no episodio atual, mas so uns instantes depois de aparecer
  let ep = episodios(await esperarTela(t => episodios(t).foco >= 0, 1000));
  if (ep.tocando < 0) {
    await fecharPainel();
    throw new Error('Este video nao tem lista de episodios.');
  }
  // Se o foco nao veio para a fileira dos episodios (a de cima do painel), sobe ate ela
  for (let i = 0; i < 3 && ep.foco < 0; i++) {
    await shell.tecla(TECLAS.cima);
    ep = episodios(await esperarTela(t => episodios(t).foco >= 0, 800));
  }
  // Leva o foco ate o episodio que esta tocando
  for (let i = 0; i < 3 && ep.foco >= 0 && ep.foco !== ep.tocando; i++) {
    const seta = ep.foco < ep.tocando ? TECLAS.direita : TECLAS.esquerda;
    for (let n = Math.abs(ep.tocando - ep.foco); n > 0; n--) await shell.tecla(seta);
    ep = episodios(await esperarTela(t => episodios(t).foco === episodios(t).tocando, 800));
  }
  if (ep.foco < 0 || ep.foco !== ep.tocando) {
    await fecharPainel();
    throw new Error('Nao consegui achar o episodio atual na lista.');
  }
  // Um passo para o lado: se o foco nao sair do lugar, nao ha episodio nessa direcao
  await shell.tecla(passo > 0 ? TECLAS.direita : TECLAS.esquerda);
  ep = episodios(await esperarTela(t => episodios(t).foco >= 0 && episodios(t).foco !== episodios(t).tocando, 800));
  if (ep.foco < 0 || ep.foco === ep.tocando) {
    await fecharPainel();
    throw new Error(passo > 0 ? 'Este ja e o ultimo episodio.' : 'Este ja e o primeiro episodio.');
  }
  await apertarOk();
}

// --- HTTP -----------------------------------------------------------------------
const TIPOS = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json',
  '.apk': 'application/vnd.android.package-archive',
};

function responder(res, status, corpo) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(corpo));
}

function lerCorpo(req) {
  return new Promise((resolver, rejeitar) => {
    let dados = '';
    req.on('data', d => { dados += d; if (dados.length > 10000) req.destroy(); });
    req.on('end', () => { try { resolver(dados ? JSON.parse(dados) : {}); } catch (e) { rejeitar(e); } });
    req.on('error', rejeitar);
  });
}

async function api(req, res, rota) {
  if (req.method === 'GET' && rota === 'estado') {
    const ligada = await tvLigada();
    // O celular abriu o controle com a TV ligada: ja liga o injetor, para o 1o OK nao demorar
    if (ligada && !ligando) teclasAndroid.aquecer();
    return responder(res, 200, { ligada, ligando: !!ligando });
  }
  if (req.method !== 'POST') return responder(res, 405, { erro: 'Use POST.' });

  if (rota === 'tv') {
    await ligarTv();
    return responder(res, 200, { ok: true });
  }
  if (rota === 'desligar') {
    await desligarTv();
    return responder(res, 200, { ok: true });
  }
  if (rota.startsWith('tecla/')) {
    const nome = rota.slice('tecla/'.length);
    const codigo = TECLAS[nome];
    if (!codigo) return responder(res, 404, { erro: 'Tecla desconhecida.' });
    if (nome === 'ok') await apertarOk();
    else await shell.tecla(codigo);
    return responder(res, 200, { ok: true });
  }
  if (rota === 'texto') {
    const { texto } = await lerCorpo(req);
    await digitar(String(texto || ''));
    return responder(res, 200, { ok: true });
  }
  if (rota === 'mouse') {
    await mexerMouse(await lerCorpo(req));
    return responder(res, 200, { ok: true });
  }
  if (rota === 'pausar') {
    await pausar();
    return responder(res, 200, { ok: true });
  }
  if (rota === 'episodio/proximo' || rota === 'episodio/anterior') {
    await trocarEpisodio(rota.endsWith('proximo') ? 1 : -1);
    return responder(res, 200, { ok: true });
  }
  responder(res, 404, { erro: 'Rota desconhecida.' });
}

function arquivo(req, res, url) {
  const nome = url === '/' ? 'index.html' : decodeURIComponent(url.slice(1));
  const caminho = path.normalize(path.join(PUBLICO, nome));
  if (!caminho.startsWith(PUBLICO + path.sep)) { res.writeHead(403); return res.end(); }
  fs.readFile(caminho, (erro, dados) => {
    if (erro) { res.writeHead(404); return res.end('Nao encontrado'); }
    res.writeHead(200, { 'Content-Type': TIPOS[path.extname(caminho)] || 'application/octet-stream', 'Content-Length': dados.length });
    res.end(dados);
  });
}

const vistos = new Set();
const servidor = http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];
  const ip = req.socket.remoteAddress.replace(/^::ffff:/, '');
  if (!vistos.has(ip)) { vistos.add(ip); console.log(`${hora()} conectou: ${ip}`); }
  if (!url.startsWith('/api/')) return arquivo(req, res, url);
  const rota = url.slice('/api/'.length);
  const inicio = Date.now();
  try {
    await api(req, res, rota);
    if (rota !== 'estado' && rota !== 'mouse') console.log(`${hora()} ${rota} (${Date.now() - inicio} ms)`);
  } catch (e) {
    console.log(`${hora()} ${rota} ERRO: ${e.message}${e.detalhe ? ` (${e.detalhe})` : ''}`);
    responder(res, e instanceof TvDesligada ? 409 : 500, { erro: e.message });
  }
});

function hora() {
  return new Date().toLocaleTimeString('pt-BR');
}

// IP do PC na rede de casa: o da interface que sai para a internet
// (o "connect" de UDP nao manda nada, so escolhe a rota)
function ipDaRede() {
  return new Promise(resolver => {
    const s = dgram.createSocket('udp4');
    s.connect(53, '8.8.8.8', () => { resolver(s.address().address); s.close(); });
    s.on('error', () => { resolver('IP-DO-PC'); s.close(); });
  });
}

servidor.on('error', e => {
  console.error(e.code === 'EADDRINUSE' ? `A porta ${PORTA} ja esta em uso. Use outra: set PORTA=9000` : e.message);
  process.exit(1);
});
servidor.listen(PORTA, '0.0.0.0', async () => {
  console.log(`Controle da TV pronto. No celular (mesmo Wi-Fi), abra:\n  http://${await ipDaRede()}:${PORTA}\n`);
});

// Descoberta: o app "TV" do celular manda "tv?" em broadcast UDP quando nao acha o PC
// no endereco salvo (ex.: o IP mudou); a resposta traz a porta e o IP vem do pacote.
const descoberta = dgram.createSocket('udp4');
descoberta.on('message', (msg, origem) => {
  if (msg.toString() !== 'tv?') return;
  descoberta.send(String(PORTA), origem.port, origem.address);
  console.log(`${hora()} celular procurou o PC: ${origem.address}`);
});
descoberta.on('error', e => console.log(`Descoberta pela rede desligada: ${e.message}`));
descoberta.bind(PORTA);
