require "rails_helper"

# Invariante 8: a prova do contexto do turno vive no banco (07, seção 4; RN-49, RN-55, RF-33). Versão e digest
# andam juntos (os dois nulos só em turnos de antes do bloco 06) e a versão não é negativa.
RSpec.describe "Invariante 8, RN-55, RF-33: restrições de context_version e context_digest em ai_turns" do
  let(:infinitepay) { create(:brand, :infinitepay) }
  let(:customer) { create(:customer, brand: infinitepay) }
  let(:ticket) { Ticket.create!(brand: infinitepay, customer:, channel: "chat") }
  let(:digest) { "sha256:#{'a' * 64}" }

  def insert_turn(**attrs)
    now = Time.current
    row = { brand_id: infinitepay.id, ticket_id: ticket.id, turn: (@turn = @turn.to_i + 1), context_until_seq: 1,
            assignment_version: 0, context: {}, event_id: SecureRandom.uuid, status: "eligible", deadline_at: now + 30,
            created_at: now, updated_at: now }.merge(attrs)
    # Savepoint por verificação: a violação não aborta a transação do teste.
    ActiveRecord::Base.transaction(requires_new: true) { AiTurn.insert_all!([ row ]) }
  end

  it "aceita os dois preenchidos e os dois nulos (turno anterior ao bloco 06)" do
    expect { insert_turn(context_version: 0, context_digest: digest) }.not_to raise_error
    expect { insert_turn(context_version: nil, context_digest: nil) }.not_to raise_error
  end

  it "recusa versão sem digest e digest sem versão" do
    expect { insert_turn(context_version: 3, context_digest: nil) }
      .to raise_error(ActiveRecord::StatementInvalid, /ai_turns_context_version_digest_check/)
    expect { insert_turn(context_version: nil, context_digest: digest) }
      .to raise_error(ActiveRecord::StatementInvalid, /ai_turns_context_version_digest_check/)
  end

  it "recusa versão negativa; zero é o limite aceito" do
    expect { insert_turn(context_version: -1, context_digest: digest) }
      .to raise_error(ActiveRecord::StatementInvalid, /ai_turns_context_version_check/)
    expect { insert_turn(context_version: 0, context_digest: digest) }.not_to raise_error
  end
end
