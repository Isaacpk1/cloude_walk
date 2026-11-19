Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Entrada dos provedores de canal (bloco 02; 07, seção 5.0). Marca e conta vêm da URL.
  post "webhooks/:channel/:provider_account" => "webhooks/channels#create", as: :channel_webhook,
       constraints: { channel: /chat|whatsapp|email/ }

  # Painel (bloco 01): telas de conversa e linha do tempo, alimentadas pelo ConversationReader.
  root "conversations#index"
  resources :conversations, path: "conversas", only: %i[index show]
  resources :timelines, path: "linha-do-tempo", only: %i[index show]
end
