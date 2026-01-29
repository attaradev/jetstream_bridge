# frozen_string_literal: true

Rails.application.routes.draw do
  # Health check endpoint
  get '/health', to: proc { [200, {}, ['OK']] }

  # Sync status endpoint
  get '/sync_status', to: 'sync_status#index'

  # Organization endpoints
  resources :organizations, only: [:index, :show, :create, :update]

  # User endpoints
  resources :users, only: [:index, :show, :create, :update]
end
