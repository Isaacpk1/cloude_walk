require "rails_helper"

# ROADMAP 09, Frontend: tentativas e desfecho na linha do tempo, motivo da falha por etapa, entrega em
# conciliação na conversa e a DLQ (RF-37). Registros pelo caminho real (Outbox::Publish) ou no formato
# combinado (spec/support/delivery_records.rb e recovery_records.rb). Escape de HTML em tudo o que vem de fora.
RSpec.describe "ROADMAP 09: tentativas, conciliação e DLQ no painel" do
  let!(:brand) { create(:brand, :infinitepay) }
  let(:t0) { Time.zone.parse("2026-11-20 12:00:00") }

  before { travel_to(t0) }

  def opened_turn = open_turn_for(ingest("meu repasse não caiu"))
  def text_of(selector) = Nokogiri::HTML(response.body).css(selector).text.squish

  describe "RF-34: tentativas e desfecho na linha do tempo" do
    it "mostra o resumo N tentativas · desfecho e a lista das tentativas com erro e próxima tentativa" do
      turn = opened_turn
      turn.update_columns(deadline_at: t0 + 10.minutes)
      stub_broker({ status: 503 }, { status: 503 }, { status: 200 })
      3.times do
        travel_to(OutboxEvent.find(turn.event_id).next_attempt_at)
        Outbox::Publish.call(turn.event_id, jitter: -> { 0.0 })
      end

      get timeline_path(turn.ticket_id)

      attempts = text_of(".outbox-attempts")
      expect(attempts).to include("Publicação do turno 1", "3 tentativas · Publicado")
      expect(attempts).to include("Tentativa 1", "Falhou, nova tentativa agendada", "Kafka", "próxima às 20/11/2026 09:00:01")
      expect(attempts).to include("Tentativa 3", "Publicado")
    end

    it "ao escolher o resumo, o evento escolhido mostra a mesma lista" do
      turn = opened_turn
      record_outbox_recovered(OutboxEvent.find(turn.event_id))
      index = ConversationReader.timeline(turn.ticket_id.to_s).events.index { _1.kind == :outbox_item } + 1

      get timeline_path(turn.ticket_id, evento: index)

      expect(text_of(".selected-event")).to include("Tentativas e desfecho", "Reoferecido pela recuperação")
    end

    it "obsoleto: encerrado pela política de recuperação, com o motivo" do
      turn = opened_turn
      record_outbox_closed_obsolete(OutboxEvent.find(turn.event_id), reason: "turno_expired")

      get timeline_path(turn.ticket_id)

      expect(text_of(".outbox-attempts")).to include("Encerrado como obsoleto: Turno expirado")
    end
  end

  describe "RF-55: motivo da falha em cada etapa" do
    it "lista as cinco etapas, com a origem do erro e o link para o evento" do
      turn = opened_turn
      stub_request(:post, BrokerHelpers::BROKER_URL).to_raise(Errno::ECONNREFUSED)
      Outbox::Publish.call(turn.event_id)

      get timeline_path(turn.ticket_id)

      failures = text_of(".stage-failures")
      expect(failures).to include("Ingestão", "Publicação", "Agente", "Aplicação", "Entrega")
      expect(failures).to include("Broker fora do ar", "Sem falha registrada")
      index = ConversationReader.timeline(turn.ticket_id.to_s).events.index { _1.kind == :publish_failed } + 1
      expect(Nokogiri::HTML(response.body).css(".stage-failures a").map { _1["href"] })
        .to include(timeline_path(turn.ticket_id, evento: index))
    end
  end

  describe "07, seção 3.2: entrega em conciliação" do
    def reconciled(text: "Seu repasse cai hoje até as 18h.")
      turn = opened_turn
      record_agent_action(turn, agent_action_payload(turn, text:), occurred_at: Time.current)
      delivery = record_outbound(turn, text:)
      6.times { |i| record_delivery_sending(delivery, attempt: i + 1) }
      delivery.update_columns(lease_until: nil, last_error: "Net::ReadTimeout")
      record_reconciliation_needed(delivery, attempts: 6)
      [ turn, delivery ]
    end

    it "a conversa destaca a entrega com tentativas, último erro, delivery_id e o efeito na ordem" do
      turn, delivery = reconciled
      following = record_outbound(turn, text: "Mais alguma dúvida?")

      get conversation_path(turn.ticket_id)

      card = text_of(".reconciliation")
      expect(card).to include("Entrega em conciliação", "seq #{delivery.seq}", delivery.delivery_id, "6 tentativas",
                              "Net::ReadTimeout", "Saídas seguintes aguardam a conciliação: seq #{following.seq}")
    end

    it "sem saída seguinte, diz que a próxima saída vai esperar" do
      turn, = reconciled

      get conversation_path(turn.ticket_id)

      expect(text_of(".reconciliation")).to include("A próxima saída deste atendimento vai aguardar a conciliação")
    end

    it "a linha do tempo destaca a conciliação com o que se sabe" do
      turn, delivery = reconciled

      get timeline_path(turn.ticket_id)

      row = Nokogiri::HTML(response.body).at_css(".timeline__row--delivery_reconciliation")
      expect(row.text.squish).to include("resultado incerto após 6 tentativas", "último erro Net::ReadTimeout",
                                         "saídas seguintes aguardam a conciliação")
      expect(text_of(".outbox-attempts")).to include("Entrega da saída seq #{delivery.seq}", "Em conciliação")
    end

    it "entregue depois (callback do provedor): sai do destaque" do
      turn, delivery = reconciled
      record_delivery_delivered(delivery, attempt: 6)

      get conversation_path(turn.ticket_id)

      expect(response.body).not_to include("Entrega em conciliação")
    end
  end

  describe "RF-37: DLQ" do
    it "a navegação tem o link da DLQ" do
      get dead_letters_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(href="#{dead_letters_path}"))
    end

    it "a lista mostra quando, origem, motivo, event_id, atendimento, turno, marca e desfecho" do
      turn = opened_turn
      dead_letter = record_dead_letter(ticket: turn.ticket, turn:, outcome: "escalated")
      record_dead_letter(outcome: "uncorrelated", source: "agent-mock")

      get dead_letters_path

      rows = text_of(".dead-letters")
      expect(rows).to include("20/11/2026 09:00:00", "Broker (publicação para o agente)", "Fora do contrato",
                              dead_letter.event_id.first(8), "InfinitePay", "turno 1", "Escalou o atendimento",
                              "Agente (agent-mock)", "sem correlação")
      expect(response.body).to include(dead_letter_path(dead_letter.id), conversation_path(turn.ticket_id),
                                       "Reprocessamento: bloco seguinte")
    end

    it "lista vazia" do
      get dead_letters_path

      expect(response.body).to include("Nenhum evento na DLQ")
    end

    it "o detalhe mostra cabeçalhos, violações, corpo cru, links para a conversa, a linha do tempo e o turno" do
      turn = opened_turn
      dead_letter = record_dead_letter(ticket: turn.ticket, turn:, violations: [ "/turn", "/brand" ], error: "schema agent_inbound")

      get dead_letter_path(dead_letter.id)

      expect(response).to have_http_status(:ok)
      body = text_of(".dead-letter")
      expect(body).to include("dlq_reason", "/turn, /brand", "schema agent_inbound", dead_letter.event_id, dead_letter.trace_id,
                              "helpdesk.agent.dlq.v1", "partição 3", "Reprocessamento: bloco seguinte")
      expect(response.body).to include(conversation_path(turn.ticket_id), timeline_path(turn.ticket_id),
                                       conversation_path(turn.ticket_id, anchor: "turn-1"))
    end

    it "escapa o HTML do corpo cru e dos cabeçalhos, que vêm de fora" do
      dead_letter = record_dead_letter(payload: "<script>alert('dlq')</script>",
                                       headers: { "x" => "<img src=x onerror=alert(1)>" }, outcome: "uncorrelated")

      get dead_letter_path(dead_letter.id)

      expect(response.body).not_to include("<script>alert('dlq')", "<img src=x")
      expect(response.body).to include("&lt;script&gt;alert(&#39;dlq&#39;)&lt;/script&gt;", "&lt;img src=x")
    end

    it "corpo com \\u0000 escrito no JSON aparece como texto" do
      dead_letter = record_dead_letter(payload: '{"text": "a\u0000b"}', outcome: "uncorrelated")

      get dead_letter_path(dead_letter.id)

      expect(text_of(".dead-letter__payload")).to eq('{"text": "a\u0000b"}')
    end

    it "sem correlação: marcado, sem link para conversa" do
      dead_letter = record_dead_letter(outcome: "uncorrelated")

      get dead_letter_path(dead_letter.id)

      expect(text_of(".dead-letter")).to include("Sem correlação")
      expect(response.body).not_to include(%(href="/conversas/))
    end

    it "invariante 6: ?marca= filtra a lista e o detalhe de outra marca é 404" do
      create(:brand, :jim)
      turn = opened_turn
      mine = record_dead_letter(ticket: turn.ticket, turn:)
      jim_turn = open_turn_for(ingest(brand: "jim"))
      theirs = record_dead_letter(ticket: jim_turn.ticket, turn: jim_turn)
      uncorrelated = record_dead_letter(outcome: "uncorrelated")

      get dead_letters_path(marca: "infinitepay")
      expect(response.body).to include(dead_letter_path(mine.id, marca: "infinitepay"))
      expect(response.body).not_to include(dead_letter_path(theirs.id), dead_letter_path(uncorrelated.id))

      get dead_letter_path(theirs.id, marca: "infinitepay")
      expect(response).to have_http_status(:not_found)

      get dead_letter_path(uncorrelated.id, marca: "infinitepay")
      expect(response).to have_http_status(:not_found)
    end

    it "404 para id inexistente e marca inexistente" do
      get dead_letter_path(999_999)
      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("Evento da DLQ não encontrado")

      get dead_letters_path(marca: "nao-existe")
      expect(response).to have_http_status(:not_found)
    end

    it "RN-45: a linha do tempo mostra o evento DLQ com o desfecho e o link para o registro" do
      turn = opened_turn
      dead_letter = record_dead_letter(ticket: turn.ticket, turn:, outcome: "audited", source: "platform")

      get timeline_path(turn.ticket_id)

      row = Nokogiri::HTML(response.body).at_css(".timeline__row--dead_letter")
      expect(row.text.squish).to include("DLQ", "Plataforma (aplicação da ação do agente)", "Só auditado")
      expect(row.at_css("a[href='#{dead_letter_path(dead_letter.id)}']")).to be_present
    end
  end
end
