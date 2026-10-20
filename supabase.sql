-- =====================================================================
-- Central SAC · estrutura do banco no Supabase
-- Cole este arquivo inteiro em: Supabase > SQL Editor > New query > Run
-- Pode rodar de novo sem perder dados (os comandos são idempotentes).
-- =====================================================================

-- ---------- Tabelas ----------

create table if not exists public.chamados (
  id             uuid primary key default gen_random_uuid(),
  protocolo      text unique not null,
  tipo           text not null check (tipo in ('reclamacao', 'devolucao', 'avaria', 'duvida')),
  motivo         text not null,
  status         text not null default 'novo'
                 check (status in ('novo', 'analise', 'aguardando', 'aprovado', 'resolvido', 'recusado')),
  prioridade     text not null default 'normal' check (prioridade in ('normal', 'alta', 'urgente')),
  loja_nome      text not null,
  loja_cnpj      text,
  loja_cidade    text,
  loja_contato   text not null,
  loja_whatsapp  text not null,          -- só dígitos, usado também para a loja consultar
  nf             text,
  descricao      text not null,
  anexos         text[] not null default '{}',  -- fotos e vídeos: caminhos no bucket "anexos"
  responsavel    uuid references auth.users (id) on delete set null,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

create index if not exists chamados_status_idx on public.chamados (status);
create index if not exists chamados_criado_idx on public.chamados (criado_em desc);

-- Produtos (SKUs) do chamado. Cada um recebe a sua própria decisão.
create table if not exists public.chamado_itens (
  id             bigint generated always as identity primary key,
  chamado_id     uuid not null references public.chamados (id) on delete cascade,
  ordem          integer not null default 1,
  sku            text,
  produto        text,
  quantidade     integer check (quantidade is null or quantidade >= 0),
  decisao        text not null default 'pendente' check (decisao in ('pendente', 'aceito', 'recusado')),
  qtd_aceita     integer check (qtd_aceita is null or qtd_aceita >= 0),
  justificativa  text,
  decidido_por   uuid references auth.users (id) on delete set null,
  decidido_em    timestamptz
);

create index if not exists chamado_itens_chamado_idx on public.chamado_itens (chamado_id, ordem);
-- Motivo próprio de cada produto (ex.: um em falta, outro com falta de peso).
alter table public.chamado_itens add column if not exists motivo text;
-- Quantidade em unidades ou quilos (com até 3 casas decimais).
alter table public.chamado_itens add column if not exists unidade text not null default 'un';
alter table public.chamado_itens drop constraint if exists chamado_itens_unidade_check;
alter table public.chamado_itens add constraint chamado_itens_unidade_check check (unidade in ('un', 'kg'));
alter table public.chamado_itens alter column quantidade type numeric(12, 3);
alter table public.chamado_itens alter column qtd_aceita type numeric(12, 3);

create table if not exists public.mensagens (
  id          bigint generated always as identity primary key,
  chamado_id  uuid not null references public.chamados (id) on delete cascade,
  autor       text not null check (autor in ('loja', 'equipe', 'sistema')),
  autor_id    uuid references auth.users (id) on delete set null,
  interna     boolean not null default false,   -- nota interna: a loja nunca vê
  texto       text not null check (length(texto) between 1 and 4000),
  criado_em   timestamptz not null default now()
);

create index if not exists mensagens_chamado_idx on public.mensagens (chamado_id, criado_em);

-- Quem faz parte do SAC. Só quem está aqui enxerga e altera a fila.
create table if not exists public.equipe (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  nome       text not null,
  criado_em  timestamptz not null default now()
);

-- Lojas cadastradas pela equipe. Cada uma tem um código que vai no link dela,
-- para o formulário já abrir com os dados da loja preenchidos.
create or replace function public.gerar_codigo_loja()
returns text language sql volatile as $$
  select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + (get_byte(b, i) % 31), 1), '')
    from (select uuid_send(gen_random_uuid()) as b) r, generate_series(0, 6) i;
$$;

