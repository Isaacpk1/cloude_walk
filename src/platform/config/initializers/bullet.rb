# Detecta consultas N+1 e carregamento desnecessário no painel (desenvolvimento). Só liga se a gem estiver instalada
# (`bundle add bullet --group development`). Os avisos vão para o log do Rails e para o rodapé das páginas.
if Rails.env.development? && defined?(Bullet)
  Rails.application.config.after_initialize do
    Bullet.enable = true
    Bullet.rails_logger = true
    Bullet.add_footer = true
  end
end
