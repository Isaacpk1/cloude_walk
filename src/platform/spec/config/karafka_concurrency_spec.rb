require "rails_helper"
require "open3"

# ADR-004, 07 seção 2: cada worker do Karafka usa uma conexão do pool do Active Record, então
# KAFKA_CONCURRENCY e RAILS_MAX_THREADS precisam andar juntos no processo consumer.
RSpec.describe "ADR-004, 07 seção 2: concorrência do Karafka no processo consumer" do
  it "padrão 5, igual ao padrão do pool (RAILS_MAX_THREADS)" do
    expect(Karafka::App.config.concurrency).to eq(5)
    expect(ActiveRecord::Base.connection_pool.db_config.max_connections).to be >= Karafka::App.config.concurrency
  end

  it "lê KAFKA_CONCURRENCY do ambiente" do
    out, status = Open3.capture2e({ "KAFKA_CONCURRENCY" => "3" }, "bin/rails", "runner",
                                  "print Karafka::App.config.concurrency", chdir: Rails.root.to_s)

    expect(status).to be_success, out
    expect(out.lines.last).to eq("3")
  end
end
