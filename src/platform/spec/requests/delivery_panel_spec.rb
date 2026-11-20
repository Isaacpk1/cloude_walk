require "rails_helper"

# ROADMAP 05, Frontend: a conversa mostra o status da entrega de cada saída e o turno distingue ação
# recebida, resposta aplicada e resposta entregue; a linha do tempo mostra a entrega ao canal. Registros
# no formato combinado do bloco 05 (spec/support/delivery_records.rb), com o tempo controlado.
RSpec.describe "ROADMAP 05: entrega no painel" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.zone.parse("2026-11-20 12:00:00") }

  before { travel_to(t0) }

  def applied_turn(text: "Seu repasse cai hoje até as 18h.")
    turn = open_turn_for(ingest("meu repasse não caiu"))
    travel_to(t0 + 3)
    turn.update_columns(created_at: Time.current)
    travel_to(t0 + 5)
    record_agent_action(turn, agent_action_payload(turn, text:), occurred_at: Time.current)
    travel_to(t0 + 6)
    [ turn, record_outbound(turn, text:) ]
  end

  def deliver(delivery)
    travel_to(t0 + 7)
    record_delivery_sending(delivery)
    travel_to(t0 + 8)
    record_delivery_delivered(delivery, duration_ms: 180, provider_message_id: "pmsg_0001")
  end

  def event_index(ticket_id, kind) = ConversationReader.timeline(ticket_id.to_s).events.index { _1.kind == kind } + 1

  describe "RF-06: status da entrega na conversa" do
    it "entregue: horário, provider_message_id e o turno que a produziu" do
      turn, delivery = applied_turn
      deliver(delivery)

      get conversation_path(turn.ticket_id)

      body = response.body
      expect(body).to include("seq 2", "Seu repasse cai hoje até as 18h.", "Entregue", "pmsg_0001",
                              "entregue às 20/11/2026 09:00:08", "Resposta do turno 1", delivery.delivery_id)
    end

    it "pendente, com a retentativa agendada" do
      turn, delivery = applied_turn
      record_delivery_sending(delivery)
      record_delivery_retry(delivery, error: "503 falha simulada", next_attempt_at: t0 + 9)

      get conversation_path(turn.ticket_id)

      expect(response.body).to include("Pendente", "nova tentativa às 20/11/2026 09:00:09", "503 falha simulada")
    end

    it "RNF-15: enviando, com o número de tentativas" do
      turn, delivery = applied_turn
      record_delivery_sending(delivery, attempt: 1)
      record_delivery_retry(delivery, attempt: 1)
      record_delivery_sending(delivery, attempt: 2)

      get conversation_path(turn.ticket_id)

      expect(response.body).to include("Enviando", "tentativa 2")
    end

    it "falhou: o motivo e o status HTTP" do
      turn, delivery = applied_turn
      record_delivery_failed(delivery, reason: "seq_anterior", http_status: 409)

      get conversation_path(turn.ticket_id)

      expect(response.body).to include("Falhou", "Provedor recusou: seq anterior", "HTTP 409")
    end

    it "conciliação pendente" do
      turn, delivery = applied_turn
      record_delivery_sending(delivery, attempt: 3)
      record_reconciliation_needed(delivery, attempts: 3)

      get conversation_path(turn.ticket_id)

      expect(response.body).to include("Conciliação pendente")
    end

    it "escapa o HTML do texto da saída" do
      turn, = applied_turn(text: "<script>alert('saida')</script>")

      get conversation_path(turn.ticket_id)

      expect(response.body).not_to include("<script>alert('saida')")
      expect(response.body).to include("&lt;script&gt;alert(&#39;saida&#39;)&lt;/script&gt;")
    end
  end

  describe "RNF-05: estágios do turno" do
    it "mostra ação recebida, resposta aplicada e resposta entregue, com durações e o tempo total percebido" do
      turn, delivery = applied_turn
      deliver(delivery)

      get conversation_path(turn.ticket_id)

      stages = Nokogiri::HTML(response.body).at_css(".turn-stages").text.squish
      expect(stages).to include("Ação recebida 20/11/2026 09:00:05 2000 ms desde a abertura do turno")
      expect(stages).to include("Resposta aplicada 20/11/2026 09:00:06 1000 ms desde a ação recebida")
      expect(stages).to include("Resposta entregue 20/11/2026 09:00:08 2000 ms desde a resposta aplicada")
      expect(stages).to include("Tempo total percebido 8000 ms", "inclui a janela de agrupamento")
    end

    it "RN-56: turno descartado não mostra os estágios aplicada e entregue" do
      turn = open_turn_for(ingest("meu repasse não caiu"))
      ingest("é o de ontem")
      turn.update_columns(status: "superseded")
      record_agent_action(turn, agent_action_payload(turn), rejected: "turno_superado", occurred_at: Time.current)

      get conversation_path(turn.ticket_id)

      stages = Nokogiri::HTML(response.body).at_css(".turn-stages").text.squish
      expect(stages).to include("Ação recebida", "Resposta descartada: não há resposta aplicada nem entrega")
      expect(stages).not_to include("Resposta entregue", "Tempo total percebido")
    end
  end

  describe "RF-55, RF-56: entrega na linha do tempo" do
    it "mostra os eventos de entrega com o seq da saída, o turno e a duração da chamada" do
      turn, delivery = applied_turn
      deliver(delivery)

      get timeline_path(turn.ticket_id)

      body = response.body
      expect(body).to include("Saída gravada para entrega", "Envio ao canal", "Entrega ao canal", "180 ms",
                              "seq 2 · turno 1", delivery.trace_id, "pmsg_0001")
    end

    it "ao escolher a falha, mostra a origem do erro, a resposta HTTP e a tentativa" do
      turn, delivery = applied_turn
      record_delivery_sending(delivery)
      record_delivery_failed(delivery, reason: "contrato", http_status: 422)

      get timeline_path(turn.ticket_id, evento: event_index(turn.ticket_id, :delivery_failed))

      selected = Nokogiri::HTML(response.body).at_css(".selected-event").text.squish
      expect(selected).to include("Evento escolhido: Falha na entrega", "Provedor recusou o conteúdo fora do contrato",
                                  "422", "Sem nova tentativa")
    end

    it "ao escolher a retentativa, mostra a próxima tentativa com o mesmo delivery_id" do
      turn, delivery = applied_turn
      record_delivery_sending(delivery)
      record_delivery_retry(delivery, error: "503 falha simulada", next_attempt_at: t0 + 9)

      get timeline_path(turn.ticket_id, evento: event_index(turn.ticket_id, :delivery_retry_scheduled))

      selected = Nokogiri::HTML(response.body).at_css(".selected-event").text.squish
      expect(selected).to include("Retentativa da entrega agendada", "Provedor: falha transitória", "503 falha simulada",
                                  "Nova tentativa às 20/11/2026 09:00:09.000, com o mesmo delivery_id")
    end
  end

  it "ROADMAP 05: no exemplo sintético, a resposta entregue continua marcada como sintética" do
    get conversation_path("exemplo-repasse")

    expect(response.body).to include("Entregue", "Exemplo sintético")
    expect(response.body).not_to include("Registro do sistema")
  end
end
