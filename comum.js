// Peças compartilhadas pela página das lojas e pelo painel da equipe.
(function () {
  const TIPOS = {
    reclamacao: { rot: 'Reclamação', dica: 'Produto, entrega ou atendimento', sla: 48,
      motivos: ['Atraso na entrega', 'Qualidade do produto', 'Atendimento', 'Cobrança / boleto', 'Outro'] },
    devolucao: { rot: 'Devolução / troca', dica: 'Com nota fiscal e motivo', sla: 72,
      motivos: ['Produto com defeito', 'Produto errado', 'Quantidade divergente', 'Validade próxima', 'Produto parado (encalhe)', 'Outro'] },
    avaria: { rot: 'Avaria no transporte', dica: 'Chegou danificado', sla: 24,
      motivos: ['Embalagem danificada', 'Produto quebrado', 'Produto molhado', 'Volume faltando', 'Outro'] },
    duvida: { rot: 'Dúvida / pedido', dica: 'Boleto, nota, prazo', sla: 24,
      motivos: ['2ª via de boleto', '2ª via de nota fiscal', 'Status do pedido', 'Prazo de entrega', 'Outro'] }
  };
  const STATUS = {
    novo: 'Novo', analise: 'Em análise', aguardando: 'Aguardando loja',
    aprovado: 'Aprovado', resolvido: 'Resolvido', recusado: 'Recusado'
  };
  const ABERTOS = ['novo', 'analise', 'aguardando', 'aprovado'];
  const PRIORIDADES = { normal: 'Normal', alta: 'Alta', urgente: 'Urgente' };

  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const soDigitos = (s) => String(s || '').replace(/\D/g, '');

  const store = {
    get(k) { try { return JSON.parse(localStorage.getItem(k) || 'null'); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* sem armazenamento */ } }
  };

  function prazoDe(t) { return new Date(new Date(t.criado_em).getTime() + (TIPOS[t.tipo]?.sla || 48) * 3600e3); }
  function dur(ms) {
    const min = Math.round(ms / 60000);
    if (min < 60) return min + ' min';
    const h = Math.round(min / 60);
    if (h < 48) return h + ' h';
    return Math.round(h / 24) + ' dias';
  }
  const fmtData = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
  function quando(iso) { try { return fmtData.format(new Date(iso)); } catch (e) { return ''; } }
  function prazoInfo(t) {
    if (!ABERTOS.includes(t.status)) return { cls: 'ok', txt: STATUS[t.status] + ' ' + quando(t.atualizado_em) };
    const diff = prazoDe(t).getTime() - Date.now();
    if (diff < 0) return { cls: 'bad', txt: 'Atrasado ' + dur(-diff), atrasado: true };
    if (diff < 6 * 3600e3) return { cls: 'warn', txt: 'Vence em ' + dur(diff) };
    return { cls: 'ok', txt: 'Vence em ' + dur(diff) };
  }
  function waNumero(s) {
    const d = soDigitos(s);
    if (!d) return '';
    return (d.length === 10 || d.length === 11) ? '55' + d : d;
  }
  function foneBonito(s) {
    const d = soDigitos(s).replace(/^55(?=\d{10,11}$)/, '');
    if (d.length === 11) return `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}`;
    if (d.length === 10) return `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`;
    return s || '';
  }

  function toast(msg) {
    const el = $('toast');
    if (!el) return;
    el.textContent = msg;
    el.hidden = false;
    clearTimeout(toast.t);
    toast.t = setTimeout(() => { el.hidden = true; }, 3000);
  }
  async function copiar(txt) {
    try { await navigator.clipboard.writeText(txt); toast('Copiado!'); }
    catch (e) { toast('Não deu para copiar. Selecione o texto e copie manualmente.'); }
  }

  // Cria o cliente do Supabase, ou devolve null se o config.js ainda não foi preenchido.
  function cliente() {
    const c = window.SAC_CONFIG || {};
    if (!c.supabaseUrl || !c.supabaseAnonKey || !window.supabase) return null;
    return window.supabase.createClient(c.supabaseUrl, c.supabaseAnonKey);
  }

  // Traduz erros do banco para algo que a pessoa entenda.
  function mensagemErro(err) {
    const m = (err && (err.message || err.error_description)) || '';
    if (/Failed to fetch|NetworkError|network/i.test(m)) return 'Sem conexão com a internet. Confira e tente de novo.';
    if (/Invalid login credentials/i.test(m)) return 'E-mail ou senha incorretos.';
    if (/Preencha|inválid|longa demais|no máximo/i.test(m)) return m + '.';
    if (/exceeded the maximum allowed size|Payload too large/i.test(m)) return 'Foto grande demais (máximo 8 MB).';
    if (/mime type|invalid_mime/i.test(m)) return 'Formato de foto não aceito. Use JPG, PNG, WEBP ou HEIC.';
    return 'Algo deu errado. Tente de novo em instantes.';
  }

  function configPendente() {
    return '<div class="banner"><div><b>Site ainda não conectado ao banco de dados.</b> Preencha o arquivo <span class="mono">config.js</span> com a URL e a chave do Supabase (veja o passo a passo no LEIAME).</div></div>';
  }

  window.SAC = { TIPOS, STATUS, ABERTOS, PRIORIDADES, $, esc, soDigitos, store, prazoDe, prazoInfo, dur, quando, waNumero, foneBonito, toast, copiar, cliente, mensagemErro, configPendente };
})();
