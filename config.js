// Configuração da Central SAC.
// Pegue os dois valores em: Supabase > Project Settings > API (ou "Data API").
// A chave "anon public" é feita para ficar no site: quem protege os dados são
// as regras do arquivo supabase.sql. NUNCA coloque aqui a chave "service_role".
window.SAC_CONFIG = {
  supabaseUrl: 'https://jetzcfiooluppuukryue.supabase.co',
  supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpldHpjZmlvb2x1cHB1dWtyeXVlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI1MDIxMzAsImV4cCI6MjEwODA3ODEzMH0.NsC8uL0aPUvsHCgpxgwFdOH2Mat7EJcOsNH-3kX-azk',
  empresa: 'Victos',    // nome que aparece no topo e nas mensagens de WhatsApp
  whatsappSac: ''       // opcional: WhatsApp do SAC mostrado às lojas, ex.: '(11) 4000-1234'
};
