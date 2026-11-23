Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Status de entrega do chat (bloco 05; 07, seção 5.0). A conta da URL define a marca.
  post "webhooks/chat/:provider_account/status" => "webhooks/chat_statuses#create", as: :chat_status_webhook

  # Entrada dos provedores de canal (bloco 02; 07, seção 5.0). Marca e conta vêm da URL.
  post "webhooks/:channel/:provider_account" => "webhooks/channels#create", as: :channel_webhook,
       constraints: { channel: /chat|whatsapp|email/ }

  # Painel (bloco 01): telas de conversa e linha do tempo, alimentadas pelo ConversationReader.
  # Bloco 14 (ADR-024): login do painel.
  get "entrar" => "sessions#new", as: :login
  post "entrar" => "sessions#create"
  delete "sair" => "sessions#destroy", as: :logout
  root "conversations#index"
  resources :conversations, path: "conversas", only: %i[index show] do
    # Bloco 14 (RF-46, RF-48, RF-49): ações do analista responsável.
    post "resposta", to: "analyst_actions#reply", as: :reply
    post "notas", to: "analyst_actions#note", as: :note
    post "resolucao", to: "analyst_actions#resolve", as: :resolution
  end
  resources :timelines, path: "linha-do-tempo", only: %i[index show]
  # Bloco 07 (ADR-023): execuções gravadas em eval_runs.
  resources :evals, only: %i[index show]
  # Bloco 09 (RF-37): DLQ para o supervisor. Reprocessar fica para o bloco seguinte.
  resources :dead_letters, path: "dlq", only: %i[index show]
  # Bloco 10 (RF-42, RF-45, RN-29): casos em aguardando_humano. ?marca=<slug> restringe à marca.
  get "fila" => "human_queue#index", as: :human_queue
  # Bloco 13 (RF-27): disponibilidade do analista (online, pausa, offline). ?marca=<slug> exige que o analista seja da marca.
  patch "analistas/:id/disponibilidade" => "analyst_availabilities#update", as: :analyst_availability
end
