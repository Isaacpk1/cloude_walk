require "rails_helper"

# Painel do bloco 08 (ROADMAP 08 Frontend: "mostrar o prazo do atendimento, o aviso de progresso e o motivo do timeout";
# RN-46, RN-57, RF-36, RF-55, RF-56, RNF-18). Registros no formato combinado dos blocos 08 e 09
# (spec/support/handoff_records.rb), lidos pelas telas de conversa e de linha do tempo.
RSpec.describe "RN-46, RN-57, RF-36, RF-55, RF-56: prazo, aviso de progresso e motivo do timeout no painel" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim) }
  let(:t0) { Time.utc(2026, 11, 21, 13, 40, 0) }
  let!(:ticket) { at(t0) { ingest("meu repasse não caiu").ticket.tap { record_progress_due(_1) } } }

  before { default_queue_for(infinitepay, name: "Suporte InfinitePay") }

  def at(time, &) = travel_to(time, with_usec: true, &)

  def page(path, time)
    at(time) { get path }
    expect(response).to have_http_status(:ok)
    response.body
  end

  def section(body, css) = body[/<section class="card #{css}[" ].*?<\/section>/m]
  def deadlines(time) = section(page(conversation_path(ticket.id), time), "deadlines")
  def handoff(time) = section(page(conversation_path(ticket.id), time), "handoff")

  def escalate_by_turn_timeout
    turn = at(t0 + 1.5.seconds) { record_turn_06(ticket) }
    request = at(t0 + 21.7.seconds) do
      record_timeout_scheduled(ticket, scope: :turn, turn:)
      record_turn_expired(turn)
      record_handoff_requested(ticket, reason: "prazo_do_turno", source: "scheduler", turn:)
    end
    at(t0 + 22.seconds) { record_escalated(ticket, request) }
  end

  describe "RN-46, RN-57: prazos do atendimento com o ciclo pendente" do
    it "mostra o teto do ciclo e quanto falta, o prazo do turno e o aviso previsto, no fuso do painel" do
      at(t0 + 1.5.seconds) { record_turn_06(ticket) }
      block = deadlines(t0 + 5.seconds)

      expect(block).to include("Prazos do atendimento", "Teto do ciclo", "21/11/2026 10:41:00.000", "faltam 55,0 s",
                               "Prazo do turno 1", "21/11/2026 10:40:21.500", "faltam 16,5 s",
                               "Aviso de progresso", "Previsto", "21/11/2026 10:40:15.000")
      expect(block).not_to match(/>[^<]*13:41:00/)
    end

    it "tempo no limite: o teto vencido aparece como vencido" do
      expect(deadlines(t0 + 61.seconds)).to include("vencido há 1,0 s")
    end

    it "aviso enviado: a entrega kind progress e o status dela" do
      delivery = at(t0 + 15.3.seconds) { record_progress_sent(ticket) }
      at(t0 + 15.5.seconds) { record_delivery_delivered(delivery) }

      expect(deadlines(t0 + 16.seconds)).to include("Enviado", "seq 2", delivery.delivery_id.first(8), "Entregue")
    end

    it "aviso cancelado pela resposta aplicada: o bloco mostra o aviso do último ciclo com o motivo" do
      delivery = at(t0 + 15.3.seconds) { record_progress_sent(ticket) }
      at(t0 + 15.4.seconds) do
        record_delivery_cancelled(delivery, reason: "resposta_aplicada")
        close_cycle(ticket)
      end

      block = deadlines(t0 + 16.seconds)
      expect(block).to include("Ciclo encerrado", "Cancelado", "a resposta da IA foi aplicada antes do envio do aviso")
      expect(block).not_to include("Teto do ciclo")
    end

    it "aviso descartado: mostra o motivo" do
      at(t0 + 15.2.seconds) { record_progress_scheduled(ticket) }
      at(t0 + 15.3.seconds) { record_progress_discarded(ticket, reason: "ciclo_encerrado") }

      expect(deadlines(t0 + 16.seconds)).to include("Descartado", "o ciclo já tinha sido encerrado quando o aviso venceu")
    end
  end

  describe "RN-46, RF-36: motivo do timeout e do handoff" do
    it "timeout do turno: na fila humana com a fila, o motivo, o gatilho e as saídas canceladas" do
      progress = at(t0 + 15.3.seconds) { record_progress_sent(ticket) }
      escalate_by_turn_timeout
      body = page(conversation_path(ticket.id), t0 + 23.seconds)

      expect(section(body, "deadlines")).to be_nil
      expect(section(body, "handoff")).to include(
        "Na fila humana: Suporte InfinitePay", "Prazo do turno vencido (20 s desde a abertura, RN-46)",
        "Scheduler: prazo vencido no Postgres (ADR-016)", "turno 1", "assignment_version 0 → 1",
        "22000 ms desde a primeira mensagem pendente", "seq 2", progress.delivery_id.first(8), "progress"
      )
      expect(body).to include("Suporte InfinitePay", "Fila")
      expect(body).not_to include("Nenhuma escalação")
    end

    it "teto do ciclo vencido sem turno publicado" do
      request = at(t0 + 60.1.seconds) do
        record_timeout_scheduled(ticket, scope: :cycle)
        record_handoff_requested(ticket, reason: "teto_do_ciclo", source: "scheduler")
      end
      at(t0 + 60.3.seconds) { record_escalated(ticket, request) }

      expect(handoff(t0 + 61.seconds)).to include("Na fila humana", "Teto do ciclo vencido (60 s desde a primeira mensagem pendente, RN-46)",
                                                  "60300 ms")
    end

    it "publicação falhou de forma definitiva: gatilho do outbox" do
      turn = at(t0 + 1.5.seconds) { record_turn_06(ticket) }
      request = at(t0 + 2.seconds) { record_handoff_requested(ticket, reason: "publicacao_falhou", source: "outbox", turn:) }
      at(t0 + 2.2.seconds) { record_escalated(ticket, request) }

      expect(handoff(t0 + 3.seconds)).to include("Publicação do turno falhou de forma definitiva (RN-46)",
                                                 "Outbox: publicação para o agente")
    end

    it "handoff descartado: o motivo do descarte e o pedido" do
      request = at(t0 + 60.1.seconds) { record_handoff_requested(ticket, reason: "teto_do_ciclo", source: "scheduler") }
      at(t0 + 60.2.seconds) { record_handoff_discarded(ticket, request, reason: "atribuicao_mudou") }

      expect(handoff(t0 + 61.seconds)).to include("Pedido de handoff descartado", "o atendimento mudou de responsável desde o pedido",
                                                  "Teto do ciclo vencido")
    end

    it "RN-49: a recusa com pedido de handoff troca o 'handoff pendente (bloco 10)' pelo motivo pedido" do
      at(t0 + 2.seconds) do
        record_context_too_large(ticket, pending_chars: 18_000)
        record_handoff_requested(ticket, reason: "contexto_excede_limite", source: "turns")
      end
      body = page(conversation_path(ticket.id), t0 + 3.seconds)

      expect(section(body, "turn-refusal")).to include("handoff pedido (Contexto excede o limite do turno (RN-49))")
      expect(section(body, "turn-refusal")).not_to include("handoff pendente (bloco 10)")
      expect(page(timeline_path(ticket.id), t0 + 3.seconds)).to include("handoff para humano pedido: Contexto excede o limite")
    end

    it "RN-49: a recusa sem pedido de handoff mantém o 'handoff pendente (bloco 10)'" do
      at(t0 + 2.seconds) { record_context_too_large(ticket, pending_chars: 18_000) }

      expect(section(page(conversation_path(ticket.id), t0 + 3.seconds), "turn-refusal")).to include("handoff pendente (bloco 10)")
    end
  end

  describe "RF-55, RF-56, RNF-18: linha do tempo" do
    it "mostra todos os eventos do bloco 08 e a duração até a fila humana" do
      at(t0 + 15.2.seconds) { record_progress_scheduled(ticket) }
      at(t0 + 15.3.seconds) { record_progress_sent(ticket) }
      escalate_by_turn_timeout
      body = page(timeline_path(ticket.id), t0 + 23.seconds)

      expect(body).to include("Aviso de progresso agendado", "Aviso de progresso enviado", "Prazo vencido registrado pelo scheduler",
                              "Turno expirado", "Pedido de handoff", "Escalado para humano", "22000 ms")
    end

    it "ao escolher o evento, o detalhe mostra o gatilho, o motivo e o desfecho" do
      escalate_by_turn_timeout
      timeline = ConversationReader.timeline(ticket.id.to_s)
      position = timeline.events.index { _1.kind == :handoff_requested } + 1
      body = page(timeline_path(ticket.id, evento: position), t0 + 23.seconds)
      selected = body[/<section class="selected-event".*?<\/section>/m]

      expect(selected).to include("Evento escolhido: Pedido de handoff", "Gatilho", "Scheduler: prazo vencido no Postgres (ADR-016)",
                                  "Motivo", "Prazo do turno vencido (20 s desde a abertura, RN-46)", "Desfecho",
                                  "Escalado para humano em 300 ms")
      expect(selected).not_to include("Sem erro registrado")
    end

    it "aviso descartado na linha do tempo com o motivo" do
      at(t0 + 15.2.seconds) { record_progress_scheduled(ticket) }
      at(t0 + 15.3.seconds) { record_progress_discarded(ticket, reason: "resposta_aplicada") }

      expect(page(timeline_path(ticket.id), t0 + 16.seconds)).to include("Aviso de progresso descartado",
                                                                         "a resposta da IA foi aplicada antes do envio do aviso")
    end
  end

  describe "invariante 6 e escape" do
    it "marca errada: o handoff e o aviso de outra marca não aparecem" do
      other = at(t0) { ingest("oi da JIM", brand: "jim", identity: "acc_jim_000021").ticket.tap { record_progress_due(_1) } }
      default_queue_for(jim, name: "Suporte JIM")
      at(t0 + 15.3.seconds) { record_progress_sent(other) }
      request = at(t0 + 60.1.seconds) { record_handoff_requested(other, reason: "teto_do_ciclo", source: "scheduler") }
      at(t0 + 60.2.seconds) { record_escalated(other, request) }

      body = page(conversation_path(ticket.id), t0 + 61.seconds)
      expect(section(body, "handoff")).to be_nil
      expect(body).not_to include("Suporte JIM")
      expect(section(body, "deadlines")).not_to include("Enviado")
      expect(page(timeline_path(ticket.id), t0 + 61.seconds)).not_to include("Pedido de handoff", "Aviso de progresso enviado")
    end

    it "escapa motivos e nomes gravados (fila, motivo do descarte e do aviso)" do
      HelpdeskQueue.find_by(brand_id: infinitepay.id).publish_version!(name: "<b>Fila</b>", created_by: nil)
      request = at(t0 + 60.1.seconds) { record_handoff_requested(ticket, reason: "<script>x</script>", source: "<i>s</i>") }
      at(t0 + 60.2.seconds) { record_escalated(ticket, request) }
      at(t0 + 61.seconds) { record_handoff_discarded(ticket, request, reason: "<img src=x>") }

      body = page(conversation_path(ticket.id), t0 + 62.seconds)
      timeline = page(timeline_path(ticket.id), t0 + 62.seconds)
      [ body, timeline ].each do |html|
        expect(html).not_to include("<script>x</script>", "<b>Fila</b>", "<i>s</i>", "<img src=x>")
      end
      expect(body).to include("&lt;b&gt;Fila&lt;/b&gt;", "&lt;script&gt;x&lt;/script&gt;")
    end

    it "sintéticos continuam marcados como exemplo" do
      expect(page(conversations_path, t0 + 1.second)).to include("Exemplo sintético", "Registro do sistema")
    end
  end
end
