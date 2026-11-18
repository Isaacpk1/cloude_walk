# Origem dos dados que uma tela mostra. Toda conversa e todo evento carregam a sua,
# para o painel nunca apresentar exemplo como se fosse registro (ROADMAP, "Como desenvolver").
class DataSource < Data.define(:key, :label)
  def synthetic? = key == :synthetic
end

DataSource::SYNTHETIC = DataSource.new(key: :synthetic, label: "Exemplo sintético")
DataSource::SYSTEM = DataSource.new(key: :system, label: "Registro do sistema")
