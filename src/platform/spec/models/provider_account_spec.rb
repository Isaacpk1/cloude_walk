require "rails_helper"

RSpec.describe ProviderAccount do
  let(:infinitepay) { create(:brand, :infinitepay) }
  let(:jim) { create(:brand, :jim) }

  describe "07, seção 5.0: marca e conta vêm da URL e do cadastro da conta" do
    it "encontra a conta ativa pelo canal e pelo identificador da URL" do
      account = create(:provider_account, brand: jim, slug: "jim-chat-mock")

      expect(described_class.find!(channel: "chat", slug: "jim-chat-mock")).to eq(account)
      expect(account.brand_slug).to eq("jim")
    end

    it "recusa conta desconhecida" do
      expect { described_class.find!(channel: "chat", slug: "nao-existe") }.to raise_error(ProviderAccount::NotFound)
    end

    it "recusa conta de outro canal" do
      create(:provider_account, brand: jim, slug: "jim-chat-mock")

      expect { described_class.find!(channel: "whatsapp", slug: "jim-chat-mock") }.to raise_error(ProviderAccount::NotFound)
    end

    it "recusa conta desativada" do
      create(:provider_account, brand: jim, slug: "jim-chat-mock", active: false)

      expect { described_class.find!(channel: "chat", slug: "jim-chat-mock") }.to raise_error(ProviderAccount::NotFound)
    end
  end

  describe "ADR-019: segredo da assinatura" do
    let!(:account) { create(:provider_account, brand: infinitepay, secret: "segredo-muito-secreto") }

    it "fica criptografado no banco" do
      raw = described_class.connection.select_value("SELECT secret FROM provider_accounts WHERE id = #{account.id}")

      expect(raw).not_to include("segredo-muito-secreto")
      expect(account.reload.secret).to eq("segredo-muito-secreto")
    end

    it "não aparece no inspect" do
      expect(account.inspect).not_to include("segredo-muito-secreto")
    end

    it "é obrigatório" do
      expect(build(:provider_account, brand: infinitepay, secret: "")).not_to be_valid
    end
  end

  describe "invariante 8: restrições no banco" do
    let(:now) { Time.current }

    def insert(**attrs)
      described_class.insert_all!([ { brand_id: infinitepay.id, channel: "chat", slug: "conta", secret: "x",
                                      active: true, created_at: now, updated_at: now }.merge(attrs) ])
    end

    it "uma URL aponta para uma conta só" do
      insert(slug: "conta-1")

      expect { insert(slug: "conta-1", brand_id: jim.id) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "recusa canal desconhecido" do
      expect { insert(channel: "sms") }.to raise_error(ActiveRecord::StatementInvalid, /provider_accounts_channel_check/)
    end

    it "conta de WhatsApp exige o phone_number_id que o corpo precisa trazer" do
      expect { insert(channel: "whatsapp") }.to raise_error(ActiveRecord::StatementInvalid, /provider_accounts_whatsapp_phone_check/)
    end

    it "um número de WhatsApp pertence a uma conta só" do
      insert(slug: "wa-1", channel: "whatsapp", phone_number_id: "100")

      expect { insert(slug: "wa-2", channel: "whatsapp", phone_number_id: "100") }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "recusa marca inexistente" do
      expect { insert(brand_id: 0) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
