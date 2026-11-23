require "rails_helper"

# V2 bloco 10, defeito: o aviso de progresso (RN-57) é gravado com author_type "bot" e o Handoff::Summarize o conta
# como resposta da IA. No timeout com o agente mudo (sempre há aviso aos 15 s), o resumo diz que a IA respondeu e que
# falta só "confirmar se a última resposta resolveu", quando o cliente nunca teve resposta (RN-39, campos 3 e 5).
RSpec.describe Handoff::Summarize, "RN-39: aviso de progresso não é resposta da IA no resumo (verificação do bloco 10)" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:t0) { Time.utc(2026, 11, 18, 21, 0, 0) }

  before { allow(DatabaseClock).to receive(:now) { Time.current } }

  it "timeout com aviso de progresso: ações tomadas sem resposta e pendente pede responder ao cliente" do
    ticket = travel_to(t0, with_usec: true) { ingest("meu repasse não caiu", identity: "acc_v210_prog") }.ticket.reload
    progress = travel_to(t0 + 15.seconds, with_usec: true) do
      Deadlines::ProgressDue.call(now: Time.current, limit: 100, ticket_ids: [ ticket.id ])
      OutboxEvent.find_by!(dedup_key: "progress:#{ticket.id}:#{ticket.reload.first_pending_seq}")
    end
    travel_to(t0 + 15.1.seconds, with_usec: true) { Turns::ProgressNotice.call(progress.id) }
    expect(Delivery.where(ticket_id: ticket.id, kind: "progress").count).to eq(1)
    # O aviso já chegou ao cliente (o caso do agente mudo: sai aos 15 s, o timeout vem aos ~22 s).
    Delivery.where(ticket_id: ticket.id, kind: "progress")
            .update_all(status: "delivered", provider_message_id: "chat_out_p", delivered_at: t0 + 15.2.seconds)

    travel_to(t0 + 21.seconds, with_usec: true) do
      Handoff::Escalate.call(request_handoff(ticket, reason: "prazo_do_turno", source: "scheduler"))
      Handoff::Summarize.call(OutboxEvent.find_by!(dedup_key: "summary:#{ticket.id}:0").id)
    end

    fields = HandoffSummary.find_by!(ticket_id: ticket.id).fields
    expect(fields["acoes_tomadas"]).not_to include("Respondeu ao cliente", "não entregue", "Ainda estou verificando")
    expect(fields["pendente"]).to start_with("Responder ao cliente")
  end
end
