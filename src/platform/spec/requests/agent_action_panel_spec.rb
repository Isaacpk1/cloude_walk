require "rails_helper"

# ROADMAP 04, "pronto quando": é possível abrir o turno e conferir as mensagens enviadas e a ação
# resultante. Registros no formato combinado do bloco 04, gravados direto pelo helper.
RSpec.describe "ROADMAP 04: ação do agente no painel" do
  let!(:brand) { create(:brand, :infinitepay) }

  def applied_turn(text: "Seu repasse cai hoje até as 18h.")
    turn = open_turn_for(ingest("meu repasse não caiu"))
    record_agent_action(turn, agent_action_payload(turn, text:, agent_ms: 2_345))
    turn
  end

  def rejected_turn
    turn = open_turn_for(ingest("meu repasse não caiu"))
    ingest("é o de ontem")
    turn.update_columns(status: "superseded")
    record_agent_action(turn, agent_action_payload(turn), rejected: "turno_superado")
    turn
  end

  describe "RF-31, RF-32, RN-37: ação do agente no turno (conversa)" do
    it "mostra as mensagens do turno, a ação, a consulta com argumentos, resultado e duração, o agente e o desfecho" do
      turn = applied_turn

      get conversation_path(turn.ticket_id)

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("Ação recebida", "Resposta ao cliente", "Seu repasse cai hoje até as 18h.")
      expect(body).to include("consultar_repasse", "120 ms", "periodo", "ontem", "programado")
      expect(body).to include("mock-deterministico", "0.3.0", "sha256:9f2c4", "2345 ms", "Aplicada")
      expect(body).to include("seq 1</a>: meu repasse não caiu")
    end

    it "RN-56: mostra a resposta descartada com o motivo" do
      turn = rejected_turn

      get conversation_path(turn.ticket_id)

      expect(response.body).to include("Descartada", "Turno superado por mensagem nova do cliente")
    end

    it "turno sem resposta diz que aguarda o agente" do
      turn = open_turn_for(ingest("meu repasse não caiu"))

      get conversation_path(turn.ticket_id)

      expect(response.body).to include("Aguardando resposta do agente")
    end

    it "escalate mostra o motivo e o resumo do handoff (RN-39)" do
      turn = open_turn_for(ingest("cobraram duas vezes"))
      record_agent_action(turn, agent_action_payload(turn, action: "escalate"))

      get conversation_path(turn.ticket_id)

      expect(response.body).to include("Escalação para humano", "contestacao_de_cobranca", "Cobrança em duplicidade",
                                       "abrir contestação")
    end

    it "escapa o HTML vindo do agente no texto da resposta e no resultado da consulta" do
      turn = open_turn_for(ingest("meu repasse não caiu"))
      payload = agent_action_payload(turn, text: "<script>alert('x')</script>",
                                           tool_calls: [ { "tool" => "consultar_repasse", "args" => {},
                                                           "result" => { "nota" => "<img src=x onerror=alert(1)>" } } ])
      record_agent_action(turn, payload)

      get conversation_path(turn.ticket_id)

      expect(response.body).not_to include("<script>alert", "<img src=x")
      expect(response.body).to include("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;", "&lt;img src=x")
    end
  end

  describe "RF-55, RF-56: ação recebida na linha do tempo" do
    it "mostra a execução do agente com a duração e a aplicação, ligadas ao turno" do
      turn = applied_turn

      get timeline_path(turn.ticket_id)

      body = response.body
      expect(body).to include("Execução do agente", "Ação recebida do agente", "2345 ms", "Aplicação da resposta")
      expect(body).to include("consultar_repasse (120 ms)", "turno 1")
    end

    it "RN-56: mostra o descarte com o motivo" do
      turn = rejected_turn

      get timeline_path(turn.ticket_id)

      expect(response.body).to include("Descarte da resposta", "Turno superado por mensagem nova do cliente")
    end

    it "ao escolher a ação, mostra as consultas, a ação, o agente e o desfecho" do
      turn = rejected_turn
      index = ConversationReader.timeline(turn.ticket_id.to_s).events.index { _1.kind == :discarded } + 1

      get timeline_path(turn.ticket_id, evento: index)

      body = response.body
      expect(body).to include("Evento escolhido: Descarte da resposta", "Consultas do agente", "consultar_repasse",
                              "periodo", "programado", "120 ms", "mock-deterministico 0.3.0", "sha256:9f2c4",
                              "Descartada", "Turno superado")
    end

    it "escapa o HTML vindo do agente no evento escolhido" do
      turn = open_turn_for(ingest("meu repasse não caiu"))
      record_agent_action(turn, agent_action_payload(turn, text: "<script>alert(1)</script>"))
      index = ConversationReader.timeline(turn.ticket_id.to_s).events.index { _1.kind == :applied } + 1

      get timeline_path(turn.ticket_id, evento: index)

      expect(response.body).not_to include("<script>alert(1)")
      expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    end
  end

  it "ROADMAP 04: no exemplo sintético, a ação de exemplo aparece marcada como sintética" do
    get conversation_path("exemplo-repasse")
    expect(response.body).to include("Ação recebida", "consultar_repasse", "Exemplo sintético")

    index = ConversationReader.timeline("exemplo-repasse").events.index { _1.kind == :applied } + 1
    get timeline_path("exemplo-repasse", evento: index)
    expect(response.body).to include("Evento escolhido: Aplicação da resposta", "Consultas do agente", "Exemplo sintético")
  end
end