create table if not exists public.lojas (
  id         uuid primary key default gen_random_uuid(),
  codigo     text unique not null default public.gerar_codigo_loja(),
  nome       text not null check (length(trim(nome)) between 1 and 200),
  cnpj       text,
  cidade     text,
  contato    text,
  whatsapp   text,
  ativa      boolean not null default true,
  criado_em  timestamptz not null default now()
);

alter table public.chamados add column if not exists loja_id uuid references public.lojas (id) on delete set null;
create index if not exists chamados_loja_idx on public.chamados (loja_id);

-- Catálogo de produtos: a loja digita o código e o nome aparece (e vice-versa).
create table if not exists public.produtos (
  sku        text primary key check (length(trim(sku)) between 1 and 60),
  nome       text not null check (length(trim(nome)) between 1 and 200),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- Texto sem acento e em minúsculas, para a busca achar "acucar" em "Açúcar".
create or replace function public.sem_acento(t text)
returns text language sql immutable as $$
  select translate(lower(coalesce(t, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn');
$$;

-- ---------- Funções auxiliares ----------

create or replace function public.eh_equipe()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.equipe where user_id = auth.uid());
$$;

create or replace function public.tocar_atualizado_em()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

drop trigger if exists chamados_atualizado on public.chamados;
create trigger chamados_atualizado before update on public.chamados
  for each row execute function public.tocar_atualizado_em();

-- Mensagem nova ou decisão em produto também move o "atualizado em" do chamado.
create or replace function public.filho_toca_chamado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.chamados set atualizado_em = now() where id = new.chamado_id;
  return new;
end $$;

drop trigger if exists mensagens_toca on public.mensagens;
create trigger mensagens_toca after insert on public.mensagens
  for each row execute function public.filho_toca_chamado();

drop trigger if exists itens_toca on public.chamado_itens;
create trigger itens_toca after update on public.chamado_itens
  for each row execute function public.filho_toca_chamado();

-- Registra quem decidiu e quando, sem depender do navegador.
create or replace function public.item_decidido()
returns trigger language plpgsql as $$
begin
  if new.decisao is distinct from old.decisao or new.qtd_aceita is distinct from old.qtd_aceita
     or new.justificativa is distinct from old.justificativa then
    new.decidido_por := auth.uid();
    new.decidido_em := case when new.decisao = 'pendente' then null else now() end;
  end if;
  return new;
end $$;

drop trigger if exists itens_decidido on public.chamado_itens;
create trigger itens_decidido before update on public.chamado_itens
  for each row execute function public.item_decidido();

-- ---------- Segurança (RLS) ----------
-- A loja (usuário anônimo) não lê nem grava as tabelas diretamente:
-- tudo passa pelas funções abrir_chamado / consultar_chamado / mensagem_loja.

alter table public.chamados      enable row level security;
alter table public.chamado_itens enable row level security;
alter table public.mensagens     enable row level security;
alter table public.equipe        enable row level security;
alter table public.lojas         enable row level security;
alter table public.produtos      enable row level security;

drop policy if exists chamados_equipe_le     on public.chamados;
drop policy if exists chamados_equipe_altera on public.chamados;
create policy chamados_equipe_le     on public.chamados for select to authenticated using (public.eh_equipe());
create policy chamados_equipe_altera on public.chamados for update to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

drop policy if exists itens_equipe_le     on public.chamado_itens;
drop policy if exists itens_equipe_altera on public.chamado_itens;
create policy itens_equipe_le     on public.chamado_itens for select to authenticated using (public.eh_equipe());
create policy itens_equipe_altera on public.chamado_itens for update to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

drop policy if exists mensagens_equipe_le    on public.mensagens;
drop policy if exists mensagens_equipe_grava on public.mensagens;
create policy mensagens_equipe_le    on public.mensagens for select to authenticated using (public.eh_equipe());
create policy mensagens_equipe_grava on public.mensagens for insert to authenticated
  with check (public.eh_equipe() and autor in ('equipe', 'sistema') and autor_id = auth.uid());

drop policy if exists lojas_equipe on public.lojas;
create policy lojas_equipe on public.lojas for all to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

drop policy if exists produtos_equipe on public.produtos;
create policy produtos_equipe on public.produtos for all to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

drop policy if exists equipe_le on public.equipe;
create policy equipe_le on public.equipe for select to authenticated using (public.eh_equipe());

revoke all on public.chamados, public.chamado_itens, public.mensagens, public.equipe, public.lojas from anon;
grant select, insert, update, delete on public.lojas to authenticated;
revoke all on public.produtos from anon;
grant select, insert, update, delete on public.produtos to authenticated;
grant select, update on public.chamados to authenticated;
grant select on public.chamado_itens to authenticated;
grant update (decisao, qtd_aceita, justificativa) on public.chamado_itens to authenticated;
grant select, insert on public.mensagens to authenticated;
grant select on public.equipe to authenticated;

-- ---------- Funções públicas usadas pela página da loja ----------

-- Caminho aceito para anexos enviados pela loja (fotos e vídeos).
create or replace function public.anexo_valido(caminho text)
returns boolean language sql immutable as $$
  select caminho ~ '^pendente/[0-9a-f-]{36}\.(jpg|jpeg|png|webp|heic|mp4|mov|webm|3gp)$';
$$;

create or replace function public.abrir_chamado(dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tipo      text := dados->>'tipo';
  v_whats     text := regexp_replace(coalesce(dados->>'loja_whatsapp', ''), '\D', '', 'g');
  v_anexos    text[] := coalesce(array(select jsonb_array_elements_text(coalesce(dados->'anexos', '[]'::jsonb))), '{}');
  v_itens     jsonb := coalesce(dados->'itens', '[]'::jsonb);
  v_item      jsonb;
  v_ordem     integer := 0;
  v_qtd       numeric(12, 3);
  v_proto     text;
  v_id        uuid;
  v_tentativa integer := 0;
  v_loja      public.lojas%rowtype;
begin
  if coalesce(dados->>'loja_codigo', '') <> '' then
    select * into v_loja from public.lojas where codigo = lower(trim(dados->>'loja_codigo')) and ativa;
    if found then
      -- Os dados cadastrados valem mais que os digitados: o link da loja é a fonte.
      dados := dados || jsonb_build_object('loja_nome', v_loja.nome, 'loja_cnpj', coalesce(v_loja.cnpj, ''), 'loja_cidade', coalesce(v_loja.cidade, ''));
    end if;
  end if;
  if v_tipo not in ('reclamacao', 'devolucao', 'avaria', 'duvida') then
    raise exception 'Tipo de atendimento inválido' using errcode = '22023';
  end if;
  if coalesce(trim(dados->>'loja_nome'), '') = '' or coalesce(trim(dados->>'loja_contato'), '') = ''
     or coalesce(trim(dados->>'motivo'), '') = '' or coalesce(trim(dados->>'descricao'), '') = '' then
    raise exception 'Preencha os campos obrigatórios' using errcode = '22023';
  end if;
  if length(v_whats) not between 10 and 13 then
    raise exception 'WhatsApp inválido: use DDD + número' using errcode = '22023';
  end if;
  if length(dados->>'descricao') > 4000 or length(dados->>'loja_nome') > 200 then
    raise exception 'Texto longo demais' using errcode = '22023';
  end if;
  if jsonb_typeof(v_itens) <> 'array' or jsonb_array_length(v_itens) > 200 then
    raise exception 'Lista de produtos inválida' using errcode = '22023';
  end if;
  if v_tipo in ('devolucao', 'avaria') and not exists (
       select 1 from jsonb_array_elements(v_itens) i
        where coalesce(trim(i->>'sku'), '') <> '' or coalesce(trim(i->>'produto'), '') <> '') then
    raise exception 'Informe pelo menos um produto' using errcode = '22023';
  end if;
  -- Teto de segurança contra abuso; na prática, a loja não sente limite.
  if cardinality(v_anexos) > 100 then
    raise exception 'Anexos demais em um só chamado' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_anexos) a where not public.anexo_valido(a)) then
    raise exception 'Anexo inválido' using errcode = '22023';
  end if;

  loop
    v_proto := 'SAC-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYMMDD') || '-' ||
      (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (get_byte(b, i) % 32), 1), '')
         from (select uuid_send(gen_random_uuid()) as b) r, generate_series(0, 3) i);
    begin
      insert into public.chamados (protocolo, tipo, motivo, prioridade, loja_id, loja_nome, loja_cnpj, loja_cidade,
                                   loja_contato, loja_whatsapp, nf, descricao, anexos)
      values (v_proto, v_tipo, left(trim(dados->>'motivo'), 120),
              case when v_tipo = 'avaria' then 'alta' else 'normal' end, v_loja.id,
              left(trim(dados->>'loja_nome'), 200), left(nullif(trim(dados->>'loja_cnpj'), ''), 30),
              left(nullif(trim(dados->>'loja_cidade'), ''), 120), left(trim(dados->>'loja_contato'), 120),
              v_whats, left(nullif(trim(dados->>'nf'), ''), 60), trim(dados->>'descricao'), v_anexos)
      returning id into v_id;
      exit;
    exception when unique_violation then
      v_tentativa := v_tentativa + 1;
      if v_tentativa > 5 then raise; end if;
    end;
  end loop;

  for v_item in select * from jsonb_array_elements(v_itens) loop
    continue when coalesce(trim(v_item->>'sku'), '') = '' and coalesce(trim(v_item->>'produto'), '') = '';
    v_ordem := v_ordem + 1;
    v_qtd := null;
    if nullif(v_item->>'quantidade', '') is not null then
      v_qtd := round(greatest(0, replace(v_item->>'quantidade', ',', '.')::numeric), 3);
    end if;
    insert into public.chamado_itens (chamado_id, ordem, sku, produto, quantidade, unidade, motivo)
    values (v_id, v_ordem, left(nullif(trim(v_item->>'sku'), ''), 60), left(nullif(trim(v_item->>'produto'), ''), 200), v_qtd,
            case when v_item->>'unidade' = 'kg' then 'kg' else 'un' end,
            left(nullif(trim(v_item->>'motivo'), ''), 120));
  end loop;

  insert into public.mensagens (chamado_id, autor, texto) values (v_id, 'sistema', 'Chamado aberto pela loja');
  return jsonb_build_object('protocolo', v_proto);
