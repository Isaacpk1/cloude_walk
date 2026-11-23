require "rails_helper"

# Invariante 8: regras da DLQ da plataforma no banco (RN-48; 07, seção 4, dead_letters).
RSpec.describe "Invariante 8: integridade de dead_letters garantida pelo banco" do
  let(:now) { Time.current }

  def insert(**attrs)
    row = { topic: "helpdesk.agent.dlq.v1", partition: 0, offset: rand(1_000_000), source: "broker", reason: "contrato",
            payload: "{}", created_at: now }.merge(attrs)
    DeadLetter.insert_all!([ row ], returning: [ :id ]).rows.first.first
  end

  describe "RN-48, RNF-16: retenção mínima de 7 dias" do
    it "o banco recusa apagar um registro com menos de 7 dias" do
      id = insert(created_at: now - 7.days + 1.minute)

      expect { DeadLetter.where(id:).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /7 dias/)
    end

    it "a retenção compara em UTC, qualquer que seja o fuso da sessão (psql ou job de limpeza fora do Rails)" do
      id = insert(created_at: now - 7.days + 2.hours)
      ActiveRecord::Base.connection.execute("SET LOCAL TIME ZONE 'Asia/Tokyo'")

      expect { DeadLetter.where(id:).delete_all }.to raise_error(ActiveRecord::StatementInvalid, /7 dias/)
    end

    it "o banco aceita apagar depois de 7 dias (limpeza futura)" do
      id = insert(created_at: now - 7.days - 1.minute)

      expect(DeadLetter.where(id:).delete_all).to eq(1)
    end
  end

  describe "RF-34: mensagem com cabeçalho de origem ausente ou desconhecido" do
    it "é gravada com source unknown, para nada da DLQ sumir do espelho" do
      expect { insert(source: "unknown") }.to change(DeadLetter, :count).by(1)
    end

    it "outra origem continua recusada" do
      expect { insert(source: "scheduler") }.to raise_error(ActiveRecord::StatementInvalid, /dead_letters_source_check/)
    end
  end

  describe "RN-47: uma linha por mensagem do tópico" do
    it "o banco recusa o mesmo topic/partition/offset duas vezes" do
      insert(partition: 3, offset: 10)

      expect { insert(partition: 3, offset: 10) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
