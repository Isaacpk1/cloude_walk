require "rails_helper"

# Bloco 14 (ADR-024, RNF-24): o ActionCable só aceita conexão com sessão de painel válida.
RSpec.describe ApplicationCable::Connection, type: :channel do
  let!(:infinitepay) { create(:brand, :infinitepay) }
  let(:setup) { distribution_setup(infinitepay) }
  let!(:ana) { analyst_in(setup[:team], password: "senha-sintetica-1") }

  def session_with(user_id:, seen_at: Time.current.to_i)
    { "user_id" => user_id, "seen_at" => seen_at }
  end

  it "aceita sessão válida e identifica o usuário" do
    connect "/cable", session: session_with(user_id: ana.id)

    expect(connection.current_user).to eq(ana)
  end

  it "recusa sem sessão, sessão expirada, usuário inexistente e bot" do
    expect { connect "/cable" }.to have_rejected_connection
    expect { connect "/cable", session: session_with(user_id: ana.id, seen_at: 9.hours.ago.to_i) }.to have_rejected_connection
    expect { connect "/cable", session: session_with(user_id: 0) }.to have_rejected_connection
    ana.update_columns(kind: "bot")
    expect { connect "/cable", session: session_with(user_id: ana.id) }.to have_rejected_connection
  end
end
