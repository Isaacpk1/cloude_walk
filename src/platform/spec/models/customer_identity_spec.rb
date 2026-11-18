require "rails_helper"

RSpec.describe CustomerIdentity do
  describe "RN-01: o mesmo identificador em duas marcas gera dois clientes" do
    it "aceita o mesmo telefone na InfinitePay e na JIM" do
      phone = "+5511999990000"
      ip = create(:customer_identity, customer: create(:customer, brand: create(:brand, :infinitepay)), external_id: phone)
      jim = create(:customer_identity, customer: create(:customer, brand: create(:brand, :jim)), external_id: phone)

      expect(ip.customer_id).not_to eq(jim.customer_id)
    end
  end

  describe "RN-02: um identificador pertence a um só cliente na marca" do
    it "recusa o mesmo telefone em dois clientes da mesma marca (repetição)" do
      brand = create(:brand)
      create(:customer_identity, customer: create(:customer, brand:), external_id: "+5511988887777")

      duplicate = build(:customer_identity, customer: create(:customer, brand:), external_id: "+5511988887777")

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "recusa identidade cuja marca difere da marca do cliente (marca errada)" do
      customer = create(:customer, brand: create(:brand, :infinitepay))
      identity = build(:customer_identity, customer:, brand: create(:brand, :jim))

      expect(identity).not_to be_valid
    end
  end
end
