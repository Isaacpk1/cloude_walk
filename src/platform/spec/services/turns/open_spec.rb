require "rails_helper"

RSpec.describe Turns::Open, "RF-29, RF-33, RN-55, ADR-016: abertura do turno pela ação turn.dispatch do scheduler" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "pt-BR") }
  let(:start) { Time.zone.parse("2026-11-18T21:00:00Z") }

  around { |example| travel_to(start) { example.run } }

  def open_for(received) = described_class.call(due_dispatch(received).id)
  def last_audit(ticket) = ticket.audit_events.reload.last

  describe "caminho feliz" do
    it "RN-55: abre com todas as mensagens pendentes, o prazo do atendimento e zera dispatch_due_at, na mesma transação" do
      ingest("meu repasse não caiu", trace_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      travel 1.second
      second = ingest("é o de ontem, R$ 1.200", trace_id: "4bf92f3577b34da6a3ce929d0e0e4736")
      ticket = start_cycle(second.ticket, dispatch_due_at: start + 2.5.seconds, ai_deadline_at: start + 60.seconds)
      travel_to(start + 2.5.seconds, with_usec: true)
      item = create(:turn_dispatch, for_ticket: ticket)

      result = described_class.call(item.id)

      turn = result.turn
      expect(result.status).to eq(:opened)
      expect(turn).to have_attributes(turn: 1, status: "eligible", context_until_seq: 2, assignment_version: 0,
                                      brand_id: infinitepay.id, ticket_id: ticket.id, deadline_at: start + 22.5.seconds)
      payload = OutboxEvent.find(turn.event_id).payload
      expect(payload.dig("context", "pending_messages")).to eq([ { "seq" => 1, "text" => "meu repasse não caiu" },
                                                                 { "seq" => 2, "text" => "é o de ontem, R$ 1.200" } ])
      expect(payload["deadline_at"]).to eq((start + 22.5.seconds).utc.iso8601(3))
      expect(OutboxEvent.find(turn.event_id)).to have_attributes(event_type: "agent.event", completed_at: nil, attempts: 0,
                                                                 trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
                                                                 next_attempt_at: Time.current)
      expect(item.reload.completed_at).to eq(Time.current)
      expect(ticket.reload).to have_attributes(dispatch_due_at: nil, first_pending_seq: 1, ai_deadline_at: start + 60.seconds)
    end

    it "RNF-28: o evento sai dentro do contrato agent_inbound, com o event_id igual ao id do outbox" do
      received = ingest
      turn = open_for(received).turn

      payload = OutboxEvent.find(turn.event_id).payload

      expect(HelpdeskContracts.errors(:agent_inbound, payload)).to be_empty
      expect(payload).to include(
        "schema" => "helpdesk.agent_event.v1", "event_id" => turn.event_id,
        "event_type" => "message.created", "conversation_id" => "tkt_#{received.ticket.id}", "brand" => "infinitepay",
        "locale" => "pt-BR", "turn" => 1, "context_until_seq" => 1, "assignment_version" => 0,
        "occurred_at" => start.utc.iso8601(3)
      )
      # Bloco 11: o Open faz a triagem do caso novo antes do turno; o evento já leva o estado e a classificação.
      expect(payload["ticket"]).to eq("state" => "com_ia", "channel" => "chat", "ai_turns" => 0, "category" => "repasses",
                                      "priority" => "alta")
      expect(payload["customer"]).to include("id" => "cus_#{received.ticket.customer_id}", "verified" => false)
      expect(payload["message"]).to eq("id" => "msg_#{received.message.id}", "seq" => 1, "text" => "meu repasse não caiu")
    end

    it "RN-46, ADR-020: cada turno tem 20 s desde a abertura; o teto do ciclo não reinicia" do
      first = ingest("meu repasse não caiu")
      first_turn = open_for(first).turn
      travel 20.seconds
      second_turn = open_for(ingest("é o de ontem")).turn

      expect(first_turn.deadline_at).to eq(start + 20.seconds)
      expect(second_turn).to have_attributes(turn: 2, context_until_seq: 2, deadline_at: start + 40.seconds)
      expect(OutboxEvent.find(second_turn.event_id).payload["deadline_at"]).to eq((start + 40.seconds).utc.iso8601(3))
      expect(first.ticket.reload.ai_deadline_at).to eq(start + 60.seconds)
    end

    it "ADR-020: turno aberto perto do teto do ciclo vale só até o teto (tempo no limite)" do
      received = ingest("meu repasse não caiu")
      travel 50.seconds
      turn = open_for(received).turn

      expect(turn.deadline_at).to eq(start + 60.seconds)
    end

    it "RF-54, RF-56: audita a abertura com o trace_id da ação e o fim da janela" do
      received = ingest(trace_id: "4bf92f3577b34da6a3ce929d0e0e4736")
      item = due_dispatch(received)
      turn = described_class.call(item.id).turn

      audit = received.ticket.audit_events.find_by!(event_type: "ai_turn.opened")
      expect(audit).to have_attributes(trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", brand_id: infinitepay.id,
                                       actor_type: "system")
      expect(audit.data).to include("turn" => 1, "event_id" => turn.event_id, "context_until_seq" => 1,
                                    "pending_seqs" => [ 1 ], "dispatch_id" => item.id, "cover_until_seq" => 1,
                                    "dispatch_due_at" => start.utc.iso8601(3))
    end
  end

  describe "repetição" do
    it "RNF-15: processar a mesma ação de novo não abre outro turno nem outro evento" do
      item = due_dispatch(ingest)
      described_class.call(item.id)

      again = described_class.call(item.id)

      expect(again.status).to eq(:already_done)
      expect(AiTurn.count).to eq(1)
      expect(OutboxEvent.where(event_type: "agent.event").count).to eq(1)
    end
  end

  describe "ordem: job de versão anterior (07, seção 3.4)" do
    it "RN-55: a ação da mensagem 1 chega com a janela da mensagem 2 aberta e é descartada, preservando a janela" do
      first = ingest("meu repasse não caiu")
      old_item = due_dispatch(first)
      travel 1.second
      second = ingest("é o de ontem")
      window = start + 2.5.seconds
      start_cycle(second.ticket, dispatch_due_at: window)

      result = described_class.call(old_item.id)

      expect(result.status).to eq(:window_open)
      expect(AiTurn.count).to eq(0)
      expect(old_item.reload.completed_at).to eq(Time.current)
      expect(second.ticket.reload.dispatch_due_at).to eq(window)
      expect(last_audit(second.ticket)).to have_attributes(event_type: "ai_turn.not_opened")
      expect(last_audit(second.ticket).data).to include("reason" => "janela_aberta", "dispatch_id" => old_item.id,
                                                        "dispatch_due_at" => window.utc.iso8601(3))
    end

    it "RN-55: a ação antiga com o teto de 4 s já vencido abre um turno que cobre a mensagem nova" do
      first = ingest("meu repasse não caiu")
      old_item = due_dispatch(first)
      travel 4.seconds
      start_cycle(ingest("é o de ontem").ticket, dispatch_due_at: start + 4.seconds)

      result = described_class.call(old_item.id)

      expect(result.turn).to have_attributes(turn: 1, context_until_seq: 2)
    end

    it "sem janela pendente (dispatch_due_at nulo) a ação é descartada" do
      received = ingest
      item = due_dispatch(received)
      received.ticket.update_columns(dispatch_due_at: nil)

      expect(described_class.call(item.id).status).to eq(:no_window)
      expect(last_audit(received.ticket).data).to include("reason" => "sem_janela")
    end

    it "RN-56: turno elegível já cobre a última mensagem: a ação é descartada como coberta" do
      received = ingest
      turn = open_for(received).turn
      duplicate = create(:turn_dispatch, for_ticket: received.ticket.reload, dedup_key: "outra-chave")

      result = described_class.call(duplicate.id)

      expect(result.status).to eq(:covered)
      expect(AiTurn.count).to eq(1)
      expect(duplicate.reload.completed_at).to be_present
      expect(last_audit(received.ticket).data).to include("reason" => "coberto", "covered_by_turn" => turn.turn)
    end

    it "RN-55: coberto zera um dispatch_due_at que tenha ficado; só uma mensagem nova pede outro turno" do
      received = ingest
      open_for(received)
      received.ticket.update_columns(dispatch_due_at: start)
      duplicate = create(:turn_dispatch, for_ticket: received.ticket.reload, dedup_key: "outra-chave")

      expect(described_class.call(duplicate.id).status).to eq(:covered)
      expect(received.ticket.reload.dispatch_due_at).to be_nil
      expect(Deadlines::DispatchDue.call(now: start + 30.seconds, limit: 10)).to be_empty
    end
  end

  describe "atribuição" do
    it "invariante 4: assignment_version mudou depois da ação: descarta com atribuicao_mudou" do
      received = ingest
      item = due_dispatch(received)
      received.ticket.update_columns(assignment_version: 1)

      result = described_class.call(item.id)

      expect(result.status).to eq(:stale_assignment)
      expect(AiTurn.count).to eq(0)
      expect(item.reload.completed_at).to be_present
      expect(last_audit(received.ticket).data).to include("reason" => "atribuicao_mudou", "expected_version" => 0,
                                                          "current_version" => 1)
    end

    it "invariante 4: atribuicao_mudou com o caso ainda na IA mantém dispatch_due_at; a volta seguinte abre na versão nova" do
      received = ingest
      item = due_dispatch(received)
      received.ticket.update_columns(assignment_version: 1)

      expect(described_class.call(item.id).status).to eq(:stale_assignment)
      expect(received.ticket.reload.dispatch_due_at).to be_present

      ids = Deadlines::DispatchDue.call(now: Time.current, limit: 10)
      result = described_class.call(ids.sole)
      expect(result.status).to eq(:opened)
      expect(result.turn).to have_attributes(assignment_version: 1, context_until_seq: 1)
    end

    it "07, seção 3.3: caso com analista não abre turno; a ação é encerrada com auditoria" do
      received = ingest
      item = due_dispatch(received)
      received.ticket.update!(state: "com_analista", assignee: create(:user))

      result = described_class.call(item.id)

      expect(result.status).to eq(:skipped)
      expect(AiTurn.count).to eq(0)
      expect(item.reload.completed_at).to be_present
      expect(last_audit(received.ticket).data).to include("reason" => "fora_da_ia", "state" => "com_analista")
    end

    it "07, seção 3.3: fora_da_ia zera dispatch_due_at; o scheduler não volta a esse atendimento" do
      received = ingest
      item = due_dispatch(received)
      received.ticket.update!(state: "com_analista", assignee: create(:user))

      expect(described_class.call(item.id).status).to eq(:skipped)
      expect(received.ticket.reload.dispatch_due_at).to be_nil
      expect(Deadlines::DispatchDue.call(now: Time.current + 30.seconds, limit: 10)).to be_empty
    end
  end

  describe "marca errada" do
    it "ADR-014, invariante 6: o turno, o evento e a auditoria ficam na marca do atendimento, só com as mensagens dele" do
      ingest("mensagem da InfinitePay", identity: "acc_compartilhada")
      jim_received = ingest("mensagem da JIM", brand: "jim", identity: "acc_compartilhada")

      payload = OutboxEvent.find(open_for(jim_received).turn.event_id).payload

      expect(payload["brand"]).to eq("jim")
      expect(payload.dig("context", "pending_messages").map { _1["text"] }).to eq([ "mensagem da JIM" ])
      expect(AiTurn.sole.brand_id).to eq(jim.id)
      expect(OutboxEvent.where(event_type: %w[turn.dispatch agent.event]).pluck(:brand_id).uniq).to eq([ jim.id ])
      expect(AuditEvent.where(event_type: "ai_turn.opened").pluck(:brand_id)).to eq([ jim.id ])
    end
  end

  describe "invariante 10: contrato na saída" do
    it "evento que sairia fora do contrato não abre turno, encerra a ação sem retentativa e audita as violações" do
      item = due_dispatch(received = ingest)
      allow_any_instance_of(Turns::Envelope).to receive(:to_h).and_wrap_original { |m| m.call.except("turn") }

      result = described_class.call(item.id)

      expect(result.status).to eq(:invalid)
      expect(AiTurn.count).to eq(0)
      expect(OutboxEvent.where(event_type: "agent.event")).to be_empty
      expect(item.reload.completed_at).to be_present
      expect(last_audit(received.ticket).data).to include("reason" => "contrato", "violations" => [ "/turn" ])
    end

    it "RN-46: contrato inválido é recusa terminal: zera dispatch_due_at e o scheduler não repete" do
      item = due_dispatch(received = ingest)
      allow_any_instance_of(Turns::Envelope).to receive(:to_h).and_wrap_original { |m| m.call.except("turn") }

      expect(described_class.call(item.id).status).to eq(:invalid)
      expect(received.ticket.reload).to have_attributes(dispatch_due_at: nil, first_pending_seq: 1)
      expect(Deadlines::DispatchDue.call(now: Time.current + 30.seconds, limit: 10)).to be_empty
      expect(described_class::TERMINAL_REASONS).to include("contrato")
    end
  end

  describe "tempo no limite (RN-46, RN-55)" do
    it "abre o turno a 1 ms do prazo" do
      item = due_dispatch(ingest)
      travel_to(start + 60.seconds - 0.001, with_usec: true)

      expect(described_class.call(item.id).status).to eq(:opened)
    end

    it "não abre o turno exatamente no prazo: o caso segue pelo timeout (bloco 08)" do
      received = ingest
      item = due_dispatch(received)
      travel_to(start + 60.seconds)

      result = described_class.call(item.id)

      expect(result.status).to eq(:expired)
      expect(AiTurn.count).to eq(0)
      # Recusa terminal do ciclo: dispatch_due_at zera (o scheduler não tem o que reemitir); o ciclo fica para o timeout.
      expect(received.ticket.reload).to have_attributes(dispatch_due_at: nil, first_pending_seq: 1,
                                                        ai_deadline_at: start + 60.seconds)
      expect(last_audit(received.ticket).data).to include("reason" => "prazo_vencido",
                                                          "deadline_at" => (start + 60.seconds).utc.iso8601(3))
    end

    it "sem prazo do ciclo (ai_deadline_at nulo) também é terminal: zera dispatch_due_at" do
      received = ingest
      item = due_dispatch(received)
      received.ticket.update_columns(ai_deadline_at: nil)

      expect(described_class.call(item.id).status).to eq(:expired)
      expect(received.ticket.reload.dispatch_due_at).to be_nil
      expect(last_audit(received.ticket).data).to include("reason" => "sem_prazo")
    end

    it "abre exatamente no fim da janela (dispatch_due_at == agora)" do
      received = ingest
      start_cycle(received.ticket, dispatch_due_at: start + 1.5.seconds)
      travel_to(start + 1.5.seconds, with_usec: true)

      expect(described_class.call(create(:turn_dispatch, for_ticket: received.ticket.reload).id).status).to eq(:opened)
    end

    it "1 ms antes do fim da janela a ação é descartada (janela aberta)" do
      received = ingest
      start_cycle(received.ticket, dispatch_due_at: start + 1.5.seconds)
      item = create(:turn_dispatch, for_ticket: received.ticket.reload)
      travel_to(start + 1.5.seconds - 0.001, with_usec: true)

      expect(described_class.call(item.id).status).to eq(:window_open)
    end
  end

  describe "concorrência", :concurrency do
    it "dois workers com a mesma ação abrem um turno só" do
      item_id = due_dispatch(ingest).id

      results = run_concurrently(threads: 2) { described_class.call(item_id) }

      expect(results.map(&:status)).to contain_exactly(:opened, :already_done)
      expect(AiTurn.count).to eq(1)
      expect(OutboxEvent.where(event_type: "agent.event").count).to eq(1)
    end

    it "ações de duas versões da mesma conversa, juntas, abrem um turno que cobre as duas mensagens" do
      first = ingest("um")
      old_id = due_dispatch(first).id
      new_id = due_dispatch(ingest("dois")).id

      results = run_concurrently(threads: 2) { |i| described_class.call([ old_id, new_id ][i]) }

      expect(results).to all(be_a(Turns::Open::Result))
      expect(results.map(&:status)).to contain_exactly(:opened, :covered)
      expect(AiTurn.sole).to have_attributes(turn: 1, context_until_seq: 2)
    end
  end
end
