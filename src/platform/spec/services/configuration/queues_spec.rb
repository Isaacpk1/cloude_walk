require "rails_helper"

# Bloco 12 (RF-13, RF-17, RF-18, RN-20, RN-53, invariantes 6, 7, 9): fila criada, editada, desativada e excluída pelo
# supervisor, versionada e auditada, com as validações de referência.
RSpec.describe Configuration::Queues, "RF-13, RF-17, RF-18: filas" do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let!(:jim) { create(:brand, :jim, locale: "en") }
  let(:setup) { distribution_setup(infinitepay) }
  let!(:boss) { analyst_in(setup[:team], role: "supervisor") }

  def create_queue(name: "Crédito", team: setup[:team], brand: infinitepay, **opts)
    described_class.create(brand:, team_id: team.id, name:, created_by: boss, **opts)
  end

  describe ".create" do
    it "cria a fila e a versão 1 com nome, IA primeiro e SLA, e audita" do
      sla = { "alta" => { "assume_s" => 120 } }
      result = create_queue(ai_first: false, sla_policy: sla)

      expect(result.ok).to be(true)
      queue = result.record
      expect(queue).to have_attributes(brand_id: infinitepay.id, team_id: setup[:team].id, active: true, is_default: false, escalation: false)
      expect(queue.current_version).to have_attributes(version: 1, name: "Crédito", ai_first: false, sla_policy: sla, created_by_id: boss.id)
      expect(AuditEvent.where(event_type: "queue.created", ticket_id: nil).sole.data)
        .to include("queue_id" => queue.id, "version" => 1, "name" => "Crédito")
    end

    it "recusa nome em branco ou muito longo, com o motivo em texto" do
      expect(create_queue(name: " ").errors).to include("o nome é obrigatório")
      expect(create_queue(name: "x" * 121).errors).to include("o nome tem no máximo 120 caracteres")
      expect(HelpdeskQueue.where.not(id: setup[:queue].id)).to be_empty
    end

    it "marca errada: equipe de outra marca é recusada" do
      jim_team = distribution_setup(jim)[:team]

      result = create_queue(team: jim_team)

      expect(result.errors).to include("a equipe não existe nesta marca")
      expect(HelpdeskQueue.where(team_id: jim_team.id).count).to eq(1) # só a fila do próprio setup da JIM
    end

    it "SLA com prioridade ou campo desconhecido, ou número inválido, é recusado" do
      expect(create_queue(sla_policy: { "urgente" => { "assume_s" => 10 } }).errors).to include(a_string_matching(/prioridade desconhecida/))
      expect(create_queue(sla_policy: { "alta" => { "assume_s" => 0 } }).errors).to include(a_string_matching(/inteiro positivo/))
      expect(create_queue(sla_policy: { "alta" => { "foo" => 5 } }).errors).to include(a_string_matching(/campo desconhecido/))
    end
  end

  describe ".update" do
    let(:queue) { create_queue.record }

    it "publica versão nova sem editar a antiga e audita o que mudou" do
      result = described_class.update(brand: infinitepay, queue_id: queue.id, name: "Crédito PJ", ai_first: false,
                                      sla_policy: {}, created_by: boss)

      expect(result.ok).to be(true)
      expect(queue.reload.current_version).to have_attributes(version: 2, name: "Crédito PJ", ai_first: false)
      expect(queue.versions.first).to have_attributes(version: 1, name: "Crédito", ai_first: true)
      expect(AuditEvent.where(event_type: "queue.version_published").sole.data)
        .to include("queue_id" => queue.id, "version" => 2, "changes" => include("name" => [ "Crédito", "Crédito PJ" ], "ai_first" => [ true, false ]))
    end

    it "marca errada: fila de outra marca é inexistente" do
      result = described_class.update(brand: jim, queue_id: queue.id, name: "x", ai_first: true, sla_policy: {}, created_by: boss)

      expect(result.errors).to eq([ "a fila não existe nesta marca" ])
      expect(queue.reload.current_version.version).to eq(1)
    end

    it "RN-20: duas edições ao mesmo tempo viram versões seguidas", :concurrency do
      queue
      results = run_concurrently(threads: 2) do |i|
        described_class.update(brand: infinitepay, queue_id: queue.id, name: "N#{i}", ai_first: true, sla_policy: {}, created_by: boss)
      end

      expect(results.map(&:ok)).to eq([ true, true ])
      expect(queue.reload.versions.pluck(:version)).to eq([ 1, 2, 3 ])
    end
  end

  describe ".set_active" do
    let(:queue) { create_queue.record }

    it "desativa e reativa a fila, auditando" do
      described_class.set_active(brand: infinitepay, queue_id: queue.id, active: false, created_by: boss)
      expect(queue.reload.active).to be(false)
      described_class.set_active(brand: infinitepay, queue_id: queue.id, active: true, created_by: boss)
      expect(queue.reload.active).to be(true)
      expect(AuditEvent.where(event_type: %w[queue.deactivated queue.activated]).count).to eq(2)
    end

    it "RF-17: não desativa a fila padrão da marca nem a fila de escalas" do
      expect(described_class.set_active(brand: infinitepay, queue_id: setup[:queue].id, active: false, created_by: boss).errors)
        .to include(a_string_matching(/padrão|escalas/))
      expect(setup[:queue].reload.active).to be(true)
    end

    it "RF-17: não desativa a fila que o conjunto de regras atual usa" do
      RoutingRuleset.publish!(brand: infinitepay, default_queue: setup[:queue], created_by: boss,
                              rules: { "schema_version" => 1, "rules" => [ { "name" => "R", "queue_id" => queue.id,
                                                                              "any" => [ { "all" => [ { "field" => "channel", "op" => "eq", "value" => "chat" } ] } ] } ] })

      result = described_class.set_active(brand: infinitepay, queue_id: queue.id, active: false, created_by: boss)

      expect(result.errors).to include(a_string_matching(/regras/))
      expect(queue.reload.active).to be(true)
    end
  end

  describe ".destroy" do
    let(:queue) { create_queue.record }

    it "exclui (arquiva) a fila sem atendimento aberto, mantendo versões e auditoria" do
      done = waiting_case(brand: infinitepay, queue:, identity: "acc_0")
      done.update_columns(state: "resolvido")

      result = described_class.destroy(brand: infinitepay, queue_id: queue.id, created_by: boss)

      expect(result.ok).to be(true)
      expect(queue.reload).to have_attributes(active: false)
      expect(queue.archived_at).to be_present
      expect(queue.versions.count).to eq(1)
      expect(AuditEvent.where(event_type: "queue.deleted").sole.data).to include("queue_id" => queue.id, "name" => "Crédito")
    end

    it "RF-17: com atendimento aberto na fila, recusa" do
      waiting_case(brand: infinitepay, queue:, identity: "acc_1")

      result = described_class.destroy(brand: infinitepay, queue_id: queue.id, created_by: boss)

      expect(result.errors).to include(a_string_matching(/atendimento\(s\) aberto/))
      expect(queue.reload.archived_at).to be_nil
    end

    it "arquivada, a fila não pode ser editada nem excluída de novo (inexistente)" do
      described_class.destroy(brand: infinitepay, queue_id: queue.id, created_by: boss)

      expect(described_class.destroy(brand: infinitepay, queue_id: queue.id, created_by: boss).errors).to eq([ "a fila não existe nesta marca" ])
      expect(described_class.update(brand: infinitepay, queue_id: queue.id, name: "x", ai_first: true, sla_policy: {}, created_by: boss).ok).to be(false)
    end

    it "RF-17: fila padrão, de escalas ou usada nas regras não é excluída" do
      expect(described_class.destroy(brand: infinitepay, queue_id: setup[:queue].id, created_by: boss).ok).to be(false)
    end
  end
end