end $$;

-- Busca no catálogo para o formulário da loja: por código exato, começo do código ou parte do nome.
create or replace function public.buscar_produtos(p_busca text, p_limite integer default 8)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with b as (select trim(coalesce(p_busca, '')) as q, public.sem_acento(trim(coalesce(p_busca, ''))) as qn)
  select coalesce(jsonb_agg(jsonb_build_object('sku', r.sku, 'nome', r.nome) order by r.ordem, r.nome), '[]'::jsonb)
  from (
    select p.sku, p.nome,
           case when lower(p.sku) = lower(b.q) then 0
                when lower(p.sku) like lower(b.q) || '%' then 1
                when public.sem_acento(p.nome) like b.qn || '%' then 2
                else 3 end as ordem
      from public.produtos p, b
     where p.ativo and length(b.q) >= 2
       and (lower(p.sku) like lower(b.q) || '%' or public.sem_acento(p.nome) like '%' || b.qn || '%')
     order by ordem, p.nome
     limit least(greatest(coalesce(p_limite, 8), 1), 20)
  ) r;
$$;

-- Dados da loja para o formulário que abre pelo link dela.
create or replace function public.loja_por_codigo(p_codigo text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object('codigo', codigo, 'nome', nome, 'cnpj', cnpj, 'cidade', cidade, 'contato', contato, 'whatsapp', whatsapp)
    from public.lojas where codigo = lower(trim(p_codigo)) and ativa;
$$;

-- A loja consulta com protocolo + WhatsApp informado na abertura.
create or replace function public.consultar_chamado(p_protocolo text, p_whatsapp text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'protocolo', c.protocolo, 'tipo', c.tipo, 'motivo', c.motivo, 'status', c.status,
    'loja_nome', c.loja_nome, 'nf', c.nf, 'descricao', c.descricao, 'anexos_qtd', cardinality(c.anexos),
    'criado_em', c.criado_em, 'atualizado_em', c.atualizado_em,
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object('sku', i.sku, 'produto', i.produto, 'quantidade', i.quantidade, 'unidade', i.unidade, 'motivo', i.motivo,
                                          'decisao', i.decisao, 'qtd_aceita', i.qtd_aceita, 'justificativa', i.justificativa)
                       order by i.ordem)
      from public.chamado_itens i where i.chamado_id = c.id
    ), '[]'::jsonb),
    'mensagens', coalesce((
      select jsonb_agg(jsonb_build_object('autor', m.autor, 'texto', m.texto, 'criado_em', m.criado_em) order by m.criado_em)
      from public.mensagens m where m.chamado_id = c.id and not m.interna
    ), '[]'::jsonb))
  from public.chamados c
  where c.protocolo = upper(trim(p_protocolo))
    and c.loja_whatsapp = regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g');
