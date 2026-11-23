FactoryBot.define do
  # Fila com a versão corrente publicada (RN-20): o roteamento lê nome e IA primeiro da versão.
  factory :routing_queue, parent: :queue_record do
    transient do
      name { "Fila" }
      ai_first { true }
    end

    after(:create) do |queue, ctx|
      queue.publish_version!(name: ctx.name, ai_first: ctx.ai_first, created_by: nil)
    end
  end
end
