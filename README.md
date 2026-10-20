# Central SAC Victos

Site de atendimento às lojas da Victos: reclamações, devoluções, avarias e dúvidas.

## Como colocar no ar

O site tem duas partes:

| Página | Quem usa | Precisa de login? |
|---|---|---|
| `index.html` | Lojas: abrir chamados (vários produtos, fotos e vídeos) e acompanhar a resposta | Não. A loja consulta com protocolo + WhatsApp |
| `painel.html` | Equipe do SAC: fila, status, decisão por produto, respostas, fotos e vídeos, planilha | Sim, e-mail e senha |

Os dados ficam no **Supabase** (banco de dados gratuito) e o site fica no **GitHub Pages** (hospedagem gratuita).

## 1. Criar o banco no Supabase (uns 10 minutos)

1. Crie uma conta em https://supabase.com e clique em **New project**. Escolha a região **South America (São Paulo)** e anote a senha do banco.
2. No menu lateral, abra **SQL Editor** e clique em **New query**. Cole todo o conteúdo de `supabase.sql` e clique em **Run**.
3. Em **Authentication > Sign In / Providers**, desligue **Allow new users to sign up**. Assim, só quem você cadastrar entra no painel.
4. Em **Authentication > Users > Add user > Create new user**, crie o usuário de cada pessoa do SAC (e-mail + senha). Marque **Auto Confirm User**.
5. Volte ao **SQL Editor** e rode, para cada pessoa:

   ```sql
   insert into public.equipe (user_id, nome)
   select id, 'Ana Souza' from auth.users where email = 'ana@suaempresa.com.br'
   on conflict (user_id) do update set nome = excluded.nome;
   ```

   Para tirar alguém da equipe: `delete from public.equipe where user_id = (select id from auth.users where email = 'ana@suaempresa.com.br');`

## 2. Ligar o site ao banco

Em **Project Settings > API** (ou **Data API**), copie a **Project URL** e a chave **anon public**. Cole as duas em `config.js`. O nome da empresa já está como Victos.

A chave `anon` pode ficar no site: quem protege os dados são as regras do `supabase.sql`. **Nunca** use a chave `service_role` no site.

## 3. Publicar

Com o GitHub Pages ativo na branch `main` (Settings > Pages > Deploy from a branch > `main` / `root`), os endereços ficam assim:

- Lojas: `https://danieelozorio.github.io/Victos/`
- Equipe: `https://danieelozorio.github.io/Victos/painel.html`

No painel, a aba **Lojas** é onde a equipe cadastra as lojas, uma por uma ou colando uma lista do Excel (Nome, CNPJ, Cidade, Contato, WhatsApp). Cada loja ganha:

- um **link próprio** (`.../Victos/?loja=código`): o formulário abre com a loja identificada, sem digitar nome, CNPJ e cidade. O aparelho lembra da loja nas próximas visitas;
- um **QR code** pronto para imprimir (botão "Baixar QR code") e uma **mensagem** pronta para mandar no WhatsApp.

Ao desativar uma loja, o link dela para de funcionar.

A aba **Produtos** guarda o catálogo (código + nome). Cadastre um por um ou cole as duas colunas da planilha em **Importar lista**; códigos repetidos têm o nome atualizado. No formulário, a loja digita o código e o nome aparece sozinho, ou começa pelo nome e escolhe entre as sugestões. Produto fora do catálogo continua podendo ser digitado à mão.

**Ao atualizar o site com novidades no banco**, rode de novo o `supabase.sql` inteiro no SQL Editor. Ele só acrescenta o que falta e não apaga nenhum dado. Também existe um link geral, para quem ainda não foi cadastrado.

## Como os dados ficam protegidos

- A loja **não lê o banco**. Ela só abre chamados e consulta um chamado quando sabe o protocolo **e** o WhatsApp usado na abertura.
- As notas internas da equipe nunca aparecem para a loja.
- Fotos e vídeos ficam num bucket privado (`anexos`). A loja só envia, e só a equipe abre (por links que expiram em 1 hora).
- Cada produto do chamado recebe a sua decisão (aceito, com a quantidade, ou recusado, com justificativa). O banco registra quem decidiu e quando, e a loja vê o resultado de cada produto na consulta.
- Um usuário que faz login mas não está na tabela `equipe` não vê nada.

## Limites do plano gratuito do Supabase

São 500 MB de banco e 1 GB de arquivos, e cada arquivo pode ter no máximo 50 MB (um vídeo de celular de 20 a 30 segundos). O banco aguenta milhares de chamados, mas vídeos enchem o 1 GB rápido: com uso intenso de vídeo, vale o plano Pro (US$ 25/mês, 100 GB). Um projeto sem acesso por 7 dias é pausado; basta entrar no painel do Supabase e reativar. Com uso diário, isso não acontece.

## Arquivos


- `index.html`: página das lojas
- `painel.html`: painel da equipe
- `comum.js`, `estilo.css`: partes compartilhadas
- `config.js`: a sua configuração do Supabase
- `supabase.sql`: estrutura e regras de segurança do banco
- `img/`: logos da Victos (versões para fundo claro e escuro), ícone do site e selo do Grupo UniSuper
