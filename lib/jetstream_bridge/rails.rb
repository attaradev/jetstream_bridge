# frozen_string_literal: true

# Entry point for Rails-specific integration (lifecycle helpers + railtie)
require_relative 'rails/integration'
require_relative 'rails/railtie' if defined?(Rails::Railtie)
