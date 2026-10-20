// Configuração da Central SAC.
// Pegue os dois valores em: Supabase > Project Settings > API (ou "Data API").
// A chave "anon public" é feita para ficar no site: quem protege os dados são
// as regras do arquivo supabase.sql. NUNCA coloque aqui a chave "service_role".
window.SAC_CONFIG = {
  supabaseUrl: '',      // ex.: 'https://abcdefghijkl.supabase.co'
  supabaseAnonKey: '',  // ex.: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...'
  empresa: 'Victos',    // nome que aparece no topo e nas mensagens de WhatsApp
  whatsappSac: ''       // opcional: WhatsApp do SAC mostrado às lojas, ex.: '(11) 4000-1234'
};
