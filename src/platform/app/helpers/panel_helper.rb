# Apresentação do painel: selos, rótulos e formatação de tempo. Sem regra de negócio.
module PanelHelper
  DISPLAY_TIME_ZONE = PanelClock::TIME_ZONE
  RESERVED_SECTIONS = %w[Filas Evals Configuração].freeze

  def nav_link(label, path, active:)
    link_to label, path, class: class_names("nav__item", "nav__item--active" => active), aria: { current: (active ? "page" : nil) }
  end

  def reserved_nav_item(label)
    tag.span(label, class: "nav__item nav__item--disabled", aria: { disabled: true }, title: "Chega nos próximos blocos do roadmap")
  end

  def source_badge(source)
    tag.span(source.label, class: "badge badge--source badge--#{source.key}", title: "Origem dos dados")
  end

  def author_badge(message)
    tag.span(message.author_label, class: "badge badge--author badge--#{message.author_type}")
  end

  # Mensagem de entrada lida do banco já foi confirmada: o 202 só sai depois do commit (RNF-14).
  def delivery_badge(message, source = DataSource::SYNTHETIC)
    if message.inbound? && !source.synthetic?
      return tag.span("Confirmada", class: "badge badge--delivery badge--delivered", title: "Gravada antes do 202 ao provedor")
    end
    return tag.span("Recebida", class: "badge badge--delivery badge--received") if message.inbound?

    tag.span(message.delivery_label || "Sem entrega", class: "badge badge--delivery badge--#{message.delivery_status || 'none'}")
  end

  def turn_status_badge(turn)
    tag.span(turn.status_label, class: "badge badge--turn badge--#{turn.status}")
  end

  def covered_seqs_text(turn)
    "cobre seq #{turn.covered_seqs.to_sentence(words_connector: ', ', two_words_connector: ' e ', last_word_connector: ' e ')}"
  end

  def panel_time(time, precise: false) = PanelClock.format(time, precise:)

  def duration_text(ms)
    ms.nil? ? "sem fim registrado" : "#{ms} ms"
  end

  # Argumentos e resultados das consultas do agente (ROADMAP 04) como JSON compacto. Volta como texto
  # comum: o ERB escapa (o conteúdo vem de fora).
  def agent_data_text(data) = JSON.generate(data)

  def timeline_bar_style(timeline, event)
    total = [ timeline.total_duration_ms.to_i, 1 ].max
    start = timeline.offset_ms(event) * 100.0 / total
    width = [ event.duration_ms.to_i * 100.0 / total, 0.4 ].max
    "--bar-start: #{start.round(2)}%; --bar-width: #{width.round(2)}%"
  end
end
