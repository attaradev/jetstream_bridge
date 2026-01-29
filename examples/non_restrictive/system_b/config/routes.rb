# frozen_string_literal: true

Rails.application.routes.draw do
  # Health check endpoint
  get '/health', to: proc { [200, {}, ['OK']] }

  # Bidirectional sync endpoints
  resources :organizations, only: [:index, :show, :create, :update]
  resources :users, only: [:index, :show, :create, :update]

  # Sync status endpoint
  get '/sync_status', to: 'sync_status#index'
end