$$;

create or replace function public.mensagem_loja(p_protocolo text, p_whatsapp text, p_texto text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
begin
  if coalesce(trim(p_texto), '') = '' or length(p_texto) > 4000 then
    raise exception 'Mensagem vazia ou longa demais' using errcode = '22023';
  end if;
  select id into v_id from public.chamados
   where protocolo = upper(trim(p_protocolo))
     and loja_whatsapp = regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g');
  if v_id is null then return false; end if;
  insert into public.mensagens (chamado_id, autor, texto) values (v_id, 'loja', trim(p_texto));
  update public.chamados set status = 'analise' where id = v_id and status = 'aguardando';
  return true;
end $$;

revoke all on function public.abrir_chamado(jsonb) from public;
revoke all on function public.consultar_chamado(text, text) from public;
revoke all on function public.mensagem_loja(text, text, text) from public;
revoke all on function public.loja_por_codigo(text) from public;
revoke all on function public.buscar_produtos(text, integer) from public;
grant execute on function public.buscar_produtos(text, integer) to anon, authenticated;
grant execute on function public.loja_por_codigo(text) to anon, authenticated;
grant execute on function public.abrir_chamado(jsonb) to anon, authenticated;
grant execute on function public.consultar_chamado(text, text) to anon, authenticated;
grant execute on function public.mensagem_loja(text, text, text) to anon, authenticated;
grant execute on function public.eh_equipe() to authenticated;
grant execute on function public.anexo_valido(text) to anon, authenticated;

-- ---------- Fotos e vídeos (Storage) ----------
-- Bucket privado: a loja só envia; só a equipe abre os anexos.
-- 50 MB por arquivo é o máximo do plano gratuito do Supabase.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('anexos', 'anexos', false, 52428800,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif',
              'video/mp4', 'video/quicktime', 'video/webm', 'video/3gpp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists anexos_loja_envia on storage.objects;
drop policy if exists anexos_equipe_le  on storage.objects;
create policy anexos_loja_envia on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'anexos' and public.anexo_valido(name));
create policy anexos_equipe_le on storage.objects for select to authenticated
  using (bucket_id = 'anexos' and public.eh_equipe());

-- ---------- Tempo real (o painel atualiza sozinho) ----------
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['chamados', 'chamado_itens', 'mensagens', 'lojas'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- =====================================================================
-- DEPOIS DE RODAR: cadastre a equipe.
-- 1) Em Authentication > Users > Add user, crie o usuário (e-mail e senha).
-- 2) Rode o comando abaixo trocando o e-mail e o nome:
--
--   insert into public.equipe (user_id, nome)
--   select id, 'Seu Nome' from auth.users where email = 'voce@empresa.com.br'
--   on conflict (user_id) do update set nome = excluded.nome;
-- =====================================================================
