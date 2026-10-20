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
  produto        text,
  quantidade     integer check (quantidade is null or quantidade >= 0),
  descricao      text not null,
  fotos          text[] not null default '{}',  -- caminhos no bucket "fotos"
  responsavel    uuid references auth.users (id) on delete set null,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

create index if not exists chamados_status_idx on public.chamados (status);
create index if not exists chamados_criado_idx on public.chamados (criado_em desc);

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

-- Uma mensagem nova também move o "atualizado em" do chamado.
create or replace function public.mensagem_toca_chamado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.chamados set atualizado_em = now() where id = new.chamado_id;
  return new;
end $$;

drop trigger if exists mensagens_toca on public.mensagens;
create trigger mensagens_toca after insert on public.mensagens
  for each row execute function public.mensagem_toca_chamado();

-- ---------- Segurança (RLS) ----------
-- A loja (usuário anônimo) não lê nem grava as tabelas diretamente:
-- tudo passa pelas funções abrir_chamado / consultar_chamado / mensagem_loja.

alter table public.chamados  enable row level security;
alter table public.mensagens enable row level security;
alter table public.equipe    enable row level security;

drop policy if exists chamados_equipe_le    on public.chamados;
drop policy if exists chamados_equipe_altera on public.chamados;
create policy chamados_equipe_le     on public.chamados for select to authenticated using (public.eh_equipe());
create policy chamados_equipe_altera on public.chamados for update to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

drop policy if exists mensagens_equipe_le    on public.mensagens;
drop policy if exists mensagens_equipe_grava on public.mensagens;
create policy mensagens_equipe_le    on public.mensagens for select to authenticated using (public.eh_equipe());
create policy mensagens_equipe_grava on public.mensagens for insert to authenticated
  with check (public.eh_equipe() and autor in ('equipe', 'sistema') and autor_id = auth.uid());

drop policy if exists equipe_le on public.equipe;
create policy equipe_le on public.equipe for select to authenticated using (public.eh_equipe());

revoke all on public.chamados, public.mensagens, public.equipe from anon;
grant select, update on public.chamados to authenticated;
grant select, insert on public.mensagens to authenticated;
grant select on public.equipe to authenticated;

-- ---------- Funções públicas usadas pela página da loja ----------

create or replace function public.abrir_chamado(dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tipo      text := dados->>'tipo';
  v_whats     text := regexp_replace(coalesce(dados->>'loja_whatsapp', ''), '\D', '', 'g');
  v_fotos     text[] := coalesce(array(select jsonb_array_elements_text(coalesce(dados->'fotos', '[]'::jsonb))), '{}');
  v_qtd       integer;
  v_proto     text;
  v_id        uuid;
  v_tentativa integer := 0;
begin
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
  if cardinality(v_fotos) > 6 then
    raise exception 'Envie no máximo 6 fotos' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_fotos) f where f !~ '^pendente/[0-9a-f-]{36}\.(jpg|jpeg|png|webp|heic)$') then
    raise exception 'Foto inválida' using errcode = '22023';
  end if;
  if nullif(dados->>'quantidade', '') is not null then
    v_qtd := greatest(0, (dados->>'quantidade')::numeric)::integer;
  end if;

  loop
    v_proto := 'SAC-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYMMDD') || '-' ||
      (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (get_byte(b, i) % 32), 1), '')
         from (select uuid_send(gen_random_uuid()) as b) r, generate_series(0, 3) i);
    begin
      insert into public.chamados (protocolo, tipo, motivo, prioridade, loja_nome, loja_cnpj, loja_cidade,
                                   loja_contato, loja_whatsapp, nf, produto, quantidade, descricao, fotos)
      values (v_proto, v_tipo, left(trim(dados->>'motivo'), 120),
              case when v_tipo = 'avaria' then 'alta' else 'normal' end,
              left(trim(dados->>'loja_nome'), 200), left(nullif(trim(dados->>'loja_cnpj'), ''), 30),
              left(nullif(trim(dados->>'loja_cidade'), ''), 120), left(trim(dados->>'loja_contato'), 120),
              v_whats, left(nullif(trim(dados->>'nf'), ''), 60), left(nullif(trim(dados->>'produto'), ''), 200),
              v_qtd, trim(dados->>'descricao'), v_fotos)
      returning id into v_id;
      exit;
    exception when unique_violation then
      v_tentativa := v_tentativa + 1;
      if v_tentativa > 5 then raise; end if;
    end;
  end loop;

  insert into public.mensagens (chamado_id, autor, texto) values (v_id, 'sistema', 'Chamado aberto pela loja');
  return jsonb_build_object('protocolo', v_proto);
end $$;

-- A loja consulta com protocolo + WhatsApp informado na abertura.
create or replace function public.consultar_chamado(p_protocolo text, p_whatsapp text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'protocolo', c.protocolo, 'tipo', c.tipo, 'motivo', c.motivo, 'status', c.status,
    'loja_nome', c.loja_nome, 'nf', c.nf, 'produto', c.produto, 'quantidade', c.quantidade,
    'descricao', c.descricao, 'criado_em', c.criado_em, 'atualizado_em', c.atualizado_em,
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
grant execute on function public.abrir_chamado(jsonb) to anon, authenticated;
grant execute on function public.consultar_chamado(text, text) to anon, authenticated;
grant execute on function public.mensagem_loja(text, text, text) to anon, authenticated;
grant execute on function public.eh_equipe() to authenticated;

-- ---------- Fotos (Storage) ----------
-- Bucket privado: a loja só envia; só a equipe abre as fotos.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos', 'fotos', false, 8388608, array['image/jpeg', 'image/png', 'image/webp', 'image/heic'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists fotos_loja_envia on storage.objects;
drop policy if exists fotos_equipe_le  on storage.objects;
create policy fotos_loja_envia on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'fotos' and name ~ '^pendente/[0-9a-f-]{36}\.(jpg|jpeg|png|webp|heic)$');
create policy fotos_equipe_le on storage.objects for select to authenticated
  using (bucket_id = 'fotos' and public.eh_equipe());

-- ---------- Tempo real (o painel atualiza sozinho) ----------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'chamados') then
      alter publication supabase_realtime add table public.chamados;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'mensagens') then
      alter publication supabase_realtime add table public.mensagens;
    end if;
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
