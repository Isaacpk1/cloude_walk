# Por que uma etapa falhou e quem recusou (ROADMAP 03: "origem de um erro"). Vem da auditoria de cada
# tentativa de publicação (Outbox::Publish) e, no bloco 05, de cada tentativa de entrega ao canal.
# `retry_key` é a chave que a nova tentativa repete: event_id na publicação, delivery_id na entrega.
class TimelineView::Error < Data.define(:origin, :http_status, :message, :attempt, :retry, :next_attempt_at, :outcome,
                                        :retry_key)
  ORIGINS = {
    "kafka" => "Kafka: o broker não recebeu a confirmação da escrita",
    "broker_indisponivel" => "Broker fora do ar: sem resposta HTTP (conexão recusada ou timeout)",
    "broker_em_andamento" => "Broker: outra entrega do mesmo evento estava em andamento",
    "broker" => "Broker: erro na resposta HTTP",
    "assinatura" => "Assinatura HMAC recusada pelo broker (RNF-23)",
    "contrato" => "Contrato recusado pelo broker: o evento foi para a DLQ (RNF-28)",
    "plataforma" => "Plataforma: evento fora do contrato, nem saiu para o broker",
    "turno_superseded" => "Turno superado por mensagem nova do cliente (RN-56)",
    "turno_expired" => "Turno expirado",
    "turno_applied" => "Turno já respondido",
    "prazo_vencido" => "Prazo do atendimento vencido (RN-46)",
    "atribuicao_mudou" => "Atendimento mudou de responsável desde o turno",
    "provedor_transitorio" => "Provedor: falha transitória (5xx, timeout ou conexão)",
    "entrega_plataforma" => "Recusada pela plataforma antes do envio ao provedor",
    "conciliacao" => "Confirmação do provedor incerta: a entrega precisa de conciliação (07, seção 6)"
  }.freeze
  # Motivos da entrega (delivery.failed.reason). "assinatura" e "contrato" existem nas duas etapas com textos
  # diferentes: no erro da entrega (retry_key delivery_id) vale o da entrega; nas demais, o da publicação.
  DELIVERY_ORIGINS = ConversationView::DeliveryStatus::FAILURE_REASONS

  OUTCOMES = { "retentativas_esgotadas" => "Retentativas esgotadas (RN-43)",
               "prazo_vencido" => "Sem nova tentativa: passaria do prazo do turno (RN-46)",
               "conciliacao_pendente" => "Conciliação pendente: conferir no provedor antes de reenviar (07, seção 6)",
               "obsoleto" => "Encerrado pela política de recuperação: não volta a ser tentado (RF-34, RF-35)" }.freeze

  def initialize(retry_key: "event_id", **rest) = super

  def origin_label
    return DELIVERY_ORIGINS.fetch(origin) if retry_key == "delivery_id" && DELIVERY_ORIGINS.key?(origin)

    ORIGINS[origin] || DELIVERY_ORIGINS.fetch(origin, origin)
  end
  def outcome_label = outcome && OUTCOMES.fetch(outcome, outcome)
end
