require "rails_helper"

# Bloco 07, "pronto quando": a resposta antiga que chega aos 3,5 s é rejeitada após o commit da mensagem 2,
# mesmo com o turno seguinte atrasado (07, seção 3.4, diagrama da corrida; RN-55, RN-56; RF-31, RF-54).
# Tudo pelo caminho real: ingestão, scheduler, Turns::Open, Outbox::Publish (broker simulado) e
# AgentActions::Apply. Ver spec/support/race_timeline.rb.
RSpec.describe "RN-56: a corrida dos 3 s com as peças reais" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  # O relógio do banco (condição 4) não anda com o travel_to: o cenário começa agora.
  let(:t0) { Time.current.utc.change(usec: 0) }

  before { stub_broker({ status: 200 }) }

  def rejections(ticket)
    AuditEvent.where(ticket_id: ticket.id, event_type: "agent_action.rejected").order(:id).map { _1.data.values_at("turn", "reason") }
  end

  describe "RN-56, RF-31: turno seguinte atrasado (o scheduler só volta aos 6 s)" do
    it "a resposta do turno 1 aos 3,5 s é rejeitada como turno_superado; o turno 2 sai aos 6 s com [1, 2] e é o único aplicado" do
      ticket = race_ingest_at(t0, "meu repasse não caiu").ticket
      turn1 = race_tick_at(t0 + 1.5.seconds).sole
      expect(turn1).to have_attributes(turn: 1, context_until_seq: 1, status: "eligible")
      expect(OutboxEvent.find(turn1.event_id).published_at).to be_present # aberto e publicado aos 1,5 s
      expect(broker_requests.size).to eq(1)

      race_ingest_at(t0 + 3.seconds, "é o de ontem, R$ 1.200")
      # O commit da mensagem 2 já superou o turno 1, sem turno 2 aberto.
      expect(turn1.reload.status).to eq("superseded")
      expect(AiTurn.where(ticket_id: ticket.id).count).to eq(1)

      late = race_reply(turn1, "Qual repasse?")
      result = race_apply_at(t0 + 3.5.seconds, late)

      expect(result).to have_attributes(status: :rejected, reason: "turno_superado")
      expect(outbound_messages(ticket)).to be_empty
      expect(Delivery.where(ticket_id: ticket.id)).to be_empty
      expect(rejections(ticket)).to eq([ [ 1, "turno_superado" ] ])
      rejected = AuditEvent.find_by!(ticket_id: ticket.id, event_type: "agent_action.rejected")
      expect(rejected).to have_attributes(agent_model: "mock-deterministico", agent_version: "0.3.0",
                                          trace_id: AgentActionHelpers::TRACE_ID)
      expect(rejected.data).to include("event_id" => late["event_id"], "turn_status" => "superseded",
                                       "reply" => { "text" => "Qual repasse?" })
      expect(turn1.reload).to have_attributes(status: "superseded", applied_event_id: nil)
      # A rejeição não mexe no ciclo pendente: a janela da mensagem 2 continua valendo (teto de 4 s).
      expect(ticket.reload).to have_attributes(first_pending_seq: 1, dispatch_due_at: t0 + 4.seconds)

      # Repetição: o Kafka reentrega a resposta velha. Nada muda.
      expect(race_apply_at(t0 + 3.6.seconds, late).status).to eq(:duplicate)
      expect(rejections(ticket).size).to eq(1)

      # O scheduler atrasa: nada roda entre 4 s e 6 s. Aos 6 s, o turno 2 sai com as duas mensagens.
      turn2 = race_tick_at(t0 + 6.seconds).sole
      expect(turn2).to have_attributes(turn: 2, context_until_seq: 2, status: "eligible")
      expect(pending_seqs_of(turn2)).to eq([ 1, 2 ])
      scheduled = AuditEvent.where(event_type: "turn.dispatch_scheduled", ticket_id: ticket.id).order(:id).last
      expect(scheduled.data).to include("cover_until_seq" => 2, "delay_ms" => 2000) # o atraso fica medido

      result2 = race_apply_at(t0 + 8.seconds, race_reply(turn2, "O repasse de ontem, R$ 1.200, cai hoje."))

      expect(result2.status).to eq(:applied)
      expect(turn2.reload.status).to eq("applied")
      expect(outbound_messages(ticket).pluck(:seq, :body)).to eq([ [ 3, "O repasse de ontem, R$ 1.200, cai hoje." ] ])
      expect(Delivery.where(ticket_id: ticket.id).count).to eq(1)
      expect(AiTurn.where(ticket_id: ticket.id).order(:turn).pluck(:turn, :status)).to eq([ [ 1, "superseded" ], [ 2, "applied" ] ])
    end
  end

  describe "RN-56: variante com o turno 2 já aberto quando a resposta do turno 1 chega" do
    it "a resposta do turno 1 é rejeitada como turno_superado e não impede a do turno 2" do
      ticket = race_ingest_at(t0, "meu repasse não caiu").ticket
      turn1 = race_tick_at(t0 + 1.5.seconds).sole
      race_ingest_at(t0 + 3.seconds, "é o de ontem, R$ 1.200")
      turn2 = race_tick_at(t0 + 4.seconds).sole
      expect(pending_seqs_of(turn2)).to eq([ 1, 2 ])

      result = race_apply_at(t0 + 4.2.seconds, race_reply(turn1, "Qual repasse?"))

      expect(result).to have_attributes(status: :rejected, reason: "turno_superado")
      expect(outbound_messages(ticket)).to be_empty
      expect(turn2.reload.status).to eq("eligible")

      expect(race_apply_at(t0 + 6.seconds, race_reply(turn2, "Cai hoje.")).status).to eq(:applied)
      expect(outbound_messages(ticket).count).to eq(1)
      expect(rejections(ticket)).to eq([ [ 1, "turno_superado" ] ])
    end
  end

  describe "RN-56, ADR-014: a resposta velha com a marca errada" do
    it "vai para a DLQ sem tocar o atendimento" do
      ticket = race_ingest_at(t0, "meu repasse não caiu").ticket
      turn1 = race_tick_at(t0 + 1.5.seconds).sole
      race_ingest_at(t0 + 3.seconds, "é o de ontem, R$ 1.200")
      create(:brand, :jim)

      result = race_apply_at(t0 + 3.5.seconds, race_reply(turn1, "Qual repasse?").merge("brand" => "jim"))

      expect(result).to have_attributes(status: :rejected, reason: "marca_divergente")
      expect(rejections(ticket)).to be_empty
      expect(outbound_messages(ticket)).to be_empty
      expect(dead_letters.size).to eq(1)
    end
  end
end
