# Por que uma etapa falhou e quem recusou (ROADMAP 03: "origem de um erro"). Vem da auditoria de cada
# tentativa de publicação (Outbox::Publish).
class TimelineView::Error < Data.define(:origin, :http_status, :message, :attempt, :retry, :next_attempt_at, :outcome)
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
    "atribuicao_mudou" => "Atendimento mudou de responsável desde o turno"
  }.freeze

  OUTCOMES = { "retentativas_esgotadas" => "Retentativas esgotadas (RN-43)",
               "prazo_vencido" => "Sem nova tentativa: passaria do prazo do turno (RN-46)" }.freeze

  def origin_label = ORIGINS.fetch(origin, origin)
  def outcome_label = outcome && OUTCOMES.fetch(outcome, outcome)
end
